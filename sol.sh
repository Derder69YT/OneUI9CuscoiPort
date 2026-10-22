#!/system/bin/sh
# sol.sh - modo sol: lee el sensor de luz (stk3acx) y avisa a brillo.sh con un archivo
# de bandera cuando hay sol fuerte, para que suba el techo de brillo (SUNCAP).
# Necesita el BRILLO AUTOMATICO ENCENDIDO: con el brillo manual el sensor esta apagado
# y no hay lecturas. Se lanza desde el service.sh:  sh "${0%/*}/sol.sh" >/dev/null 2>&1 &
CONF=/data/local/tmp/sol.conf
FLAG=/data/local/tmp/sol.flag
LOG=/data/local/tmp/sol.log
PIDF=/data/local/tmp/sol.pid
BL=/sys/class/backlight/panel0-backlight/brightness
TEMPF=/sys/class/power_supply/battery/temp
UPFILE=/proc/uptime
SENS='Ambient Light Sensor Non-wakeup: last'

if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOC
# Lux para ENTRAR en modo sol (sol directo ~50000-100000; sombra clara ~5000-10000)
ENTER_LUX=8000
# Lux para SALIR del modo sol
EXIT_LUX=4000
# Valor del backlight en modo sol (maximo del panel: 4095). Sube de poco en poco.
SUNCAP=3000
# Si la bateria pasa de esta temperatura (decimas de grado: 430 = 43.0 C) se sale del modo sol
TEMP_MAX=430
# Segundos entre lecturas
POLL=2
EOC
fi
. "$CONF"
ENTER_LUX=${ENTER_LUX:-8000}; EXIT_LUX=${EXIT_LUX:-4000}; TEMP_MAX=${TEMP_MAX:-430}; POLL=${POLL:-2}

if [ -f "$PIDF" ]; then
  old=$(cat "$PIDF" 2>/dev/null)
  [ -n "$old" ] && [ "$old" != "$$" ] && kill "$old" 2>/dev/null
fi
echo "$$" > "$PIDF"
echo 0 > "$FLAG"

if [ "$1" != "now" ]; then
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
  sleep 20
fi
echo "start v1 ENTER=$ENTER_LUX EXIT=$EXIT_LUX POLL=$POLL $(date)" > "$LOG"

# Lee la ultima medida del sensor. LUX=entero. Devuelve 1 si no hay dato reciente.
read_lux() {
  line=$(dumpsys sensorservice 2>/dev/null | grep -A50 "$SENS" | grep -E '^[[:space:]]+[0-9]+ \(ts=' | tail -n 1)
  [ -z "$line" ] && return 1
  ts=${line#*ts=}; ts=${ts%%,*}; ts=${ts%.*}
  val=${line#*) }; val=${val%%,*}; LUX=${val%.*}
  case "$LUX" in ''|*[!0-9]*) return 1;; esac
  case "$ts" in ''|*[!0-9]*) return 1;; esac
  read -r UP _ < "$UPFILE"; UP=${UP%.*}
  [ $((UP - ts)) -gt 6 ] && return 1
  return 0
}

setflag() { echo "$1" > "$FLAG"; echo "flag=$1 lux=${LUX:-?} temp=${TEMP:-?} $(date +%H:%M:%S)" >> "$LOG"; }

SUN=0; HI=0; LO=0; STALE=0; HOT=0; LUX=0; TEMP=0
while true; do
  read -r cur < "$BL" 2>/dev/null
  case "$cur" in ''|*[!0-9]*) sleep 2; continue;; esac
  if [ "$cur" -lt 100 ]; then          # pantalla apagada o AOD
    [ $SUN = 1 ] && { SUN=0; setflag 0; }
    HI=0; LO=0; STALE=0
    sleep 5; continue
  fi

  read -r TEMP < "$TEMPF" 2>/dev/null
  case "$TEMP" in ''|*[!0-9]*) TEMP=0;; esac
  if [ "$TEMP" -ge "$TEMP_MAX" ]; then HOT=1; elif [ "$TEMP" -lt $((TEMP_MAX - 20)) ]; then HOT=0; fi

  if read_lux; then
    STALE=0
    if [ $SUN = 0 ]; then
      if [ "$LUX" -ge "$ENTER_LUX" ]; then HI=$((HI + 1)); else HI=0; fi
      if [ $HI -ge 2 ] && [ $HOT = 0 ]; then SUN=1; LO=0; setflag 1; fi
    else
      if [ "$LUX" -le "$EXIT_LUX" ]; then LO=$((LO + 1)); else LO=0; fi
      if [ $LO -ge 3 ] || [ $HOT = 1 ]; then SUN=0; HI=0; setflag 0; fi
    fi
  else
    STALE=$((STALE + 1)); HI=0
    if [ $STALE -ge 5 ] && [ $SUN = 1 ]; then SUN=0; setflag 0; fi
  fi
  sleep "$POLL"
done
