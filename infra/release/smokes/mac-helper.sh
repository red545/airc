#!/bin/bash
# Small build-Mac helpers for infra/release/smokes.py (run from the work folder root or anywhere).
#   mac-helper.sh idle <seconds> <max-wait>   wait until HID idle >= seconds (the owner's and the UI driver's input
#                                             both count); prints "idle N s after W s"; exit 1 after max-wait.
#   mac-helper.sh mark <file>                 touch a crash-audit marker
#   mac-helper.sh crashes <file>              list Airc* crash/hang reports newer than the marker (exit 1 if any)
#   mac-helper.sh sweep <file> <dest> [n] [max]  after a check that crashes on purpose (chrome://crash): wait until
#                                             n test-build reports newer than the marker exist and none came for 10 s
#                                             (ReportCrash writes ~25 s after the crash; max 90 s), then move only
#                                             those (bundle org.airc.Airc.test*) to <dest>; exit 1 if fewer than n came
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
  sweep)
    # 0.1.63 tail: a sweep right after the check missed the renderer report by a second, and `crashes` counted it.
    mark=$2; dest=$3; n=${4:-1}; max=${5:-90}; waited=0; last=-1; still=0
    ours() { for f in "$HOME"/Library/Logs/DiagnosticReports/Airc*.ips; do
        [ -f "$f" ] && [ "$f" -nt "$mark" ] && head -1 "$f" | grep -q '"bundleID":"org.airc.Airc.test' && echo "$f"; done; }
    while :; do
      c=$(ours | grep -c .)
      if [ "$c" = "$last" ]; then still=$((still + 2)); else still=0; last=$c; fi
      [ "$c" -ge "$n" ] && [ $still -ge 10 ] && break
      [ $waited -ge "$max" ] && break
      sleep 2; waited=$((waited + 2))
    done
    mkdir -p "$dest"
    ours | while IFS= read -r f; do mv "$f" "$dest/" && echo "moved $(basename "$f")"; done
    echo "sweep: $c of $n after $waited s"
    [ "$c" -ge "$n" ];;
  load) sysctl -n vm.loadavg | awk '{print $2}';;
  *) echo "usage: mac-helper.sh idle|mark|crashes|sweep|load"; exit 2;;
esac
