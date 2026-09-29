#!/bin/bash
# Builds a single-conv Core ML model in a given numeric format and profiles it.
# usage: coreml_run.sh SHAPE FORMAT [ITERS]
#   SHAPE  op:k:C:HW              e.g. conv:3:1024:64
#   FORMAT io=..,w=..,a=..[,prec=..]  see coreml_build.py
source "$(dirname "$0")/env.sh"
tag=$(echo "$1_$2" | tr ':,=' '_-.'); d=$WORK/coreml/$tag.mlpackage; mkdir -p "$WORK/coreml"
if [ ! -d "$d" ]; then
  k=$("$PYTHON" "$CAL/scripts/coreml_build.py" "$d" "$1" "$2" 2>"$WORK/coreml/$tag.err" | tail -1) ||
    { echo "ERR,$1,$2,build: $(grep -m1 -iE 'error' "$WORK/coreml/$tag.err" | cut -c1-120)"; exit 1; }
  echo "$k" > "$WORK/coreml/$tag.macs"
fi
k=$(cat "$WORK/coreml/$tag.macs")
out=$("$PROFILER" --coreml "$d" --macs "$k" --iters "${3:-20}" 2>&1)
if ! grep -q "Average Latency" <<<"$out"; then
  echo "ERR,$1,$2,run: $(grep -m1 -E '❌|rror' <<<"$out" | cut -c1-140)"; exit 1
fi
awk -v sh="$1" -v fm="$2" -v k=$k '
 /Average Latency/{match($0,/Latency: [0-9.]+ ms/); lat=substr($0,RSTART+9,RLENGTH-12)}
 /^\[[0-9][0-9]\]/{i=substr($1,2,2)+0; v=$5; gsub(",","",v); r[i]=v}
 END{printf "%s,%s,%d,%s,%s,%s,%s\n",sh,fm,k,lat,r[10],r[13],r[21]}' <<<"$out"
