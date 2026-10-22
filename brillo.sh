#!/system/bin/sh
# brillo.sh v4 - sube el techo de brillo del panel (Edge 50 Fusion + GSI One UI).
# Con el deslizador al 100 % el sistema pide brillo 1.0 y el HAL de Motorola escribe
# solo 819 de 4095 en el backlight. Este script reescribe ese valor con una curva que
# deja casi intactos los niveles bajos y sube el alto hasta CAP.
# v3: NO pelea con el HAL mientras este cambia el valor (eso era el parpadeo). Espera a
# que el valor lleve SETTLE_CS centesimas estable y entonces sube hasta el objetivo con
# una rampa corta de RAMP_STEPS pasos.
# v4: modo sol. Si sol.sh escribe 1 en /data/local/tmp/sol.flag, el techo pasa de CAP a
# SUNCAP (de /data/local/tmp/sol.conf) con la misma rampa suave.
# Se lanza desde el service.sh del modulo:  sh "${0%/*}/brillo.sh" >/dev/null 2>&1 &
BL=/sys/class/backlight/panel0-backlight/brightness
CONF=/data/local/tmp/brillo.conf
LOG=/data/local/tmp/brillo.log
PIDF=/data/local/tmp/brillo.pid
SOLFLAG=/data/local/tmp/sol.flag
SOLCONF=/data/local/tmp/sol.conf
SETTLE_CS=10     # espera (centesimas de segundo) con el valor del HAL estable
RAMP_STEPS=8     # pasos de la rampa (cada paso ~20 ms)

[ -w "$BL" ] || exit 0

if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOC
# BASE: valor que escribe el HAL con el deslizador al 100 % (en tu movil: 819)
BASE=819
# CAP: valor que se escribe cuando el HAL pide BASE. El maximo del panel es 4095;
# los valores muy altos sostenidos calientan y gastan mucho, sube de poco en poco.
CAP=2000
EOC
fi
. "$CONF"
BASE=${BASE:-819}; CAP=${CAP:-2000}
[ "$CAP" -gt 4095 ] && CAP=4095
[ "$CAP" -lt "$BASE" ] && CAP=$BASE

# Una sola instancia
if [ -f "$PIDF" ]; then
  old=$(cat "$PIDF" 2>/dev/null)
  [ -n "$old" ] && [ "$old" != "$$" ] && kill "$old" 2>/dev/null
fi
echo "$$" > "$PIDF"

if [ "$1" != "now" ]; then
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
fi
CAPE=$CAP; SUN=0
echo "start v4 BASE=$BASE CAP=$CAP $(date)" > "$LOG"

now() { read -r UPT _ < /proc/uptime; NOW=${UPT%.*}${UPT#*.}; }

# objetivo para un valor del HAL
target() {
  v=$1
  if [ "$v" -gt 0 ] && [ "$v" -le "$BASE" ]; then
    t=$((v * 1000 / BASE))
    t3=$((t * t / 1000 * t / 1000))
    TGT=$((v + (CAPE - BASE) * t3 / 1000))
    [ "$TGT" -gt "$CAPE" ] && TGT=$CAPE
  else
    TGT=$v
  fi
}

# rampa desde $1 hasta $2; devuelve 1 si el HAL escribio algo mientras tanto
ramp() {
  from=$1; to=$2; i=1
  while [ $i -le $RAMP_STEPS ]; do
    v=$((from + (to - from) * i / RAMP_STEPS))
    echo "$v" > "$BL"; MINE=$v; SEEN=$v
    sleep 0.02
    read -r c < "$BL" 2>/dev/null
    if [ "$c" != "$v" ]; then SEEN=-1; return 1; fi
    i=$((i + 1))
  done
  return 0
}

SEEN=-1; MINE=-1; HALV=-1; APPLIED=1; SINCE=0; N=0
while true; do
  read -r cur < "$BL" 2>/dev/null
  case "$cur" in ''|*[!0-9]*) sleep 0.2; continue;; esac

  # modo sol: cambia el techo y fuerza a reaplicar sin esperar al HAL
  read -r F < "$SOLFLAG" 2>/dev/null
  [ "$F" = "1" ] || F=0
  if [ "$F" != "$SUN" ]; then
    SUN=$F
    if [ "$SUN" = 1 ]; then
      [ -f "$SOLCONF" ] && . "$SOLCONF"
      CAPE=${SUNCAP:-3000}
      [ "$CAPE" -gt 4095 ] && CAPE=4095
      [ "$CAPE" -lt "$CAP" ] && CAPE=$CAP
    else
      CAPE=$CAP
    fi
    echo "modo sol=$SUN techo=$CAPE" >> "$LOG"
    if [ "$HALV" -ge 0 ]; then APPLIED=0; now; SINCE=$((NOW - SETTLE_CS)); fi
  fi

  if [ "$cur" != "$SEEN" ]; then
    SEEN=$cur
    if [ "$cur" != "$MINE" ]; then      # lo escribio el HAL, no nosotros
      HALV=$cur; now; SINCE=$NOW; APPLIED=0
    fi
  fi

  if [ $APPLIED = 0 ]; then
    now
    if [ $((NOW - SINCE)) -ge $SETTLE_CS ]; then
      target "$HALV"
      if [ "$TGT" != "$HALV" ]; then
        if [ $N -lt 40 ]; then N=$((N+1)); echo "hal=$HALV -> $TGT" >> "$LOG"; fi
        ramp "$cur" "$TGT" || continue   # si el HAL interfirio, se reevalua
      fi
      APPLIED=1
    fi
    sleep 0.02
  else
    sleep 0.1
  fi
done
