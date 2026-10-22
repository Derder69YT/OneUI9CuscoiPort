#!/system/bin/sh
# fod.sh - FOD touch trigger v8 (antirrebote; requestId por log y, si no hay log, por dumpsys). Se lanza desde el service.sh del modulo con:
#   sh "${0%/*}/fod.sh" >/dev/null 2>&1 &
# Toque en la zona del sensor -> service call fingerprint 34 (onPointerDown),
# 36 (onUdfpsUiEvent) y al soltar 35 (onPointerUp).
# Uso manual sin reiniciar:  sh fod.sh now
LOG=/data/local/tmp/fodtrigger.log
REQ=/data/local/tmp/fod_req
SENSOR=0
CX=540; CY=2155; HALF=150          # centro y radio de la zona de disparo (px)
W=1080; H=2400                     # resolucion de pantalla
X0=$((CX-HALF)); X1=$((CX+HALF)); Y0=$((CY-HALF)); Y1=$((CY+HALF))
LOCKCS=80    # tras un disparo, ignora nuevos toques durante 0.80 s (la luz del HAL dura ~0.47 s)
MINGAP=25    # un toque que vuelve a aparecer a menos de 0.25 s de soltar se considera rebote

# Una sola instancia (pidfile): mata la anterior y sus procesos hijos
PIDF=/data/local/tmp/fod.pid
if [ -f "$PIDF" ]; then
  old=$(cat "$PIDF" 2>/dev/null)
  [ -n "$old" ] && [ "$old" != "$$" ] && kill "$old" 2>/dev/null
fi
echo "$$" > "$PIDF"
pkill -f 'getevent -l /dev/input' 2>/dev/null
pkill -f 'logcat -b all -v threadtime BiometricScheduler' 2>/dev/null

if [ "$1" != "now" ]; then
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
  sleep 15
fi
rm -f "$REQ"
echo "start v8 $(date)" > "$LOG"

# 1) Sigue el requestId de la operacion activa (registro o desbloqueo).
#    (BiometricScheduler escribe en el buffer 'system', por eso -b all).
#    Sin -d ni -T: vuelca primero el historial del buffer (solo este tag) y
#    despues sigue en vivo, asi no se pierde un registro ya iniciado.
(
  logcat -b all -v threadtime BiometricScheduler:D '*:S' | while read -r line; do
    case "$line" in
      *"[Started]"*EnrollClient*|*"[Started]"*AuthenticationClient*)
        id=${line#*requestId=}; id=${id%%,*}
        echo "$id" > "$REQ"; echo "req=$id" >> "$LOG";;
      *"[Finishing]"*EnrollClient*|*"[Finishing]"*AuthenticationClient*|*"Cancelling enrollment"*)
        rm -f "$REQ"; echo "req=none" >> "$LOG";;
    esac
  done
) &

# 2) Dispositivo tactil
DEV=""
for e in /dev/input/event*; do
  if getevent -lp "$e" 2>/dev/null | grep -q ABS_MT_POSITION_X; then DEV="$e"; break; fi
done
[ -z "$DEV" ] && { echo "no touch device" >> "$LOG"; exit 1; }
MAXX=$(getevent -lp "$DEV" | sed -n 's/.*ABS_MT_POSITION_X.*max \([0-9]*\),.*/\1/p' | head -n1)
MAXY=$(getevent -lp "$DEV" | sed -n 's/.*ABS_MT_POSITION_Y.*max \([0-9]*\),.*/\1/p' | head -n1)
echo "dev=$DEV maxx=$MAXX maxy=$MAXY rect=$X0-$X1,$Y0-$Y1" >> "$LOG"

