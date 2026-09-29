#!/usr/bin/env python3
"""Summarizes pmu_sweep.csv: throughput, MACs per nominal tick, compute-cycle share.

usage: pmu_analyze.py data/pmu_sweep.csv
"""
import csv, sys, statistics as st
NOM_PER_S = 37.5e9  # NE_NOMINAL ticks per second on M4 (from long runs)
rows, errs = [], []
for r in csv.reader(open(sys.argv[1])):
    if not r or r[0] in ("mode", "DONE"): continue
    if r[0].startswith("ERR"): errs.append(",".join(r)); continue
    m, op, ci, co, H, W, k, macs, lat, nom, cmp_, pe, i8, f16, thr, dma = r
    macs, lat, nom, cmp_, pe = int(macs), float(lat), int(nom), int(cmp_), int(pe)
    dev_s = nom / NOM_PER_S
    rows.append(dict(mode=m, op=op, c=int(ci), hw=int(H), k=int(k), macs=macs, lat=lat,
        dev_ms=dev_s * 1e3, nom_per_ms=nom / lat / 1e6, tmac_host=macs / (lat * 1e-3) / 1e12,
        tmac_dev=macs / dev_s / 1e12, mac_per_nom=macs / nom, mac_per_cmp=macs / cmp_ if cmp_ else 0,
        cmp_pct=100 * cmp_ / nom, pe_pct=100 * pe / nom, i8=i8, f16=f16))
hdr = f"{'mode':5}{'op':5}{'k':>2}{'C':>6}{'HW':>5}{'MACs':>9}{'lat ms':>8}{'nom/ms':>8}{'TMAC/s':>8}{'MAC/nom':>9}{'MAC/cmp':>9}{'cmp%':>7}{'pe%':>6}"
print(hdr)
for d in rows:
    print(f"{d['mode']:5}{d['op']:5}{d['k']:>2}{d['c']:>6}{d['hw']:>5}{d['macs']/1e9:>8.2f}G{d['lat']:>8.3f}{d['nom_per_ms']:>8.1f}{d['tmac_host']:>8.2f}{d['mac_per_nom']:>9.1f}{d['mac_per_cmp']:>9.1f}{d['cmp_pct']:>7.1f}{d['pe_pct']:>6.1f}")
print("\nbest TMAC/s (host latency) per mode/op:")
for key in sorted({(d['mode'], d['op'], d['k']) for d in rows}):
    g = [d for d in rows if (d['mode'], d['op'], d['k']) == key]
    b = max(g, key=lambda d: d['tmac_host'])
    print(f"  {key[0]:5} {key[1]}{key[2]}: {b['tmac_host']:.2f} TMAC/s = {2*b['tmac_host']:.1f} TOPS  (C={b['c']}, HW={b['hw']}, MAC/nom={b['mac_per_nom']:.0f}, cmp%={b['cmp_pct']:.1f})")
big = [d for d in rows if d['lat'] > 2]
if big: print(f"\nnominal ticks per ms (lat>2ms, n={len(big)}): median {st.median(d['nom_per_ms'] for d in big):.1f}M, range {min(d['nom_per_ms'] for d in big):.1f}-{max(d['nom_per_ms'] for d in big):.1f}M")
print("INT8_CYCLES/FP16_CYCLES nonzero rows:", sum(1 for d in rows if d['i8'] not in ('0','') or d['f16'] not in ('0','')))
if errs: print("\nerrors:", *errs, sep="\n  ")
