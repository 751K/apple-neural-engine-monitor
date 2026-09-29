#!/bin/bash
# Run with sudo. Compares anemon's busy % with workloads of known duty cycle.
# usage: sudo verify_anemon.sh [path/to/anemon]
source "$(dirname "$0")/env.sh"
A=${1:-$CAL/../.build/make/anemon}
OUT=$WORK/verify; rm -rf "$OUT"; mkdir -p "$OUT"
mk() { local d=$MODELS/$1; [ -f "$d/model.mil" ] || as_user "$BIN/qgen" "$d" "${@:2}" > /dev/null; echo "$d"; }
long=$(mk a8w8_conv_1024_1024_128x128_k3 a8w8 conv 1024 1024 128 128 3)
vlong=$(mk fp16_conv_1024_1024_128x128_k3 fp16 conv 1024 1024 128 128 3)
mid=$(mk fp16_conv_512_512_128x128_k3 fp16 conv 512 512 128 128 3)
tiny=$(mk fp16_conv_64_64_16x16_k1 fp16 conv 64 64 16 16 1)
case_() {
  local name=$1; shift
  [ "$name" = idle ] || as_user "$@" > "$OUT/$name.log" 2>&1 &
  sleep 1.5; "$A" --json --count 4 > "$OUT/$name.json" 2> "$OUT/$name.err"; wait; sleep 1
}
case_ idle
case_ long_100  "$BIN/burn" -t 7s "$long"
case_ long_50   "$BIN/burn" -t 7s -duty 0.5 "$long"
case_ long_25   "$BIN/burn" -t 7s -duty 0.25 "$long"
case_ vlong_100 "$BIN/burn" -t 7s "$vlong"
case_ mid_50    "$BIN/burn" -t 7s -duty 0.5 -period 50ms "$mid"
case_ tiny_100  "$BIN/burn" -t 7s "$tiny"
chmod -R a+r "$OUT"
"$PYTHON" - "$OUT" <<'PY'
import json, os, re, sys, statistics as st
d = sys.argv[1]
print(f"{'case':10}{'host-busy':>10}{'anemon busy':>13}{'tasks/s':>9}{'ms/task':>9}{'power W':>9}")
for n in ["idle", "long_100", "long_50", "long_25", "vlong_100", "mid_50", "tiny_100"]:
    rows = [json.loads(l) for l in open(f"{d}/{n}.json") if l.startswith("{")][1:]
    if not rows:
        print(n, "no data:", open(f"{d}/{n}.err").read().strip()); continue
    def med(k, i=None):
        v = [r[k][i] if i is not None else r[k] for r in rows if r.get(k) is not None]
        v = [x for x in v if x is not None]
        return st.median(v) if v else float("nan")
    log = f"{d}/{n}.log"
    host = re.search(r"host-busy=([\d.]+)", open(log).read()).group(1) + "%" if os.path.exists(log) else "0%"
    print(f"{n:10}{host:>10}{med('ane_busy_pct', 0):>12.1f}%{med('ane_tasks_per_s', 0):>9.0f}"
          f"{med('ane_avg_task_ms', 0):>9.3f}{med('ane_power_w'):>9.2f}")
PY
