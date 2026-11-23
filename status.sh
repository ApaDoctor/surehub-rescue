#!/bin/bash
# surehub-rescue: show what each connected hub is doing. No sudo needed.
# Usage: ./status.sh          (one-shot)
#        ./status.sh --watch  (refresh every 5s, Ctrl-C to stop)
DIR="$(cd "$(dirname "$0")" && pwd)"
CAP="$DIR/captures"

# count lines containing a fixed string; 0 if the file doesn't exist yet
count() { local n=0; [ -f "$2" ] && n=$(grep -cF -- "$1" "$2"); echo "${n:-0}"; }

show() {
  echo "surehub-rescue status  $(date +%H:%M:%S)"
  echo
  if ! pgrep -qf "$DIR/dns.py" || [ "$(pgrep -f "$DIR/relay.py" | wc -l)" -lt 2 ]; then
    echo "  ! services not running - start with: sudo ./hub-up.sh"; echo
  fi

  hubs=$( (grep -ho '192\.168\.77\.[0-9]*' "$CAP/dns.log" 2>/dev/null; \
           arp -an 2>/dev/null | grep -o '192\.168\.77\.[0-9]*') | grep -v '^192\.168\.77\.1$' | sort -u -t. -k4,4n)
  if [ -z "$hubs" ]; then
    echo "  No hub seen yet. Power-cycle the hub (unplug 5s) and wait ~30s."
    return
  fi

  for ip in $hubs; do
    lookups=$(count " $ip hub.api.surehub.io" "$CAP/dns.log")
    checkins=$(count "hub ('$ip'" "$CAP/relay443.log")
    pages=$(count "hub ('$ip'" "$CAP/relay80.log")
    cloud=$(count " $ip iot.production.surehub.io" "$CAP/dns.log")
    last80=$(grep -F "hub ('$ip'" "$CAP/relay80.log" 2>/dev/null | tail -1 | cut -d' ' -f1)

    echo "Hub $ip"
    printf '  [%s] got an IP address from the Mac\n' "x"
    printf '  [%s] asked for hub.api.surehub.io (%s times)\n' "$([ "$lookups" -gt 0 ] && echo x || echo ' ')" "$lookups"
    printf '  [%s] HTTPS check-in through relay (%s connections)\n' "$([ "$checkins" -gt 0 ] && echo x || echo ' ')" "$checkins"
    if [ "$pages" -gt 0 ] && [ "$cloud" -gt 0 ]; then
      printf '  [x] firmware download: %s pages, finished\n' "$pages"
    elif [ "$pages" -gt 0 ]; then
      printf '  [x] firmware download: %s pages so far (last at %s) - DO NOT UNPLUG\n' "$pages" "$last80"
    else
      printf '  [ ] firmware download (not started / not needed)\n'
    fi
    if [ "$cloud" -gt 0 ]; then
      printf '  [x] connected to Sure cloud (iot.production.surehub.io) - FIXED\n'
    else
      printf '  [ ] connected to Sure cloud\n'
    fi
    echo
  done
  echo "Logs: $CAP/{dns,relay443,relay80}.log   Packets: $CAP/hub-*.pcap"
}

if [ "${1:-}" = "--watch" ]; then
  while true; do clear; show; sleep 5; done
else
  show
fi
