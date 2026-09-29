"""Writes raw-MIL conv variants that coremltools cannot express (bf16, fp8,
fp32 compute) plus controls, one directory each, for `dump_ane_pmu_objc --mil`.

usage: rawmil_types.py OUTDIR
"""
import os, struct, sys, numpy as np
H = '''program(1.3)
[buildInfo = dict<string, string>({{"coremlc-component-MIL", "3510.2.1"}, {"coremlc-version", "3505.4.1"}, {"coremltools-component-milinternal", ""}, {"coremltools-version", "9.0"}})]
{
    func main<ios18>(tensor<%(io)s, [1, 256, 32, 32]> x) {
        string pt = const()[name = string("pt"), val = string("valid")];
        tensor<int32, [2]> st = const()[name = string("st"), val = tensor<int32, [2]>([1, 1])];
        tensor<int32, [4]> pd = const()[name = string("pd"), val = tensor<int32, [4]>([0, 0, 0, 0])];
        tensor<int32, [2]> dl = const()[name = string("dl"), val = tensor<int32, [2]>([1, 1])];
        int32 gr = const()[name = string("gr"), val = int32(1)];
        tensor<%(wt)s, [256, 256, 1, 1]> W0 = const()[name = string("W0"), val = tensor<%(wt)s, [256, 256, 1, 1]>(BLOBFILE(path = string("@model_path/weights/weight.bin"), offset = uint64(64)))];
%(body)s
    } -> (y);
}
'''
def blob(code, data):
    hdr = struct.pack("<II", 1, 2).ljust(64, b"\0")
    meta = struct.pack("<IIQQ", 0xDEADBEEF, code, len(data), 128).ljust(64, b"\0")
    return hdr + meta + data
def write(name, io, wt, code, wbytes, body):
    d = os.path.join(sys.argv[1], f"raw_{name}"); os.makedirs(d + "/weights", exist_ok=True)
    open(d + "/model.mil", "w").write(H % dict(io=io, wt=wt, body=body))
    open(d + "/weights/weight.bin", "wb").write(blob(code, wbytes))
rng = np.random.default_rng(0); w = (rng.standard_normal(256*256) * 0.02).astype(np.float32)
fp16 = w.astype(np.float16).tobytes()
bf16 = (w.view(np.uint32) >> 16).astype(np.uint16).tobytes()
i8 = rng.integers(-127, 128, 256*256).astype(np.int8).tobytes()
conv = '        tensor<%s, [1, 256, 32, 32]> y = conv(dilations = dl, groups = gr, pad = pd, pad_type = pt, strides = st, weight = %s, x = %s)[name = string("conv")];'
c16 = '        string t16 = const()[name = string("t16"), val = string("fp16")];\n'
# 1: bf16 I/O, cast to fp16 for compute
write("bf16_io", "bf16", "fp16", 1, fp16, c16 +
  '        tensor<fp16, [1, 256, 32, 32]> xh = cast(dtype = t16, x = x)[name = string("xh")];\n' +
  (conv % ("fp16", "W0", "xh")).replace("> y =", "> yh =").replace('"conv"', '"convh"') + "\n" +
  '        string tb = const()[name = string("tb"), val = string("bf16")];\n' +
  '        tensor<bf16, [1, 256, 32, 32]> y = cast(dtype = tb, x = yh)[name = string("y")];')
# 2: bf16 compute end-to-end
write("bf16_compute", "bf16", "bf16", 5, bf16, conv % ("bf16", "W0", "x"))
# 3: bf16 weights stored, cast to fp16
write("bf16_weights", "fp16", "bf16", 5, bf16, c16 +
  '        tensor<fp16, [256, 256, 1, 1]> W = cast(dtype = t16, x = W0)[name = string("W")];\n' + conv % ("fp16", "W", "x"))
# 4/5: int8 weights with blob dtype code 4 vs 8 (which does the loader expect?)
for code in (4, 8):
    write(f"int8_code{code}", "fp16", "int8", code, i8,
          c16 + '        tensor<fp16, [256, 256, 1, 1]> W = cast(dtype = t16, x = W0)[name = string("W")];\n' + conv % ("fp16", "W", "x"))
# 6: fp32 compute end-to-end (no fp16 cast)
write("fp32_compute", "fp32", "fp32", 2, w.tobytes(), conv % ("fp32", "W0", "x"))
# 7-9: fp8 guesses
for tn, code in (("fp8e4m3fn", 16), ("fp8e5m2", 17), ("fp8", 16)):
    write(f"fp8_{tn}", "fp16", tn, code, bytes(256*256), c16 +
      '        tensor<fp16, [256, 256, 1, 1]> W = cast(dtype = t16, x = W0)[name = string("W")];\n' + conv % ("fp16", "W", "x"))
write("fp16_control", "fp16", "fp16", 1, fp16, conv % ("fp16", "W0", "x"))
write("fp32io_cast", "fp32", "fp16", 1, fp16, c16 +
  '        tensor<fp16, [1, 256, 32, 32]> xh = cast(dtype = t16, x = x)[name = string("xh")];\n' +
  (conv % ("fp16", "W0", "xh")).replace("> y =", "> yh =").replace('"conv"', '"convh"') + "\n" +
  '        string t32 = const()[name = string("t32"), val = string("fp32")];\n' +
  '        tensor<fp32, [1, 256, 32, 32]> y = cast(dtype = t32, x = yh)[name = string("y")];')
