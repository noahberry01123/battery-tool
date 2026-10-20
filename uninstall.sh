#!/bin/bash
# battery-tool uninstaller. Re-enables charging FIRST, restores macOS Low Power
# Mode and process priorities, then unloads and deletes everything battery-tool
# installed. Self-contained on purpose: it needs nothing else from the install
# (the SMC helper's C source is embedded below and compiled on demand), keeps
# going when a step fails, and is safe to run any number of times.
#   uninstall.sh [--yes] [--from-daemon | --from-menubar]
# Needs root (re-runs itself with sudo). build.sh extracts smc_helper_source().
# No `set -e`/`set -u` on purpose: nothing may stop the restore half-way.

# Run as `sh uninstall.sh`? Another sh, or bash in POSIX mode, cannot parse what follows.
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set +o posix

# Installed layout; keep in sync with Sources/Shared/Paths.swift and install.sh.
BIN=/usr/local/bin/battery-tool
LIB_DIR=/usr/local/lib/battery-tool
MANIFEST=$LIB_DIR/install-manifest.txt
CONFIG_DIR=/usr/local/etc/battery-tool
VAR_DIR=/usr/local/var/battery-tool
CHANGES=$VAR_DIR/changes.tsv
DAEMON_LABEL=local.battery-tool.daemon
DAEMON_PLIST=/Library/LaunchDaemons/$DAEMON_LABEL.plist
MENU_LABEL=local.battery-tool.menubar
MENU_PLIST=/Library/LaunchAgents/$MENU_LABEL.plist
MENU_APP=/Applications/BatteryTool.app
SENTINEL_NAME=UNINSTALL-BATTERY-TOOL
REPORT_NAME=BATTERY-TOOL-UNINSTALLED.txt

export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C

FROM_DAEMON=0
FROM_MENUBAR=0
SCRIPT_DIR=""
TMPD=""
HELPER=""
REPORT=""          # everything printed, for the --from-daemon report file
CREATED_DIRS=""    # created_dir= entries of the manifest (read before deleting it)
T_NAMES=() T_UIDS=() T_HOMES=()   # target users: manifest user + console user
CONSOLE_USER="" CONSOLE_UID=""
LPM_EXPECT_BATTERY="" LPM_EXPECT_AC=""   # recorded Low Power Mode originals
PROC_SUMMARY=""
LEFT_SENTINEL=0

# ---- output -------------------------------------------------------------------

say()  { printf '%s\n' "$*" 2>/dev/null; REPORT+="$*"$'\n'; }
ok()   { say "  ✔ $*"; }
note() { say "  – $*"; }
bad()  { say "  ✖ $*"; }
one_line() { printf '%s\n' "$1" | sed '/^$/d' | paste -sd ' ' -; }

# ---- pure parsing (sourced by tests) --------------------------------------------

# Values of every `KEY=value` line for KEY in an install manifest, in file order.
manifest_values() {  # key file
    local line
    [ -r "$2" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in "$1="*) printf '%s\n' "${line#*=}" ;; esac
    done < "$2"
}

# "SOURCE ORIG" for each `lpm` line of a change record (first line per source wins).
record_lpm() {  # file
    [ -r "$1" ] || return 0
    awk -F'\t' '$1 == "lpm" && ($2 == "battery" || $2 == "ac") && $3 ~ /^[0-9]+$/ && !seen[$2]++ { print $2, $3 }' "$1"
}

# Epoch seconds extreme low power mode was turned on (the record's `since` line), if any.
record_since() {  # file
    [ -r "$1" ] || return 0
    awk -F'\t' '$1 == "since" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$1"
}

# "PID START_SEC" for each `proc` line of a change record.
record_procs() {  # file
    [ -r "$1" ] || return 0
    awk -F'\t' '$1 == "proc" && $2 ~ /^[0-9]+$/ && length($2) <= 9 && $2 > 1 && $3 ~ /^[0-9]+$/ { print $2, $3 }' "$1"
}

# `ps -o lstart=` text (local time, e.g. "Mon Oct  6 07:46:12 2026") -> epoch seconds.
lstart_to_epoch() {
    local s
    s=$(printf '%s' "$1" | tr -s ' \t' '  ' | sed 's/^ //; s/ $//')
    [ -n "$s" ] && LC_ALL=C date -j -f "%a %b %d %T %Y" "$s" +%s 2>/dev/null
}

