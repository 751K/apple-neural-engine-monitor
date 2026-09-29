// qgen writes a single-conv MIL model directory for ANE PMU calibration.
//
//	qgen dir mode op cin cout H W k
//	mode: fp16 | w8 | a8w8      op: conv | dw
package main

import (
	"fmt"
	"log"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"encoding/binary"

	"github.com/tmc/apple/x/ane/mil"
)

const header = "program(1.3)\n[buildInfo = dict<string, string>({{\"coremlc-component-MIL\", \"3510.2.1\"}, {\"coremlc-version\", \"3505.4.1\"}, {\"coremltools-component-milinternal\", \"\"}, {\"coremltools-version\", \"9.0\"}})]\n"

func atoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		log.Fatal(err)
	}
	return n
}

func main() {
	a := os.Args[1:]
	dir, mode, op := a[0], a[1], a[2]
	cin, cout, H, W, k := atoi(a[3]), atoi(a[4]), atoi(a[5]), atoi(a[6]), atoi(a[7])
	groups, wi := 1, cin
	if op == "dw" {
		groups, cout, wi = cin, cin, 1
	}
	nw := cout * wi * k * k
	r := rand.New(rand.NewPCG(1, 2))

	bw := &blobWriter{}
	var wIdx, sIdx int
	if mode == "fp16" {
		w := make([]float32, nw)
		for i := range w {
			w[i] = float32(r.NormFloat64() * 0.02)
		}
		wIdx = bw.add(1, fp16Bytes(w))
	} else {
		q := make([]byte, nw)
		for i := range q {
			q[i] = byte(int8(r.IntN(255) - 127))
		}
		wIdx = bw.add(8, q)
		s := make([]float32, cout)
		for i := range s {
			s[i] = 0.0002
		}
		sIdx = bw.add(1, fp16Bytes(s))
	}
	blob := bw.build()

	pad := "valid"
	if k > 1 && os.Getenv("PAD") != "valid" {
		pad = "same"
	}
	layers := 1
	if v := os.Getenv("LAYERS"); v != "" {
		layers = atoi(v)
	}
	oH, oW := H, W
	if pad == "valid" {
		oH, oW = H-k+1, W-k+1
	}
	wt := fmt.Sprintf("[%d, %d, %d, %d]", cout, wi, k, k)
	var b strings.Builder
	b.WriteString(header + "{\n")
	fmt.Fprintf(&b, "    func main<ios18>(tensor<fp16, [1, %d, %d, %d]> x) {\n", cin, H, W)
	fmt.Fprintf(&b, "        string pt = const()[name = string(\"pt\"), val = string(\"%s\")];\n", pad)
	b.WriteString("        tensor<int32, [2]> st = const()[name = string(\"st\"), val = tensor<int32, [2]>([1, 1])];\n")
	b.WriteString("        tensor<int32, [4]> pd = const()[name = string(\"pd\"), val = tensor<int32, [4]>([0, 0, 0, 0])];\n")
	b.WriteString("        tensor<int32, [2]> dl = const()[name = string(\"dl\"), val = tensor<int32, [2]>([1, 1])];\n")
	fmt.Fprintf(&b, "        int32 gr = const()[name = string(\"gr\"), val = int32(%d)];\n", groups)
	blobRef := func(t, shape string, i int) string {
		return fmt.Sprintf("tensor<%s, %s>(BLOBFILE(path = string(\"@model_path/weights/weight.bin\"), offset = uint64(%d)))", t, shape, 64+64*i)
	}
	if mode == "fp16" {
		fmt.Fprintf(&b, "        tensor<fp16, %s> Wt = const()[name = string(\"Wt\"), val = %s];\n", wt, blobRef("fp16", wt, wIdx))
	} else {
		ss := fmt.Sprintf("[%d, 1, 1, 1]", cout)
		fmt.Fprintf(&b, "        tensor<int8, %s> Wq = const()[name = string(\"Wq\"), val = %s];\n", wt, blobRef("int8", wt, wIdx))
		fmt.Fprintf(&b, "        tensor<fp16, %s> Ws = const()[name = string(\"Ws\"), val = %s];\n", ss, blobRef("fp16", ss, sIdx))
		fmt.Fprintf(&b, "        tensor<fp16, %s> Wt = constexpr_blockwise_shift_scale(data = Wq, scale = Ws)[name = string(\"Wt\")];\n", wt)
	}
	xin, act := "x", fmt.Sprintf("[1, %d, %d, %d]", cin, H, W)
	if mode == "a8w8" {
		b.WriteString("        fp16 xs = const()[name = string(\"xs\"), val = fp16(0x1p-5)];\n")
		b.WriteString("        string i8 = const()[name = string(\"i8\"), val = string(\"int8\")];\n")
		fmt.Fprintf(&b, "        tensor<int8, %s> xq = quantize(input = x, scale = xs, output_dtype = i8)[name = string(\"xq\")];\n", act)
		fmt.Fprintf(&b, "        tensor<fp16, %s> xd = dequantize(input = xq, scale = xs)[name = string(\"xd\")];\n", act)
		xin = "xd"
	}
	cur, cH, cW := xin, H, W
	for l := 0; l < layers; l++ {
		nH, nW := cH, cW
		if pad == "valid" {
			nH, nW = cH-k+1, cW-k+1
		}
		out := fmt.Sprintf("[1, %d, %d, %d]", cout, nH, nW)
		name := fmt.Sprintf("c%d", l)
		fmt.Fprintf(&b, "        tensor<fp16, %s> %s = conv(dilations = dl, groups = gr, pad = pd, pad_type = pt, strides = st, weight = Wt, x = %s)[name = string(\"%s\")];\n", out, name, cur, name)
		cur = name
		if mode == "a8w8" {
			fmt.Fprintf(&b, "        tensor<int8, %s> %sq = quantize(input = %s, scale = xs, output_dtype = i8)[name = string(\"%sq\")];\n", out, name, name, name)
			fmt.Fprintf(&b, "        tensor<fp16, %s> %sd = dequantize(input = %sq, scale = xs)[name = string(\"%sd\")];\n", out, name, name, name)
			cur = name + "d"
		}
		cH, cW = nH, nW
	}
	fmt.Fprintf(&b, "        tensor<fp16, [1, %d, %d, %d]> y = identity(x = %s)[name = string(\"y\")];\n", cout, cH, cW, cur)
	oH, oW = cH, cW
	b.WriteString("    } -> (y);\n}\n")

	os.MkdirAll(filepath.Join(dir, "weights"), 0o755)
	os.WriteFile(filepath.Join(dir, "model.mil"), []byte(b.String()), 0o644)
	os.WriteFile(filepath.Join(dir, "weights", "weight.bin"), blob, 0o644)
	macs := 0
	h, w := H, W
	for l := 0; l < layers; l++ {
		if pad == "valid" {
			h, w = h-k+1, w-k+1
		}
		macs += cout * wi * k * k * h * w
	}
	_ = oH
	_ = oW
	fmt.Println(macs) // MACs
}

