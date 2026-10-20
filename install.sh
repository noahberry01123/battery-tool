#!/bin/bash
# battery-tool installer: copies build/ (run ./build.sh first) into place and starts
# the root daemon and the menu bar agent. Needs root (re-runs itself with sudo).
# Safe to re-run: a running install is stopped first and config.json is kept.
# Undo with: sudo /usr/local/lib/battery-tool/uninstall.sh

# Installed layout; keep in sync with Sources/Shared/Paths.swift and uninstall.sh.
BIN=/usr/local/bin/battery-tool
LIB_DIR=/usr/local/lib/battery-tool
MANIFEST=$LIB_DIR/install-manifest.txt
CONFIG_DIR=/usr/local/etc/battery-tool
CONFIG_FILE=$CONFIG_DIR/config.json
VAR_DIR=/usr/local/var/battery-tool
LOG_DIR=$VAR_DIR/log
STATUS_FILE=$VAR_DIR/status.json
DAEMON_LABEL=local.battery-tool.daemon
DAEMON_PLIST=/Library/LaunchDaemons/$DAEMON_LABEL.plist
MENU_LABEL=local.battery-tool.menubar
MENU_PLIST=/Library/LaunchAgents/$MENU_LABEL.plist
MENU_APP=/Applications/BatteryTool.app
SENTINEL_NAME=UNINSTALL-BATTERY-TOOL

export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
ROOT=""

# Default config.json, identical to `Config().encoded()` (Sources/Shared/Config.swift).
default_config() {
    cat <<'EOF'
{
  "charge_limit" : {
    "max_percent" : 80,
    "resume_percent" : 75
  },
  "duty_cycle" : {
    "enabled" : false,
    "off_seconds" : 60,
    "on_seconds" : 30,
    "warm_c" : 32
  },
  "enabled" : true,
  "heat_guard" : {
    "limit_c" : 35
  },
  "lowpower" : {
    "audio_grace_seconds" : 10,
    "audio_protect_scope" : "pid_active",
    "audio_safe_mode" : true,
    "auto_trigger" : {
      "enabled" : false,
      "temp_c" : 40
    },
    "enabled" : false,
    "protected" : [
      "Finder",
      "Dock",
      "Terminal",
      "@frontmost"
    ],
    "scan_interval_seconds" : 5
  },
  "paused" : false,
  "poll_interval_seconds" : 5,
  "probe_request" : 0,
  "revision" : 0
}
EOF
}

# Ancestors of a path that do not exist yet (created now, removed again by uninstall.sh).
missing_parents() {
    local p
    p=$(dirname "$1")
    while [ ! -d "$p" ]; do
        echo "$p"
        p=$(dirname "$p")
    done
}

# Values of every `KEY=value` line for KEY in an install manifest, in file order.
manifest_values() {  # key file
    local line
    [ -r "$2" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in "$1="*) printf '%s\n' "${line#*=}" ;; esac
    done < "$2"
}

# install-manifest.txt (reader: Sources/battery-tool/System.swift).
manifest_text() {  # version user uid home created_dirs(newline-separated)
    printf 'version=%s\nuser=%s\nuid=%s\nhome=%s\ninstalled_at=%s\n' "$1" "$2" "$3" "$4" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$5" | sed '/^$/d' | sort -u | sed 's/^/created_dir=/'
}

console_user() {
    local u
    u=$(stat -f %Su /dev/console 2>/dev/null) || return 1
    case $u in ''|root|loginwindow|_mbsetupuser) return 1 ;; esac
    echo "$u"
}

# Home folder of a user from the directory service ("" if unknown).
user_home() {
    [ -n "$1" ] || return 0
    dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null |
        awk '{ sub(/^NFSHomeDirectory:/, ""); sub(/^[ \t]+/, ""); if ($0 != "") { print; exit } }'
}

json_value() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; }

die() { echo "✖ $*" >&2; exit 1; }

on_error() {
    echo "✖ install failed at line $1. To remove whatever was installed, run:" >&2
    echo "    sudo /bin/bash \"$ROOT/uninstall.sh\"" >&2
}