# Start time (epoch seconds) of a live process; nothing if it is gone. UTC, so the repeated
# hour when daylight saving time ends cannot shift it.
proc_start() { TZ=UTC0 lstart_to_epoch "$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null)"; }

# "<battery> <ac>" lowpowermode values from `pmset -g custom` on stdin ("?" if absent).
lpm_from_custom() {
    awk '{ t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t) }
         t ~ /:$/ { sec = t; next }
         $1 == "lowpowermode" && NF == 2 { if (sec ~ /^Battery Power/) b = $2; else if (sec ~ /^AC Power/) a = $2 }
         END { print (b == "" ? "?" : b), (a == "" ? "?" : a) }'
}

# Battery line of `pmset -g batt` on stdin, e.g. "49%; AC attached; not charging".
batt_line() { awk -F'\t' '/InternalBattery/ { s = $NF; sub(/ present: true$/, "", s); print s; exit }'; }

# `smc-helper read CHTE CH0B CH0C` output on stdin: succeeds if at least one line was
# read and every key that exists is all zero (= charging enabled).
keys_enabled() {
    local line val n=0
    while IFS= read -r line; do
        case $line in *=*) ;; *) continue ;; esac
        n=$((n + 1))
        val=${line#*=}
        [ "$val" = absent ] && continue
        case $val in ''|*[!0]*) return 1 ;; esac
    done
    [ $n -gt 0 ]
}

# Home folder of a user from the directory service ("" if unknown).
user_home() {
    [ -n "$1" ] || return 0
    dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null |
        awk '{ sub(/^NFSHomeDirectory:/, ""); sub(/^[ \t]+/, ""); if ($0 != "") { print; exit } }'
}

# Escapes a string for an AppleScript string literal.
as_escape() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }

# ---- SMC helper ---------------------------------------------------------------

# Finds a working smc-helper (installed -> next to this script -> build/ -> compiled
# from the embedded source) and keeps a copy in $TMPD so it outlives step 4.
resolve_helper() {
    local cand rc cc
    for cand in "$LIB_DIR/smc-helper" "$SCRIPT_DIR/smc-helper" "$SCRIPT_DIR/build/smc-helper"; do
        [ -f "$cand" ] && [ -x "$cand" ] || continue
        if [ -n "$TMPD" ]; then
            # Always a new file: rewriting an executed binary in place gets it killed.
            rm -f "$TMPD/smc-helper"
            cp "$cand" "$TMPD/smc-helper" 2>/dev/null && chmod 755 "$TMPD/smc-helper" || continue
            HELPER=$TMPD/smc-helper
        else
            HELPER=$cand
        fi
        "$HELPER" read CHTE >/dev/null 2>&1; rc=$?
        case $rc in 0|1|3) note "SMC helper: $cand"; return 0 ;; esac   # it runs
        HELPER=""
    done
    [ -n "$TMPD" ] && smc_helper_source > "$TMPD/smc-helper.c" 2>/dev/null || return 1
    for cc in "xcrun clang" clang cc; do
        rm -f "$TMPD/smc-helper"
        $cc -O2 -o "$TMPD/smc-helper" "$TMPD/smc-helper.c" -framework IOKit >/dev/null 2>&1 || continue
        HELPER=$TMPD/smc-helper
        note "SMC helper: compiled from the source embedded in this script"
        return 0
    done
    return 1
}

loud_warning() {
    say ""
    say "  ✖✖✖ COULD NOT RE-ENABLE CHARGING AUTOMATICALLY ✖✖✖"
    say "  No SMC helper was found and none could be compiled (no C compiler)."
    say "  If this Mac does not charge afterwards:"
    say "    1. Install Apple's command line tools:  xcode-select --install"
    say "       then run this uninstaller again; it compiles its helper by itself."
    say "    2. Or shut the Mac down completely, wait 30 seconds and start it again"
    say "       (this usually resets the charging controller)."
    say "  The uninstall continues; battery-tool will not block charging again."
    say ""
}

# ---- step 1: charging -----------------------------------------------------------