// blobWriter emits MIL blob storage v2: a 64-byte header {u32 count, u32 version},
// one 64-byte descriptor per blob {u32 magic, u32 dtype, u64 size, u64 offset},
// then 64-byte-aligned data. BLOBFILE offsets point at the descriptor.
type blobWriter struct {
	dtypes []uint32
	data   [][]byte
}

func (w *blobWriter) add(dtype uint32, b []byte) int {
	w.dtypes = append(w.dtypes, dtype)
	w.data = append(w.data, b)
	return len(w.data) - 1
}

func align64(n int) int { return (n + 63) &^ 63 }

func (w *blobWriter) build() []byte {
	off := 64 + 64*len(w.data)
	out := make([]byte, off)
	le := binary.LittleEndian
	le.PutUint32(out[0:], uint32(len(w.data)))
	le.PutUint32(out[4:], 2)
	for i, d := range w.data {
		m := out[64+64*i:]
		le.PutUint32(m[0:], 0xDEADBEEF)
		le.PutUint32(m[4:], w.dtypes[i])
		le.PutUint64(m[8:], uint64(len(d)))
		le.PutUint64(m[16:], uint64(len(out)))
		out = append(out, d...)
		out = append(out, make([]byte, align64(len(out))-len(out))...)
	}
	return out
}

func fp16Bytes(v []float32) []byte {
	b, err := mil.BuildFP16Blob(v)
	if err != nil {
		log.Fatal(err)
	}
	return b[128:] // strip the single-blob header; keep raw fp16
}