R=0; PX=540; PY=2155
# Respaldo sin log: Samsung solo escribe mensajes de nivel D si persist.log.level lo permite;
# con el nivel a 0 el seguimiento por logcat se queda ciego. Se pregunta al servicio de huellas.
REQFB=""; NEG_UNTIL=0; DBG=0
getreq_dump() {
  REQFB=""
  out=$(dumpsys fingerprint 2>/dev/null | grep -a -iE -m1 -A4 "current operation")
  REQFB=$(echo "$out" | grep -a -o -E 'requestId=[0-9]+' | head -n1 | cut -d= -f2)
  if [ -z "$REQFB" ] && [ $DBG -lt 3 ]; then
    DBG=$((DBG + 1))
    echo "dump sin requestId: $(dumpsys fingerprint 2>/dev/null | grep -a -iE 'operation|requestId' | head -n4 | tr '\n' '|' | cut -c1-300)" >> "$LOG"
  fi
}
ptr() {  # $1 = 34 down | 35 up
  service call fingerprint $1 i64 $R i32 $SENSOR i32 1 i32 48 i32 0 f $PX.0 f $PY.0 f 10.0 f 10.0 f 0.0 i32 0 i64 0 i64 0 >/dev/null 2>&1
}

X=0; Y=0; TOUCH=0; PRESSED=0; NOREQ=0; NRAW=0; IGN=0; PREV_IN=0; LAST_UP=0; LOCK_UNTIL=0
# Con un solo dispositivo, getevent NO imprime el prefijo "/dev/input/eventN:",
# asi que la linea tiene 3 campos (tipo codigo valor) en vez de 4. Se aceptan ambos.
getevent -l "$DEV" | while read -r a b c d; do
  if [ -n "$d" ]; then code=$c; value=$d; else code=$b; value=$c; fi
  if [ $NRAW -lt 6 ]; then NRAW=$((NRAW+1)); echo "raw: $a|$b|$c|$d" >> "$LOG"; fi
  case "$code" in
    ABS_MT_POSITION_X) X=$(( 0x$value * W / (MAXX + 1) ));;
    ABS_MT_POSITION_Y) Y=$(( 0x$value * H / (MAXY + 1) ));;
    ABS_MT_TRACKING_ID) if [ "$value" = "ffffffff" ]; then TOUCH=0; else TOUCH=1; fi;;
    BTN_TOUCH) if [ "$value" = "DOWN" ]; then TOUCH=1; else TOUCH=0; fi;;
    SYN_REPORT)
      read -r UPT _ < /proc/uptime; NOW=${UPT%.*}${UPT#*.}
      IN=0
      if [ "$TOUCH" = 1 ] && [ $X -ge $X0 ] && [ $X -le $X1 ] && [ $Y -ge $Y0 ] && [ $Y -le $Y1 ]; then IN=1; fi
      if [ $IN = 1 ] && [ $PRESSED = 0 ]; then
        if [ $NOW -lt $LOCK_UNTIL ] || [ $((NOW-LAST_UP)) -lt $MINGAP ]; then
          if [ $IGN = 0 ]; then IGN=1; echo "ignorado (rebote) t=$NOW" >> "$LOG"; fi
        else
          REQFB=""
          if [ ! -f "$REQ" ] && [ $NOW -ge $NEG_UNTIL ]; then
            getreq_dump
            [ -z "$REQFB" ] && NEG_UNTIL=$((NOW + 200))   # sin operacion activa: no repetir en 2 s
          fi
          if [ -f "$REQ" ] || [ -n "$REQFB" ]; then
            if [ -f "$REQ" ]; then R=$(cat "$REQ"); else R=$REQFB; fi
            PX=$X; PY=$Y; PRESSED=1; IGN=1
            LOCK_UNTIL=$((NOW+LOCKCS))
            echo "down $PX,$PY req=$R t=$NOW" >> "$LOG"
            sleep 0.05
            ptr 34
            sleep 0.35
            service call fingerprint 36 i32 1 i64 $R i32 $SENSOR >/dev/null 2>&1
          elif [ $NOREQ = 0 ]; then
            NOREQ=1; echo "toque en zona SIN requestId ($X,$Y)" >> "$LOG"
          fi
        fi
      elif [ $IN = 0 ]; then
        NOREQ=0; IGN=0
        if [ $PRESSED = 1 ]; then
          PRESSED=0
          echo "up t=$NOW" >> "$LOG"
          ptr 35
        fi
      fi
      if [ $IN = 0 ] && [ $PREV_IN = 1 ]; then LAST_UP=$NOW; fi
      PREV_IN=$IN;;
  esac
done