# Clears every charge-inhibit key and reads it back; then shows live current + pmset.
enable_charging() {  # [quiet]
    local out rc line
    if [ -z "$HELPER" ]; then
        [ -n "$1" ] || loud_warning
        return 1
    fi
    out=$("$HELPER" enable-charging 2>&1); rc=$?
    if [ -n "$1" ]; then
        if [ $rc -eq 0 ]; then ok "charging re-checked: $(one_line "$out")"; else bad "charging re-check: $(one_line "$out")"; fi
        return $rc
    fi
    while IFS= read -r line; do
        case $line in
            "") ;;
            *" ok") ok "$line (charging enabled)" ;;
            *FAILED*) bad "$line" ;;
            *) note "$line" ;;
        esac
    done <<< "$out"
    [ $rc -eq 3 ] && bad "AppleSMC could not be opened; charging state unknown"
    show_charging_state
    return $rc
}

# Live battery current (B0AC) and the pmset line; on AC below 100 % waits up to 10 s
# for current to flow.
show_charging_state() {
    local batt line pct cur i
    batt=$(pmset -g batt 2>/dev/null)
    line=$(printf '%s\n' "$batt" | batt_line)
    cur=$("$HELPER" current 2>/dev/null)
    case $batt in
        *"'AC Power'"*)
            pct=${line%%\%*}
            if [ "$pct" -lt 100 ] 2>/dev/null; then
                for ((i = 0; i < 10; i++)); do
                    [ "$cur" -gt 100 ] 2>/dev/null && break
                    sleep 1
                    cur=$("$HELPER" current 2>/dev/null)
                done
            fi
            if [ "$cur" -gt 100 ] 2>/dev/null; then
                ok "battery is charging: +$cur mA"
            else
                note "battery current ${cur:-unknown} mA: not charging right now. That can also come from a full battery or macOS Optimized Battery Charging; the key above is what battery-tool controlled."
            fi ;;
        *) note "on battery power (${cur:-unknown} mA); charging starts when a charger is connected" ;;
    esac
    note "pmset: ${line:-unavailable} (macOS refreshes this every ~60 s)"
}

# ---- step 2: Low Power Mode + process priorities -------------------------------------

lpm_now() {  # battery|ac
    local v
    v=$(pmset -g custom 2>/dev/null | lpm_from_custom)
    if [ "$1" = ac ]; then printf '%s' "${v#* }"; else printf '%s' "${v% *}"; fi
}

restore_from_record() {  # file [quiet]
    local file=$1 quiet=$2 src orig flag name now pid start ppid pri pass changed msg since cs
    local restored=" " n_ok=0 n_gone=0 n_fail=0 n_child=0 n_lines=0
    if [ ! -f "$file" ]; then
        [ -n "$quiet" ] || note "no change record: nothing to restore"
        return 0
    fi
    while read -r src orig; do
        n_lines=$((n_lines + 1))
        flag=-b name="on battery"
        [ "$src" = ac ] && flag=-c name="on AC power"
        if [ "$src" = ac ]; then LPM_EXPECT_AC=${LPM_EXPECT_AC:-$orig}; else LPM_EXPECT_BATTERY=${LPM_EXPECT_BATTERY:-$orig}; fi
        now=$(lpm_now "$src")
        if [ "$now" = "$orig" ]; then
            [ -n "$quiet" ] || ok "Low Power Mode $name: already $orig (the recorded original)"
            continue
        fi
        pmset $flag lowpowermode "$orig" >/dev/null 2>&1
        if [ "$(lpm_now "$src")" = "$orig" ]; then
            ok "Low Power Mode $name: $now → $orig (the recorded original)"
        else
            bad "Low Power Mode $name: could not restore $orig (now $(lpm_now "$src")); run: sudo pmset $flag lowpowermode $orig"
        fi
    done < <(record_lpm "$file")

    while read -r pid start; do
        n_lines=$((n_lines + 1))
        if [ "$(proc_start "$pid")" != "$start" ]; then n_gone=$((n_gone + 1)); continue; fi
        if taskpolicy -B -p "$pid" >/dev/null 2>&1; then
            n_ok=$((n_ok + 1)); restored+="$pid "
        elif [ -z "$(proc_start "$pid")" ]; then
            n_gone=$((n_gone + 1))
        else
            n_fail=$((n_fail + 1))
        fi
    done < <(record_procs "$file")
    # Children spawned while their parent was throttled inherited darwin-bg (ps pri 4); ones
    # started before extreme LPM was turned on were in the background for another reason.
    since=$(record_since "$file")
    for ((pass = 0; pass < 5 && n_ok > 0; pass++)); do
        changed=0
        while read -r pid ppid pri; do
            [ "$pri" = 4 ] || continue
            case $restored in *" $ppid "*) ;; *) continue ;; esac
            case $restored in *" $pid "*) continue ;; esac
            if [ -n "$since" ]; then
                cs=$(proc_start "$pid")
                [ -n "$cs" ] && [ "$cs" -ge "$since" ] || continue
            fi
            taskpolicy -B -p "$pid" >/dev/null 2>&1 && n_child=$((n_child + 1))
            restored+="$pid "
            changed=1
        done < <(ps -axo pid=,ppid=,pri= 2>/dev/null)
        [ $changed = 1 ] || break
    done
    [ $n_lines -gt 0 ] || { [ -n "$quiet" ] || note "change record is empty"; return 0; }
    [ -n "$quiet" ] && [ $((n_ok + n_child + n_fail)) -eq 0 ] && return 0
    msg="processes: $n_ok restored to normal priority"
    [ $n_child -gt 0 ] && msg+=", $n_child child processes"
    [ $n_gone -gt 0 ] && msg+=", $n_gone already exited"
    if [ $n_fail -gt 0 ]; then bad "$msg, $n_fail could not be restored"; else ok "$msg"; fi
    [ -n "$quiet" ] || PROC_SUMMARY=$msg
}

