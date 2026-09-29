#!/bin/bash
# Run with sudo. Captures ANE kdebug events (class 0x06, subclass 0x1b) under
# long, very long and short tasks, keeping only the task events
# (0x061b0125/0126 firmware start/end, 0x061b00a0 host submit/complete).
source "$(dirname "$0")/env.sh"
OUT=$WORK/trace; mkdir -p "$OUT"; chmod 777 "$OUT"
mk() { local d=$MODELS/$1; [ -f "$d/model.mil" ] || as_user "$BIN/qgen" "$d" "${@:2}" > /dev/null; echo "$d"; }
long=$(mk a8w8_conv_1024_1024_128x128_k3 a8w8 conv 1024 1024 128 128 3)
vlong=$(mk fp16_conv_1024_1024_128x128_k3 fp16 conv 1024 1024 128 128 3)
cap() {
  ktrace trace -f S0x061b -b 512 -T 2 2>/dev/null | grep -E ' 61b0125 | 61b0126 | 61b00a0 ' > "$OUT/$1.txt"
  chmod 644 "$OUT/$1.txt"
}
as_user "$BIN/burn" -t 6s "$long" > "$OUT/long.log" 2>&1 & sleep 2; cap long; wait
as_user "$BIN/burn" -t 6s "$vlong" > "$OUT/vlong.log" 2>&1 & sleep 2; cap vlong; wait
as_user "$BIN/duty" -duty 0.5 -t 6s > "$OUT/short.log" 2>&1 & sleep 2; cap short; wait
"$PYTHON" "$CAL/scripts/trace_pairs.py" "$OUT"/{long,vlong,short}.txt
