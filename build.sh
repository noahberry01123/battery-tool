#!/bin/bash
# Builds battery-tool into build/ (no root needed; safe to re-run from any folder):
#   build/battery-tool     CLI + daemon
#   build/smc-helper       from the C source embedded in uninstall.sh (single source of truth)
#   build/BatteryTool.app  menu bar app (Resources/uninstall.sh = copy of uninstall.sh)
# All three are ad-hoc signed; then the built-in self-test runs.

# Info.plist of the menu bar app.
info_plist() {  # version
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>local.battery-tool.menubar</string>
	<key>CFBundleExecutable</key>
	<string>BatteryTool</string>
	<key>CFBundleName</key>
	<string>Battery Tool</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$1</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
</dict>
</plist>
EOF
}

main() {
    set -euo pipefail
    local root build app version
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    build=$root/build
    app=$build/BatteryTool.app
    version=$(sed -n 's/^ *static let version = "\(.*\)"$/\1/p' "$root/Sources/Shared/Paths.swift")
    [ -n "$version" ] || { echo "cannot read the version from Sources/Shared/Paths.swift" >&2; exit 1; }

    rm -rf "$build"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

    echo "• battery-tool $version"
    clang -O2 -c "$root/Sources/CSMC/smc.c" -o "$build/smc.o"
    swiftc -swift-version 5 -O -import-objc-header "$root/Sources/CSMC/bridge.h" \
        "$root"/Sources/Shared/*.swift "$root"/Sources/battery-tool/*.swift "$build/smc.o" \
        -framework CoreAudio -o "$build/battery-tool"

    echo "• smc-helper"
    /bin/bash -c 'source "$1"; smc_helper_source' _ "$root/uninstall.sh" > "$build/smc-helper.c"
    [ -s "$build/smc-helper.c" ] || { echo "could not extract the SMC helper source from uninstall.sh" >&2; exit 1; }
    clang -O2 -Wall -o "$build/smc-helper" "$build/smc-helper.c" -framework IOKit

    echo "• BatteryTool.app"
    swiftc -swift-version 5 -O "$root"/Sources/Shared/*.swift "$root"/Sources/menubar/*.swift \
        -framework AppKit -o "$app/Contents/MacOS/BatteryTool"
    info_plist "$version" > "$app/Contents/Info.plist"
    cp "$root/uninstall.sh" "$app/Contents/Resources/uninstall.sh"

    echo "• ad-hoc signing"
    codesign --force --sign - "$build/battery-tool" "$build/smc-helper" "$app"

    echo "• selftest"
    "$build/battery-tool" selftest
    : > "$build/.selftest-ok"            # install.sh refuses a build without it
    echo "✔ built into $build; install with: sudo ./install.sh"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
