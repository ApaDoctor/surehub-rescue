#!/bin/bash
# surehub-rescue: get an old Sure Petcare hub online through a Mac so it can update its firmware.
#
# Usage:  sudo ./hub-up.sh [HUB_INTERFACE] [INTERNET_INTERFACE]
#   HUB_INTERFACE       wired port the hub is plugged into (default: auto-detect)
#   INTERNET_INTERFACE  interface the Mac uses for internet (default: from default route)
#
# Undo with: sudo ./hub-down.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$DIR/.state"
CAP="$DIR/captures"
GW=192.168.77.1
NET=192.168.77.0/24
ANCHOR=com.apple/250.SureHubRescue
RUN_USER="${SUDO_USER:-$(whoami)}"

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0 $*"
[ "$(uname)" = "Darwin" ] || die "this script is for macOS (see README for Linux/router notes)"

PY="${PYTHON:-$(command -v python3 || true)}"
[ -x "$PY" ] || die "python3 not found (install Xcode Command Line Tools or Homebrew python)"

# --- pick interfaces ---------------------------------------------------------
detect_hub_if() {
  # first wired (non-Wi-Fi) hardware port that has link but no IPv4 address
  networksetup -listallhardwareports | awk '
    /^Hardware Port:/ {port=$0}
    /^Device:/ {print port "|" $2}' |
  while IFS='|' read -r port dev; do
    case "$port" in *Wi-Fi*|*Bluetooth*|*Thunderbolt\ Bridge*|*Thunderbolt\ [0-9]*) continue;; esac
    ifconfig "$dev" 2>/dev/null | grep -q "status: active" || continue
    ifconfig "$dev" | grep -q "inet " && continue
    echo "$dev"; break
  done
}

HUB_IF="${1:-$(detect_hub_if)}"
WAN_IF="${2:-$(route -n get -inet default 2>/dev/null | awk '/interface:/ {print $2}')}"
[ -n "$HUB_IF" ] || die "no wired port with a link found. Plug the hub in (and power it), wait ~10s, retry. Or pass the interface: sudo $0 en7"
[ -n "$WAN_IF" ] || die "could not find the Mac's internet interface; pass it as 2nd argument, e.g. sudo $0 $HUB_IF en0"
[ "$HUB_IF" != "$WAN_IF" ] || die "hub interface and internet interface are the same ($HUB_IF)"
ifconfig "$HUB_IF" | grep -q "status: active" || echo "WARNING: $HUB_IF has no link yet (is the hub powered and plugged in?)"

echo "Hub port:      $HUB_IF"
echo "Internet via:  $WAN_IF"

mkdir -p "$CAP/streams"
chown "$RUN_USER" "$CAP" "$CAP/streams" 2>/dev/null || true

# --- save state so hub-down.sh can restore -----------------------------------
if [ ! -f "$STATE" ]; then
  {
    echo "HUB_IF=$HUB_IF"
    echo "PREV_FORWARDING=$(sysctl -n net.inet.ip.forwarding)"
    if [ -f /etc/bootpd.plist ]; then
      cp /etc/bootpd.plist "$DIR/.bootpd.plist.backup"
      echo "BOOTPD_BACKUP=1"
    else
      echo "BOOTPD_BACKUP=0"
    fi
  } > "$STATE"
fi

# --- 1. address on the hub-facing port ---------------------------------------
ifconfig "$HUB_IF" inet "$GW" netmask 255.255.255.0 up

# --- 2. routing + NAT (in its own pf anchor; system rules untouched) ---------
sysctl -qw net.inet.ip.forwarding=1
echo "nat on $WAN_IF inet from $NET to any -> ($WAN_IF)" | pfctl -q -a "$ANCHOR" -f - 2>/dev/null
pfctl -q -E 2>/dev/null || true

# --- 3. DHCP (macOS built-in bootpd); DNS points at our dns.py ---------------
cat > /etc/bootpd.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>bootp_enabled</key><false/>
  <key>dhcp_enabled</key><array><string>$HUB_IF</string></array>
  <key>Subnets</key><array><dict>
    <key>name</key><string>surehub-rescue</string>
    <key>net_address</key><string>192.168.77.0</string>
    <key>net_mask</key><string>255.255.255.0</string>
    <key>net_range</key><array><string>192.168.77.10</string><string>192.168.77.50</string></array>
    <key>allocate</key><true/>
    <key>dhcp_router</key><string>$GW</string>
    <key>dhcp_domain_name_server</key><array><string>$GW</string></array>
  </dict></array>
</dict></plist>
PLIST
launchctl unload /System/Library/LaunchDaemons/bootps.plist 2>/dev/null || true
launchctl load -w /System/Library/LaunchDaemons/bootps.plist

# --- 4. services (launchd jobs so they survive this shell) -------------------
for j in surehub.dns surehub.relay443 surehub.relay80 surehub.tcpdump; do
  launchctl remove "$j" 2>/dev/null || true
done
sleep 1

launchctl submit -l surehub.dns -o "$CAP/dns.log" -e "$CAP/dns.log" -- \
  "$PY" -I "$DIR/dns.py"
launchctl submit -l surehub.relay443 -o "$CAP/relay443.log" -e "$CAP/relay443.log" -- \
  /usr/bin/env RELAY_PORT=443 "$PY" -I "$DIR/relay.py"
launchctl submit -l surehub.relay80 -o "$CAP/relay80.log" -e "$CAP/relay80.log" -- \
  /usr/bin/env RELAY_PORT=80 "$PY" -I "$DIR/relay.py"

if [ "${NO_CAPTURE:-0}" != "1" ]; then
  TS=$(date +%Y%m%d-%H%M%S)
  launchctl submit -l surehub.tcpdump -- \
    /usr/sbin/tcpdump -i "$HUB_IF" -n -s0 -U -Z "$RUN_USER" -w "$CAP/hub-$TS.pcap"
fi

sleep 2
for j in surehub.dns surehub.relay443 surehub.relay80; do
  launchctl list "$j" 2>/dev/null | grep -q '"PID"' || die "$j failed to start; see $CAP/${j#surehub.}.log"
done

cat <<EOF

Ready. Now:
  1. Unplug the hub's power for 5 seconds and plug it back in.
  2. Watch progress:   ./status.sh        (no sudo needed)
  3. Do NOT unplug the hub while it downloads firmware (~5-10 minutes).
When status says the hub reached the cloud, it's fixed. Undo with: sudo ./hub-down.sh
EOF
