#!/bin/bash
# Data type x operator x size sweep (108 configurations) -> data/pmu_sweep.csv
source "$(dirname "$0")/env.sh"
OUT=${1:-$CAL/data/pmu_sweep.csv}
echo "mode,op,cin,cout,H,W,k,macs,lat_ms,nominal,compute,pe,int8cyc,fp16cyc,throttle,dma" > "$OUT"
for mode in fp16 w8 a8w8; do
  for opk in "conv 1" "conv 3" "dw 3"; do
    set -- $opk
    for c in 64 256 512 1024; do
      for hw in 16 64 128; do
        "$CAL/scripts/pmu_run.sh" $mode $1 $c $c $hw $hw $2 20 >> "$OUT" 2>&1
      done
    done
  done
done
