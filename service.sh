#!/system/bin/sh
# FOD huella (en segundo plano): lanza fod.sh, que va en la misma carpeta que este service.sh
sh "${0%/*}/fod.sh" >/dev/null 2>&1 &
# Brillo: sube el techo del deslizador (brillo.sh, misma carpeta)
sh "${0%/*}/brillo.sh" >/dev/null 2>&1 &
# Modo sol: lee el sensor de luz y activa el brillo extra (sol.sh, misma carpeta)
sh "${0%/*}/sol.sh" >/dev/null 2>&1 &

# Cuscoi USB fix (sin tocar /system) - para KernelSU / DSU
#
# Problema: el script xgsi-usb.rc de la GSI enlaza ffs.adb como "f1" y activa el
# UDC por su cuenta. El HAL de USB solo borra enlaces llamados "function*", asi que
# "f1" se queda y al pedir MTP+ADB el kernel responde EEXIST (errno 17).
#
# Solucion: vigilar la configuracion y, cuando aparezca "f1", moverlo a un nombre
# "functionN" que el HAL si sabe borrar y recrear. No toca nada mas.

G=${USBFIX_G:-/config/usb_gadget/g1}
C=$G/configs/b.1
LOG=${USBFIX_LOG:-/data/local/tmp/usbfix.log}
LOCK=${USBFIX_LOCK:-/dev/.usbfix_running}

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

free_name() {
    i=0
    while [ -e "$C/function$i" ] || [ -L "$C/function$i" ]; do i=$((i + 1)); done
    echo "$C/function$i"
}

fix_once() {
    [ -L "$C/f1" ] || return 0
    udc=$(cat "$G/UDC" 2>/dev/null | tr -d '\n')
    if [ -n "$udc" ]; then
        # estado "xgsi" estable: ADB funcionando con f1 -> lo movemos sin perder ADB
        log "f1 detectado con UDC=$udc: moviendo a functionN"
        echo "" > "$G/UDC" 2>>"$LOG"
        rm -f "$C/f1" 2>>"$LOG"
        ln -s "$G/functions/ffs.adb" "$(free_name)" 2>>"$LOG"
        echo "$udc" > "$G/UDC" 2>>"$LOG"
    else
        # el HAL ya desactivo el UDC y va a enlazar sus funciones: solo quitamos f1
        log "f1 detectado con UDC vacio: eliminando f1"
        rm -f "$C/f1" 2>>"$LOG"
    fi
    log "estado: $(ls "$C" 2>/dev/null | tr '\n' ' ') UDC=$(cat "$G/UDC" 2>/dev/null | tr -d '\n')"
}

main_loop() {
    until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
    sleep 3
    log "usbfix iniciado"
    while true; do
        fix_once
        sleep 0.5
    done
}

if [ "$1" = "--once" ]; then
    fix_once
    exit 0
fi

if [ ! -e "$LOCK" ]; then
    : > "$LOCK" 2>/dev/null
    main_loop &
fi

# ======================================================================
# Puente: hace que el menu "Proteccion de la bateria" de One UI limite la carga de verdad.
# El kernel de Motorola ignora charge_control_end_threshold, asi que se vigila el nivel
# y se corta/reanuda la carga con force_charging_disable (0 = carga, 1 = no carga).
#
#  protect_battery = 0  Desactivada                 : siempre carga
#  protect_battery = 1  Maximo (80/85/90/95 %)      : corta en el umbral, reanuda 5 puntos antes
#  protect_battery = 3  Basica                      : corta al 100 %, reanuda al 95 %
#  protect_battery = 4  Basica + Proteccion reposo  : como Basica, pero en tu horario de sueno
#                       mantiene 80 % y carga al 100 % antes de despertar
#
# Horario de sueno: se edita en /data/local/tmp/charge_limit.conf

battery_main() {
  D=/sys/devices/platform/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger
  NODE=$D/force_charging_disable
  CAPF=/sys/class/power_supply/battery/capacity
  LOG=/data/local/tmp/charge_limit.log
  CONF=/data/local/tmp/charge_limit.conf

  [ -e "$NODE" ] || return 0

  # seguridad: si este proceso termina (por la senal que sea), la carga se reactiva.
  # TERM/INT/HUP hacen 'exit', que dispara el trap de EXIT; antes solo ejecutaban el
  # echo y el bucle seguia vivo.
  trap 'echo 0 > $NODE 2>/dev/null' EXIT
  trap 'exit 0' TERM INT HUP

  # esperar a que el sistema termine de arrancar
  while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 5; done
  sleep 20

  if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<EOC
# Horario de sueno para la "Proteccion en reposo" (formato HH:MM, 24 h)
SLEEP_START=23:00
WAKE_UP=07:00
# Minutos antes de despertar en los que empieza a cargar hasta el 100 %
FINISH_BEFORE=90
# Limite que se mantiene durante el sueno
SLEEP_LIMIT=80
EOC
  fi

  to_min() {
    h=${1%%:*}; m=${1##*:}
    h=${h#0}; m=${m#0}
    echo $(( ${h:-0} * 60 + ${m:-0} ))
  }

  echo "$(date) inicio" >> $LOG
  echo 0 > $NODE

  while true; do
    MODE=$(settings get global protect_battery 2>/dev/null)
    THR=$(settings get global battery_protection_threshold 2>/dev/null)
    REC=$(settings get global battery_protection_recharge_level 2>/dev/null)
    case "$THR" in ''|null|*[!0-9]*) THR=85 ;; esac
    case "$REC" in ''|null|*[!0-9]*) REC=95 ;; esac

    LIM_E=""; LIM_S=""; WHY="sin limite"
    case "$MODE" in
      1) LIM_E=$THR; LIM_S=$((THR - 5)); WHY="maximo $THR" ;;
      3) LIM_E=100; LIM_S=$REC; WHY="basica" ;;
      4)
        LIM_E=100; LIM_S=$REC; WHY="basica"
        . "$CONF"
        NOW=$(to_min "$(date +%H:%M)")
        S=$(to_min "$SLEEP_START"); W=$(to_min "$WAKE_UP")
        HOLD_END=$(( (W - FINISH_BEFORE + 1440) % 1440 ))
        if [ "$S" -le "$HOLD_END" ]; then
          [ "$NOW" -ge "$S" ] && [ "$NOW" -lt "$HOLD_END" ] && HOLD=1 || HOLD=0
        else
          { [ "$NOW" -ge "$S" ] || [ "$NOW" -lt "$HOLD_END" ]; } && HOLD=1 || HOLD=0
        fi
        if [ "$HOLD" = 1 ]; then
          LIM_E=${SLEEP_LIMIT:-80}; LIM_S=$((LIM_E - 5)); WHY="reposo $LIM_E"
        fi
        ;;
    esac

    CAP=$(cat $CAPF); CUR=$(cat $NODE)
    if [ -z "$LIM_E" ]; then WANT=0
    elif [ "$CAP" -ge "$LIM_E" ]; then WANT=1
    elif [ "$CAP" -le "$LIM_S" ] || [ "$CAP" -lt 20 ]; then WANT=0
    else WANT=$CUR
    fi

    if [ "$WANT" != "$CUR" ]; then
      echo $WANT > $NODE
      echo "$(date) nivel=$CAP modo=$MODE ($WHY): force_charging_disable=$WANT" >> $LOG
    fi
    sleep 30
  done
}
battery_main &