# ---- step 3: unload ---------------------------------------------------------------

unload() {
    local i u p pids alive uids
    if launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
        launchctl bootout "system/$DAEMON_LABEL" >/dev/null 2>&1
        for ((i = 0; i < 30; i++)); do
            launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1 || break
            sleep 1
        done
        if launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
            bad "daemon still loaded after 30 s"
        else
            ok "daemon stopped and unloaded"
        fi
    else
        note "daemon not loaded"
    fi
    # A daemon started by hand (any path, e.g. `sudo battery-tool daemon`) is not stopped by launchd
    # and would keep acting: find it by its lock file and its command line.
    pids=$( { lsof -t "$VAR_DIR/daemon.lock" 2>/dev/null; pgrep -f '(^|/)battery-tool daemon( |$)' 2>/dev/null; } | sort -u )
    if [ -n "$pids" ]; then
        kill -TERM $pids 2>/dev/null
        for ((i = 0; i < 20; i++)); do
            alive=""; for p in $pids; do kill -0 "$p" 2>/dev/null && alive+=" $p"; done
            [ -n "$alive" ] || break
            sleep 1
        done
        [ -n "$alive" ] && kill -KILL $alive 2>/dev/null
        ok "stopped a battery-tool daemon running outside launchd (pid $(one_line "$pids"))"
    fi
    # Every GUI session's menu agent (fast user switching), except the one that asked for this
    # uninstall: it shows the result and then unloads itself.
    uids=$( { printf '%s\n' "${T_UIDS[@]}"; ps -axo uid=,comm= 2>/dev/null | awk '$2 ~ /\/loginwindow$/ { print $1 }'; } |
        awk '/^[0-9]+$/ && $1 > 0' | sort -u )
    for u in $uids; do
        if [ $FROM_MENUBAR = 1 ] && [ "$u" = "$CONSOLE_UID" ]; then
            note "menu bar app: closes itself when this uninstall finishes"
            continue
        fi
        launchctl bootout "gui/$u/$MENU_LABEL" >/dev/null 2>&1 && ok "menu bar agent unloaded (uid $u)"
        pkill -U "$u" -f "^$MENU_APP/Contents/MacOS/BatteryTool" >/dev/null 2>&1 && ok "menu bar app closed (uid $u)"
    done
    return 0
}

# ---- steps 4-5: files -------------------------------------------------------------

remove_path() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then note "$1: already absent"; return 0; fi
    rm -rf "$1" 2>/dev/null
    if [ -e "$1" ] || [ -L "$1" ]; then bad "could not remove $1"; else ok "removed $1"; fi
}

