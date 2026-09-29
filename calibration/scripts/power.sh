#!/bin/bash
# Run with sudo. ANE power (powermetrics) while each model keeps the ANE busy.
source "$(dirname "$0")/env.sh"
OUT=$WORK/power; rm -rf "$OUT"; mkdir -p "$OUT"; chmod 777 "$OUT"
pm() { powermetrics -s cpu_power,ane_power -i 1000 -n $2 > "$OUT/$1.txt" 2>/dev/null; chmod 644 "$OUT/$1.txt"; }
models="fp16 conv 1024 1024 128 128 3
fp16 conv 512 512 128 128 3
w8 conv 1024 1024 128 128 3
a8w8 conv 1024 1024 128 128 3
fp16 dw 1024 1024 128 128 3
fp16 conv 64 64 16 16 1"
echo "idle..."; sleep 3; pm idle 8
while read -r mode op ci co h w k; do
  d=$MODELS/${mode}_${op}_${ci}_${co}_${h}x${w}_k${k}
  [ -f "$d/model.mil" ] || as_user "$BIN/qgen" "$d" $mode $op $ci $co $h $w $k > /dev/null
  n=$(basename "$d"); echo "$n..."
  as_user "$BIN/burn" -t 14s "$d" > "$OUT/$n.log" 2>&1 &
  sleep 3; pm "$n" 10; wait; sleep 3
done <<<"$models"
"$PYTHON" "$CAL/scripts/power_report.py" "$OUT"