main() {
    set -euo pipefail
    if [ "$(id -u)" -ne 0 ]; then exec sudo /bin/bash "$0" "$@"; fi
    umask 022
    local build version user uid home cuser cuid h d f created t0 i ts mode pid
    ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    cd /    # the caller's folder may be unreadable for root (e.g. ~/Documents under macOS privacy rules)
    build=$ROOT/build
    trap 'on_error $LINENO' ERR

    for f in "$build/battery-tool" "$build/smc-helper" "$build/BatteryTool.app/Contents/MacOS/BatteryTool" \
             "$build/BatteryTool.app/Contents/Info.plist" "$ROOT/uninstall.sh" \
             "$ROOT/launchd/$DAEMON_LABEL.plist" "$ROOT/launchd/$MENU_LABEL.plist"; do
        [ -f "$f" ] || die "missing $f; run ./build.sh first"
    done
    [ -f "$build/.selftest-ok" ] || die "build/ did not pass its self-test; run ./build.sh and fix the failures first"
    version=$(json_value CFBundleShortVersionString "$build/BatteryTool.app/Contents/Info.plist")
    [ -n "$version" ] || die "cannot read the version from build/BatteryTool.app"

    user=${SUDO_USER:-}
    if [ -z "$user" ] || [ "$user" = root ]; then
        user=$(console_user) || die "cannot tell which user to install for; run ./install.sh from your own account"
    fi
    uid=$(id -u "$user") || die "unknown user $user"
    home=$(user_home "$user" || true)
    [ -n "$home" ] && [ -d "$home" ] || die "cannot find the home folder of $user"
    cuser=$(console_user || true)
    cuid=""
    if [ -n "$cuser" ]; then cuid=$(id -u "$cuser" 2>/dev/null || true); fi
    for h in "$home" "$(user_home "$cuser")"; do
        if [ -n "$h" ] && [ -e "$h/Desktop/$SENTINEL_NAME" ]; then
            die "$h/Desktop/$SENTINEL_NAME exists (it tells battery-tool to uninstall itself); delete it first"
        fi
    done
    echo "Installing battery-tool $version for $user (uid $uid)"

    # Stop a previous install; its daemon re-enables charging and restores settings on exit.
    if launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
        echo "• stopping the running daemon"
        launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
        for ((i = 0; i < 40; i++)); do
            launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1 || break
            sleep 1
        done
        if launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then die "the running daemon did not stop within 40 s"; fi
        # If launchd had to kill it, charging may still be blocked; don't leave it so if this install stops early.
        "$build/smc-helper" enable-charging >/dev/null 2>&1 || true
    fi
    for i in $uid $cuid; do launchctl bootout "gui/$i/$MENU_LABEL" 2>/dev/null || true; done
    pkill -f "^$MENU_APP/Contents/MacOS/BatteryTool" 2>/dev/null || true

    echo "• folders"
    created=$(manifest_values created_dir "$MANIFEST")   # parents an earlier install created
    for d in "$BIN" "$LIB_DIR" "$CONFIG_DIR" "$VAR_DIR"; do
        created+=$'\n'$(missing_parents "$d")
    done
    mkdir -p "$(dirname "$BIN")"
    install -d -o root -g wheel -m 0755 "$LIB_DIR" "$VAR_DIR" "$LOG_DIR"
    install -d -o root -g admin -m 0775 "$CONFIG_DIR"
    manifest_text "$version" "$user" "$uid" "$home" "$created" > "$MANIFEST.tmp"
    chmod 0644 "$MANIFEST.tmp"
    mv -f "$MANIFEST.tmp" "$MANIFEST"

    echo "• files"
    install -o root -g wheel -m 0755 "$build/battery-tool" "$BIN"
    install -o root -g wheel -m 0755 "$build/smc-helper" "$LIB_DIR/smc-helper"
    install -o root -g wheel -m 0755 "$ROOT/uninstall.sh" "$LIB_DIR/uninstall.sh"
    install -o root -g wheel -m 0644 "$ROOT/launchd/$DAEMON_LABEL.plist" "$DAEMON_PLIST"
    install -o root -g wheel -m 0644 "$ROOT/launchd/$MENU_LABEL.plist" "$MENU_PLIST"
    rm -rf "$MENU_APP"
    ditto "$build/BatteryTool.app" "$MENU_APP"
    chown -R root:admin "$MENU_APP"
    chmod -R u=rwX,go=rX "$MENU_APP"
    # The config folder is admin-writable, so never write, chown or chmod through a path there (a
    # planted symlink or hard link could redirect it): build the file in the root-only lib folder,
    # reading an existing config as the user (no root-only file can be copied out), then rename it in.
    f=$(mktemp "$LIB_DIR/.config.json.XXXXXX")
    if [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] && sudo -u "$user" /bin/cat "$CONFIG_FILE" > "$f" 2>/dev/null && [ -s "$f" ]; then
        echo "  keeping existing $CONFIG_FILE"
    else
        default_config > "$f"
    fi
    chown root:admin "$f"
    chmod 0664 "$f"
    mv -fh "$f" "$CONFIG_FILE"

    echo "• starting"
    t0=$(date +%s)
    launchctl bootstrap system "$DAEMON_PLIST"
    if [ -n "$cuser" ] && [ "$cuser" = "$user" ]; then
        launchctl bootstrap "gui/$uid" "$MENU_PLIST" || echo "  – the menu bar app could not start now; it starts at your next login"
    else
        echo "  – $user is not logged in at the screen; the menu bar app starts at their next login"
    fi

    ts=""
    for ((i = 0; i < 20; i++)); do
        sleep 1
        ts=$(json_value updated_at "$STATUS_FILE")
        mode=$(json_value mode "$STATUS_FILE")
        if [ -n "$ts" ] && [ "${ts%%.*}" -ge "$t0" ] 2>/dev/null && [ "$mode" != stopped ]; then break; fi
        ts=""
    done
    if [ -z "$ts" ]; then
        echo "✖ the daemon did not report its status within 20 s. Recent log lines:" >&2
        tail -n 15 "$LOG_DIR/daemon.out.log" "$LOG_DIR/battery-tool.log" 2>/dev/null >&2 || true
        echo "  To remove battery-tool: sudo /bin/bash $LIB_DIR/uninstall.sh" >&2
        exit 1
    fi
    pid=$(launchctl print "system/$DAEMON_LABEL" 2>/dev/null | awk '$1 == "pid" && $2 == "=" { print $3; exit }' || true)

    echo
    echo "✔ battery-tool $version installed; daemon running (pid ${pid:-?}, mode $mode)"
    echo "  charging: $(json_value charging.reason "$STATUS_FILE")"
    echo "  SMC key:  $(json_value charging.key "$STATUS_FILE") (verified on this macOS: $(json_value charging.key_verified "$STATUS_FILE"))"
    echo
    echo "  Try: battery-tool status | set-limit 80 | set-temp 35 | pause | lowpower on | help"
    echo "  Uninstall: menu bar → Uninstall and Restore Normal Charging…, or battery-tool uninstall,"
    echo "    or sudo $LIB_DIR/uninstall.sh, or create a file named $SENTINEL_NAME on your Desktop."
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
