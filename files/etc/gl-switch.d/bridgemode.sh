#!/bin/sh
# opal-bridge gl-switch hook (hot-toggle path; the boot-time read is primary).
# Verified on device 2026-07-25: slide to hi logs "released" -> action "off",
# slide to lo logs "pressed" -> action "on".
# User convention: hi = BRIDGE, lo = ROUTER, hence the inverted-looking map.
# Transitions are hot (no reboot); opal-mode no-ops when already in the mode.

# ignore events replayed by the input layer before apply-boot has run
[ -f /tmp/opal-mode.boot-done ] || exit 0

case "$1" in
    off) /usr/bin/opal-mode bridge ;;
    on)  /usr/bin/opal-mode router ;;
esac
