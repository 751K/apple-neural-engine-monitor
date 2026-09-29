#!/usr/bin/env python3
"""Build a single-conv .mlpackage in a given numeric format for ANE PMU tests.

usage: build_model.py OUT.mlpackage SHAPE FORMAT
  SHAPE  : op:k:C:HW   e.g. conv:3:1024:64
  FORMAT : io=<fp16|fp32>,w=<wfmt>,a=<fp16|int8|uint8>,prec=<fp16|fp32>
  wfmt   : fp16 | int8 | uint8 | int4 | uint4 | int8b32 | int4b32
           | lut1 | lut2 | lut3 | lut4 | lut6 | lut8 | sp50 | sp75 | sp50lut4
Prints the MAC count on success.
"""
import sys
import numpy as np
import coremltools as ct
import coremltools.optimize.coreml as cto
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types

out, shape, fmt = sys.argv[1], sys.argv[2], sys.argv[3]
op, k, C, HW = shape.split(":")
k, C, HW = int(k), int(C), int(HW)
f = dict(kv.split("=") for kv in fmt.split(","))
io, wf, af, prec = f.get("io", "fp16"), f.get("w", "fp16"), f.get("a", "fp16"), f.get("prec", "fp16")

groups = C if op == "dw" else 1
cin_per_group = 1 if op == "dw" else C
rng = np.random.default_rng(0)
W = (rng.standard_normal((C, cin_per_group, k, k)) * 0.02).astype(np.float32)
macs = C * cin_per_group * k * k * HW * HW

in_dtype = types.fp16 if io == "fp16" else types.fp32


@mb.program(input_specs=[mb.TensorSpec(shape=(1, C, HW, HW), dtype=in_dtype)],
            opset_version=ct.target.macOS15)
def prog(x):
    if af in ("int8", "uint8"):
        zp = np.int8(0) if af == "int8" else np.uint8(128)
        x = mb.quantize(input=x, scale=np.float16(1 / 32) if io == "fp16" else np.float32(1 / 32),
                        zero_point=zp, output_dtype=af)
        x = mb.dequantize(input=x, scale=np.float16(1 / 32) if io == "fp16" else np.float32(1 / 32),
                          zero_point=zp)
    y = mb.conv(x=x, weight=W, pad_type="same", groups=groups)
    if af in ("int8", "uint8"):
        zp = np.int8(0) if af == "int8" else np.uint8(128)
        s = np.float16(1 / 32) if io == "fp16" else np.float32(1 / 32)
        y = mb.quantize(input=y, scale=s, zero_point=zp, output_dtype=af)
        y = mb.dequantize(input=y, scale=s, zero_point=zp)
    return y


precision = ct.precision.FLOAT16 if prec == "fp16" else ct.precision.FLOAT32
m = ct.convert(prog, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
               compute_precision=precision, compute_units=ct.ComputeUnit.CPU_AND_NE)


def lq(dtype, block=None):
    if block:
        cfg = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype=dtype,
                                          granularity="per_block", block_size=block, weight_threshold=0)
    else:
        cfg = cto.OpLinearQuantizerConfig(mode="linear_symmetric" if dtype.startswith("int") else "linear",
                                          dtype=dtype, granularity="per_channel", weight_threshold=0)
    return cto.linear_quantize_weights(m, cto.OptimizationConfig(global_config=cfg))


def pal(nbits, model=None):
    cfg = cto.OpPalettizerConfig(mode="uniform", nbits=nbits, granularity="per_tensor", weight_threshold=0)
    return cto.palettize_weights(model or m, cto.OptimizationConfig(global_config=cfg))


def prune(sp):
    cfg = cto.OpMagnitudePrunerConfig(target_sparsity=sp, weight_threshold=0)
    return cto.prune_weights(m, cto.OptimizationConfig(global_config=cfg))


if wf == "fp16":
    pass
elif wf in ("int8", "uint8", "int4", "uint4"):
    m = lq(wf)
elif "b" in wf and wf[:4] in ("int8", "int4"):
    m = lq(wf[:4], block=int(wf.split("b")[1]))
elif wf.startswith("lut"):
    m = pal(int(wf[3:]))
elif wf == "sp50":
    m = prune(0.5)
elif wf == "sp75":
    m = prune(0.75)
elif wf == "sp50lut4":
    m = pal(4, prune(0.5))
else:
    sys.exit(f"unknown weight format {wf}")

m.save(out)
print(macs)
