#!/bin/bash
# Storage/compute format sweep over three conv shapes -> data/format_sweep.csv
source "$(dirname "$0")/env.sh"
OUT=${1:-$CAL/data/format_sweep.csv}
echo "shape,format,macs,lat_ms,nominal,compute,pe" > "$OUT"
F=()
for w in fp16 int8 uint8 int4 uint4 int8b32 int4b32 lut1 lut2 lut3 lut4 lut6 lut8 sp50 sp75 sp50lut4; do
  F+=("io=fp16,w=$w,a=fp16")
done
F+=("io=fp16,w=fp16,a=int8" "io=fp16,w=int8,a=int8" "io=fp16,w=int8,a=uint8" "io=fp16,w=int4,a=int8"
    "io=fp16,w=lut4,a=int8" "io=fp16,w=lut8,a=int8" "io=fp16,w=sp50,a=int8")
F+=("io=fp32,w=fp16,a=fp16" "io=fp32,w=fp16,a=fp16,prec=fp32" "io=fp16,w=fp16,a=fp16,prec=fp32")
for sh in conv:3:1024:64 conv:3:512:128 conv:1:1024:128; do
  for fm in "${F[@]}"; do "$CAL/scripts/coreml_run.sh" $sh $fm 20 >> "$OUT" 2>&1; done
done
