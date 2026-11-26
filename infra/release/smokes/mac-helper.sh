#!/bin/bash
# Small build-Mac helpers for infra/release/smokes.py (run from the work folder root or anywhere).
#   mac-helper.sh idle <seconds> <max-wait>   wait until HID idle >= seconds (the owner's and the UI driver's input
#                                             both count); prints "idle N s after W s"; exit 1 after max-wait.
#   mac-helper.sh mark <file>                 touch a crash-audit marker
#   mac-helper.sh crashes <file>              list Airc* crash/hang reports newer than the marker (exit 1 if any)
#   mac-helper.sh load                        print the 1-minute load average
set -u
hid_idle() { ioreg -c IOHIDSystem -d 4 | awk '/"HIDIdleTime"/ {print int($NF / 1000000000); exit}'; }
case $1 in
  idle)
    need=$2; max=$3; waited=0
    while :; do
      i=$(hid_idle); i=${i:-0}
      if [ "$i" -ge "$need" ]; then echo "idle $i s after $waited s"; exit 0; fi
      [ $waited -ge "$max" ] && { echo "idle only $i s after $waited s (need $need)"; exit 1; }
      s=$((need - i)); [ $s -gt 15 ] && s=15; [ $s -lt 1 ] && s=1
      sleep $s; waited=$((waited + s))
    done;;
  mark) mkdir -p "$(dirname "$2")"; touch "$2";;
  crashes)
    found=$(find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -maxdepth 1 \
      \( -name 'Airc*.ips' -o -name 'Airc*.crash' -o -name 'Airc*.hang' -o -name 'Airc*.diag' \) -newer "$2" 2>/dev/null)
    [ -z "$found" ] && exit 0
    echo "$found"; exit 1;;
  load) sysctl -n vm.loadavg | awk '{print $2}';;
  *) echo "usage: mac-helper.sh idle|mark|crashes|load"; exit 2;;
esac
