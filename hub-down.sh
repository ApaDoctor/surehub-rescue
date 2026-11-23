#!/bin/bash
# surehub-rescue: undo everything hub-up.sh did. Captures in ./captures are kept.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$DIR/.state"
ANCHOR=com.apple/250.SureHubRescue
[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }

HUB_IF=""; PREV_FORWARDING=0; BOOTPD_BACKUP=0
# shellcheck disable=SC1090
[ -f "$STATE" ] && . "$STATE"

for j in surehub.dns surehub.relay443 surehub.relay80 surehub.tcpdump; do
  launchctl remove "$j" 2>/dev/null || true
done

pfctl -q -a "$ANCHOR" -F all 2>/dev/null || true
sysctl -qw net.inet.ip.forwarding="${PREV_FORWARDING:-0}"

launchctl unload -w /System/Library/LaunchDaemons/bootps.plist 2>/dev/null || true
if [ "${BOOTPD_BACKUP:-0}" = "1" ] && [ -f "$DIR/.bootpd.plist.backup" ]; then
  mv "$DIR/.bootpd.plist.backup" /etc/bootpd.plist
else
  rm -f /etc/bootpd.plist
fi

[ -n "$HUB_IF" ] && ifconfig "$HUB_IF" inet 192.168.77.1 delete 2>/dev/null
rm -f "$STATE"
echo "Done. Everything is back to normal. Captures kept in $DIR/captures/"
