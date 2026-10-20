#!/bin/bash
# Root helper for benchmarks/run.py. Started once (sudo or an admin prompt) for one run.
# It executes ONLY these commands, read line by line from a FIFO the runner writes:
#   lpm 0|1          pmset -a lowpowermode 0|1   (macOS Low Power Mode, battery + AC)
#   pm start <name>  powermetrics (cpu_power,gpu_power), 1 s samples, plist, into <rundir>/pm/<name>.plist
#   pm stop          stop powermetrics
#   fand stop|start  stop / start the installed fan daemon (launchctl bootout / bootstrap of its LaunchDaemon);
#                    bootout sends SIGTERM, on which the daemon returns the fans to Apple's automatic control
#   bt kill9         SIGKILL the Battery Tool daemon (launchd KeepAlive restarts it): crash-recovery test
#   wake <seconds>   schedule a wake <seconds> from now (pmset schedule wake), 30..600
#   sleepnow         put the Mac to sleep (pmset sleepnow)
#   exit             stop and restore
# On exit, timeout (<max_seconds>) or any signal it stops powermetrics and restores the
# Low Power Mode values it found at start (per power source), and starts the fan daemon again if it stopped it.
# Usage: roothelper.sh <rundir> <max_seconds>
set -u
RUN=$1; MAX=$2; FIFO=$RUN/helper.fifo; LOG=$RUN/helper.log
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
cd / || exit 1
mkdir -p "$RUN/pm"; rm -f "$FIFO"; mkfifo -m 600 "$FIFO"; chown "$(stat -f %u "$RUN")" "$FIFO"
lpm_of() { pmset -g custom | awk -v src="$1" '$0 ~ src {f=1; next} /Power:$/ {f=0} f && $1=="lowpowermode" {print $2; exit}'; }
ORIG_B=$(lpm_of "Battery Power:"); ORIG_C=$(lpm_of "AC Power:")
echo "$(date +%s) start orig_battery=$ORIG_B orig_ac=$ORIG_C" >> "$LOG"
PM=""; FAND_STOPPED=""
FAND_PLIST=""
for f in /Library/LaunchDaemons/com.fancurve.daemon.plist /Library/LaunchDaemons/com.macfanctl.daemon.plist; do
    [ -f "$f" ] && FAND_PLIST=$f && break
done
stop_pm() { [ -n "$PM" ] && kill "$PM" 2>/dev/null && wait "$PM" 2>/dev/null; PM=""; }
restore() {
    stop_pm
    if [ -n "$FAND_STOPPED" ] && [ -n "$FAND_PLIST" ]; then
        launchctl bootstrap system "$FAND_PLIST" && echo "$(date +%s) fan daemon started again" >> "$LOG"
    fi
    [ -n "$ORIG_B" ] && pmset -b lowpowermode "$ORIG_B"
    [ -n "$ORIG_C" ] && pmset -c lowpowermode "$ORIG_C"
    echo "$(date +%s) restored battery=$ORIG_B ac=$ORIG_C" >> "$LOG"
    rm -f "$FIFO"
}
trap 'restore; exit 0' EXIT INT TERM HUP
exec 3<>"$FIFO"
DEADLINE=$(( $(date +%s) + MAX ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    read -r -t 5 cmd arg <&3 || continue
    echo "$(date +%s) $cmd $arg" >> "$LOG"
    case "$cmd $arg" in
        "lpm 0"|"lpm 1") pmset -a lowpowermode "$arg" ;;
        "pm stop") stop_pm ;;
        "fand stop") [ -n "$FAND_PLIST" ] && launchctl bootout system "$FAND_PLIST" && FAND_STOPPED=1 ;;
        "fand start") [ -n "$FAND_PLIST" ] && [ -n "$FAND_STOPPED" ] && launchctl bootstrap system "$FAND_PLIST" && FAND_STOPPED="" ;;
        "exit ") break ;;
        "bt kill9") pkill -9 -f "/usr/local/bin/battery-tool daemon" ;;
        "sleepnow ") pmset sleepnow ;;
        wake\ *)
            if [[ "$arg" =~ ^[0-9]{2,3}$ ]] && [ "$arg" -ge 30 ] && [ "$arg" -le 600 ]; then
                pmset schedule wake "$(date -v+"${arg}"S "+%m/%d/%y %H:%M:%S")"
            fi ;;
        pm\ start\ *)
            name=${arg#start }
            if [[ "$name" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
                stop_pm
                /usr/bin/powermetrics -i 1000 --samplers cpu_power,gpu_power -f plist -o "$RUN/pm/$name.plist" >/dev/null 2>&1 &
                PM=$!
            fi ;;
        *) echo "$(date +%s) ignored: $cmd $arg" >> "$LOG" ;;
    esac
done
