#!/bin/bash
# Profiles one generated conv model with the ANE PMU and prints a CSV row.
# usage: pmu_run.sh MODE OP CIN COUT H W K [ITERS]
#   MODE fp16 | w8 | a8w8   OP conv | dw
source "$(dirname "$0")/env.sh"
d=$MODELS/$1_$2_$3_$4_$5x$6_k$7
[ -f "$d/macs" ] || { "$ANEBENCH" gen "$d" "${@:1:7}" > "$d.macs" && mv "$d.macs" "$d/macs"; } || exit 1
k=$(cat "$d/macs")
out=$("$PROFILER" --mil "$d" --macs "$k" --iters "${8:-20}" 2>&1)
if ! grep -q "Average Latency" <<<"$out"; then
  echo "ERR,$1,$2,$3,$4,$5,$6,$7: $(grep -m1 -E '❌|rror' <<<"$out" | cut -c1-120)"; exit 1
fi
awk -v m=$1 -v o=$2 -v ci=$3 -v co=$4 -v h=$5 -v w=$6 -v kk=$7 -v k=$k '
 /Average Latency/{match($0,/Latency: [0-9.]+ ms/); lat=substr($0,RSTART+9,RLENGTH-12)}
 /^\[[0-9][0-9]\]/{i=substr($1,2,2)+0; v=$5; gsub(",","",v); r[i]=v}
 END{printf "%s,%s,%d,%d,%d,%d,%d,%d,%s,%s,%s,%s,%s,%s,%s,%s\n",m,o,ci,co,h,w,kk,k,lat,r[10],r[13],r[21],r[5],r[6],r[11],r[15]}' <<<"$out"