remove_files() {
    local p d
    for p in "$DAEMON_PLIST" "$MENU_PLIST" "$BIN" "$LIB_DIR" "$CONFIG_DIR" "$VAR_DIR"; do remove_path "$p"; done
    # Parent folders the installer had to create: deepest first, only if empty.
    while IFS= read -r d; do
        case $d in /usr/local|/usr/local/*) ;; *) continue ;; esac
        case /$d/ in */../*|*/./*) continue ;; esac
        [ -d "$d" ] || continue
        if rmdir "$d" 2>/dev/null; then ok "removed empty $d (created by the installer)"; else note "kept $d (not empty)"; fi
    done < <(printf '%s\n' "$CREATED_DIRS" | sed '/^$/d' | sort -r -u)
}

# The menu bar app's preferences (only the status item position) for each target user.
remove_menu_prefs() {
    local i f
    for ((i = 0; i < ${#T_NAMES[@]}; i++)); do
        [ -n "${T_HOMES[i]}" ] || continue
        launchctl asuser "${T_UIDS[i]}" sudo -u "${T_NAMES[i]}" defaults delete "$MENU_LABEL" >/dev/null 2>&1
        f=${T_HOMES[i]}/Library/Preferences/$MENU_LABEL.plist
        if [ -e "$f" ] || [ -L "$f" ]; then remove_path "$f"; fi
    done
}

# ---- step 6: result -------------------------------------------------------------

# Judges the FINAL state (earlier transient failures don't count). Returns 1 on problems.
final_report() {
    local p left="" out rc b a lpm_ok=1 verdict=0
    for p in "$DAEMON_PLIST" "$MENU_PLIST" "$BIN" "$LIB_DIR" "$CONFIG_DIR" "$VAR_DIR" "$MENU_APP"; do
        [ -e "$p" ] || [ -L "$p" ] && left+=" $p"
    done
    # A daemon that could not be booted out keeps running (and launchd restarts it): not removed.
    launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1 && left+=" system/$DAEMON_LABEL (still loaded)"
    if [ -z "$left" ]; then ok "all battery-tool files and services removed (or already absent)"; else bad "still present:$left"; verdict=1; fi

    if [ -n "$HELPER" ]; then
        out=$("$HELPER" read CHTE CH0B CH0C 2>/dev/null); rc=$?
        if [ $rc -le 1 ] && printf '%s\n' "$out" | keys_enabled; then
            ok "charge-inhibit keys: $(one_line "$out") (charging enabled)"
        else
            bad "charging could not be verified: $(one_line "${out:-AppleSMC unavailable}")"; verdict=2
        fi
    else
        bad "charging could not be verified: no SMC helper"; verdict=2
    fi
    note "pmset: $(pmset -g batt 2>/dev/null | batt_line)"

    b=$(lpm_now battery) a=$(lpm_now ac)
    [ -z "$LPM_EXPECT_BATTERY" ] || [ "$b" = "$LPM_EXPECT_BATTERY" ] || lpm_ok=0
    [ -z "$LPM_EXPECT_AC" ] || [ "$a" = "$LPM_EXPECT_AC" ] || lpm_ok=0
    p="macOS Low Power Mode: battery $b · AC $a"
    if [ -n "$LPM_EXPECT_BATTERY$LPM_EXPECT_AC" ]; then
        p+=" (recorded originals: battery ${LPM_EXPECT_BATTERY:-unchanged} · AC ${LPM_EXPECT_AC:-unchanged})"
    else
        p+=" (no recorded change left to restore)"
    fi
    if [ $lpm_ok = 1 ]; then ok "$p"; else bad "$p"; [ $verdict -gt 0 ] || verdict=1; fi
    note "${PROC_SUMMARY:-processes: no recorded change left to restore}"

    say ""
    case $verdict in
        0) say "Charging and power settings are back to normal." ;;
        1) say "✖ Charging is enabled, but the uninstall left problems (✖ above)." ;;
        *) say "✖ CHARGING COULD NOT BE VERIFIED. If the Mac does not charge, shut it down completely,"
           say "  wait 30 seconds and start it again, then run this uninstaller once more." ;;
    esac
    [ $verdict -eq 0 ]
}

# ---- --from-daemon extras ------------------------------------------------------------

# Writes $REPORT to DIR/REPORT_NAME without following links an unprivileged user planted
# (DIR itself or the file). The report stays root-owned 0644: chowning it to the user
# would hand them a file wherever a swapped-in Desktop symlink pointed.
write_report() {  # dir
    local tmp
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    tmp=$(mktemp "$1/.battery-tool-report.XXXXXX" 2>/dev/null) || return 1
    # Only in root-owned, sticky /Users/Shared may the file go to the user (nobody can swap it there).
    [ "$1" = /Users/Shared ] && [ -n "$CONSOLE_USER" ] && chown -h "$CONSOLE_USER" "$tmp" 2>/dev/null
    if printf '%s' "$REPORT" > "$tmp" 2>/dev/null && chmod 644 "$tmp" && rm -f "$1/$REPORT_NAME" 2>/dev/null &&
        mv -f "$tmp" "$1/$REPORT_NAME" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
}

daemon_extras() {  # uninstall succeeded (0/1)
    local i f written="" msg
    for ((i = 0; i < ${#T_HOMES[@]}; i++)); do
        f=${T_HOMES[i]}/Desktop/$SENTINEL_NAME
        [ -n "${T_HOMES[i]}" ] && { [ -e "$f" ] || [ -L "$f" ]; } || continue
        rm -f "$f" 2>/dev/null
        if [ -e "$f" ]; then bad "could not delete $f (macOS privacy protection); please delete it yourself"; LEFT_SENTINEL=1
        else ok "deleted $f"; fi
    done
    for ((i = 0; i < ${#T_HOMES[@]}; i++)); do
        [ -n "${T_HOMES[i]}" ] && write_report "${T_HOMES[i]}/Desktop" &&
            written+=" ${T_HOMES[i]}/Desktop/$REPORT_NAME"
    done
    [ -n "$written" ] || { write_report /Users/Shared && written=" /Users/Shared/$REPORT_NAME"; }
    [ -n "$written" ] && say "Report saved to:$written"
    case $CONSOLE_UID in ''|0|*[!0-9]*) return 0 ;; esac
    if [ "$1" = 0 ]; then msg="Charging and power settings are back to normal."; else msg="Finished with problems."; fi
    [ "$LEFT_SENTINEL" = 1 ] && msg+=" Please delete $SENTINEL_NAME from your Desktop."
    [ -z "$written" ] || msg+=" Report:$written"
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" osascript \
        -e "display notification \"$(as_escape "$msg")\" with title \"Battery Tool uninstalled\"" >/dev/null 2>&1 &
}

# ---- main ---------------------------------------------------------------------

add_target() {  # name uid home
    local u
    case $1 in ''|root|loginwindow|_mbsetupuser) return 0 ;; esac
    case $2 in ''|0|*[!0-9]*) return 0 ;; esac
    for u in "${T_UIDS[@]}"; do [ "$u" = "$2" ] && return 0; done
    T_NAMES+=("$1") T_UIDS+=("$2") T_HOMES+=("$3")
}

collect_targets() {
    local name uid home i
    name=$(manifest_values user "$MANIFEST" | head -n 1)
    uid=$(manifest_values uid "$MANIFEST" | head -n 1)
    home=$(manifest_values home "$MANIFEST" | head -n 1)
    [ -n "$uid" ] || uid=$(id -u "$name" 2>/dev/null)
    [ -n "$home" ] || home=$(user_home "$name")
    add_target "$name" "$uid" "$home"
    CONSOLE_USER=$(stat -f %Su /dev/console 2>/dev/null)
    CONSOLE_UID=$(stat -f %u /dev/console 2>/dev/null)
    case $CONSOLE_USER in root|loginwindow|_mbsetupuser) CONSOLE_USER="" CONSOLE_UID="" ;; esac
    add_target "$CONSOLE_USER" "$CONSOLE_UID" "$(user_home "$CONSOLE_USER")"
    for ((i = 0; i < ${#T_NAMES[@]}; i++)); do note "user: ${T_NAMES[i]} (uid ${T_UIDS[i]}, ${T_HOMES[i]:-home unknown})"; done
}

cleanup() { [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"; }

main() {
    local arg rc
    # The caller's folder may be unreadable for root (e.g. ~/Documents under macOS privacy rules).
    cd / 2>/dev/null
    trap '' HUP PIPE
    if [ "$(id -u)" -ne 0 ]; then exec sudo /bin/bash "$0" "$@"; fi
    for arg in "$@"; do
        case $arg in
            --from-daemon) FROM_DAEMON=1 ;;
            --from-menubar) FROM_MENUBAR=1 ;;
            --yes|-y) ;;
            *) echo "usage: uninstall.sh [--yes] [--from-daemon | --from-menubar]" >&2; exit 2 ;;
        esac
    done
    [ $FROM_DAEMON = 1 ] || [ $FROM_MENUBAR = 1 ] && trap '' TERM INT
    umask 022
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
    TMPD=$(mktemp -d /tmp/battery-tool-uninstall.XXXXXX 2>/dev/null) || TMPD=""
    trap cleanup EXIT

    say "Battery Tool uninstall, $(date '+%Y-%m-%d %H:%M:%S')"
    collect_targets
    CREATED_DIRS=$(manifest_values created_dir "$MANIFEST")

    say ""
    say "1) Re-enable charging"
    resolve_helper || HELPER=""
    enable_charging

    say ""
    say "2) Restore Low Power Mode and process priorities"
    restore_from_record "$CHANGES"

    say ""
    say "3) Stop battery-tool"
    unload
    # The daemon may have acted (or restored on SIGTERM) in between: check again.
    enable_charging quiet
    restore_from_record "$CHANGES" quiet
    rm -f "$CHANGES" 2>/dev/null

    say ""
    say "4) Remove files"
    remove_files

    say ""
    say "5) Remove the menu bar app"
    remove_path "$MENU_APP"
    remove_menu_prefs

    say ""
    say "6) Result"
    final_report; rc=$?
    [ $FROM_DAEMON = 1 ] && daemon_extras $rc
    exit $rc
}

# ---- embedded SMC helper (single source of truth; build.sh extracts it) ---------

smc_helper_source() {
    cat <<'EOF_SMC_HELPER'
// smc-helper: minimal AppleSMC tool used by uninstall.sh, written from the public
// IOKit AppleSMC user-client interface (same parameter block as Sources/CSMC/smc.c).
// Reads work as any user; writes need root. Never writes any key except the
// charge-inhibit keys below, and only ever to their "charging enabled" value.
//   smc-helper read KEY...       KEY=HEX, KEY=absent (no such key) or KEY=error
//   smc-helper enable-charging   CHTE->00000000, CH0B->00, CH0C->00 for each key that
//                                exists: write if needed, read back, print KEY=HEX ok|FAILED
//   smc-helper current           battery current in mA from B0AC (+ = charging) or "unknown"
// Exit: 0 ok, 1 failure, 2 usage, 3 AppleSMC cannot be opened.
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum { SMC_SELECTOR = 2, CMD_READ_BYTES = 5, CMD_WRITE_BYTES = 6, CMD_READ_KEYINFO = 9, KEY_NOT_FOUND = 132 };

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } smc_vers;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } smc_plimit;
typedef struct { uint32_t data_size, data_type; uint8_t attributes; } smc_keyinfo;
typedef struct {
    uint32_t key;
    smc_vers vers;
    smc_plimit plimit;
    smc_keyinfo info;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param;
_Static_assert(sizeof(smc_param) == 80, "AppleSMC parameter block must be 80 bytes");

static io_connect_t conn = IO_OBJECT_NULL;

static uint32_t fourcc(const char *k) {
    return (uint32_t)(uint8_t)k[0] << 24 | (uint32_t)(uint8_t)k[1] << 16 |
           (uint32_t)(uint8_t)k[2] << 8 | (uint32_t)(uint8_t)k[3];
}

// 0 = success, KEY_NOT_FOUND = no such key, anything else = error (-1 for IOKit).
static int call(const smc_param *in, smc_param *out) {
    size_t size = sizeof *out;
    memset(out, 0, sizeof *out);
    if (IOConnectCallStructMethod(conn, SMC_SELECTOR, in, sizeof *in, out, &size) != KERN_SUCCESS) return -1;
    return out->result;
}

static int key_size(const char *key, uint32_t *size) {
    smc_param in = {0}, out;
    in.key = fourcc(key);
    in.data8 = CMD_READ_KEYINFO;
    int r = call(&in, &out);
    if (r == 0) *size = out.info.data_size;
    return r;
}

static int read_key(const char *key, uint8_t buf[32], uint32_t *size) {
    int r = key_size(key, size);
    if (r) return r;
    if (*size == 0 || *size > 32) return -1;
    smc_param in = {0}, out;
    in.key = fourcc(key);
    in.info.data_size = *size;
    in.data8 = CMD_READ_BYTES;
    r = call(&in, &out);
    if (r == 0) memcpy(buf, out.bytes, *size);
    return r;
}

static int write_key(const char *key, const uint8_t *data, uint32_t size) {
    smc_param in = {0}, out;
    in.key = fourcc(key);
    in.info.data_size = size;
    in.data8 = CMD_WRITE_BYTES;
    memcpy(in.bytes, data, size);
    return call(&in, &out);
}

static void print_value(const char *key, const uint8_t *b, uint32_t n, const char *suffix) {
    printf("%s=", key);
    for (uint32_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("%s\n", suffix);
}

static int cmd_read(int n, char **keys) {
    int rc = 0;
    for (int i = 0; i < n; i++) {
        uint8_t buf[32];
        uint32_t size = 0;
        if (strlen(keys[i]) != 4) { fprintf(stderr, "smc-helper: invalid key '%s'\n", keys[i]); rc = 2; continue; }
        int r = read_key(keys[i], buf, &size);
        if (r == KEY_NOT_FOUND) printf("%s=absent\n", keys[i]);
        else if (r) { printf("%s=error\n", keys[i]); if (!rc) rc = 1; }
        else print_value(keys[i], buf, size, "");
    }
    return rc;
}

// Charging is enabled when every charge-inhibit key that exists reads all zero.
static int cmd_enable_charging(void) {
    static const struct { const char *key; uint32_t size; } keys[] = { {"CHTE", 4}, {"CH0B", 1}, {"CH0C", 1} };
    static const uint8_t zero[32];
    int present = 0, failed = 0;
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) {
        const char *key = keys[i].key;
        uint8_t buf[32];
        uint32_t size = 0;
        int r = read_key(key, buf, &size);
        if (r == KEY_NOT_FOUND) continue;
        present++;
        if (r) { printf("%s=error FAILED\n", key); failed++; continue; }
        if (size != keys[i].size) {   // not a layout battery-tool ever writes: leave it alone
            char note[64];
            snprintf(note, sizeof note, " skipped (size %u, expected %u)", size, keys[i].size);
            print_value(key, buf, size, note);
            continue;
        }
        for (int attempt = 0; attempt < 3 && r == 0 && memcmp(buf, zero, size) != 0; attempt++) {
            if (attempt) usleep(300000);
            int w = write_key(key, zero, size);
            if (w) fprintf(stderr, "smc-helper: writing %s failed (%d)%s\n", key, w, geteuid() ? "; needs root" : "");
            r = read_key(key, buf, &size);
        }
        if (r) { printf("%s=error FAILED\n", key); failed++; continue; }
        int ok = memcmp(buf, zero, size) == 0;
        print_value(key, buf, size, ok ? " ok" : " FAILED");
        if (!ok) failed++;
    }
    if (!present) printf("note: no charge-inhibit key (CHTE, CH0B, CH0C) on this Mac\n");
    return failed ? 1 : 0;
}

static int cmd_current(void) {
    uint8_t buf[32];
    uint32_t size = 0;
    if (read_key("B0AC", buf, &size) != 0 || size != 2) { printf("unknown\n"); return 1; }
    printf("%d\n", (int16_t)(buf[0] | buf[1] << 8));   // si16, little-endian
    return 0;
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "";
    int is_read = !strcmp(cmd, "read") && argc > 2;
    int is_simple = argc == 2 && (!strcmp(cmd, "enable-charging") || !strcmp(cmd, "current"));
    if (!is_read && !is_simple) {
        fprintf(stderr, "usage: smc-helper read KEY... | enable-charging | current\n");
        return 2;
    }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    kern_return_t kr = svc ? IOServiceOpen(svc, mach_task_self(), 0, &conn) : kIOReturnNotFound;
    if (svc) IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "smc-helper: cannot open AppleSMC (0x%x)\n", kr); return 3; }
    int rc = is_read ? cmd_read(argc - 2, argv + 2) : !strcmp(cmd, "current") ? cmd_current() : cmd_enable_charging();
    IOServiceClose(conn);
    return rc;
}
EOF_SMC_HELPER
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
