import Foundation

/// Generates a MIL model directory holding one conv layer, or a chain of
/// identical conv layers, for ANE calibration.
struct ConvModel {
    enum Mode: String { case fp16, w8, a8w8 }   // weights/activations: fp16/fp16, int8/fp16, int8/int8
    enum Op: String { case conv, dw }           // dense or depthwise

    var mode: Mode
    var op: Op
    var cin: Int
    var cout: Int
    var height: Int
    var width: Int
    var kernel: Int
    var validPadding = false
    var layers = 1

    /// Multiply-accumulates per inference, counting "same" padding as computed.
    var macs: Int {
        let (groupsIn, outCh) = op == .dw ? (1, cin) : (cin, cout)
        var total = 0, h = height, w = width
        for _ in 0..<layers {
            if validPadding && kernel > 1 { h -= kernel - 1; w -= kernel - 1 }
            total += outCh * groupsIn * kernel * kernel * h * w
        }
        return total
    }

    func write(to dir: URL) throws {
        let groups = op == .dw ? cin : 1
        let outCh = op == .dw ? cin : cout
        let wIn = op == .dw ? 1 : cin
        let count = outCh * wIn * kernel * kernel
        var rng = SplitMix64(seed: 0x5eed)

        var blobs = BlobWriter()
        let wIdx: Int, sIdx: Int
        if mode == .fp16 {
            wIdx = blobs.add(.fp16, fp16Bytes((0..<count).map { _ in Float(rng.normal() * 0.02) }))
            sIdx = -1
        } else {
            wIdx = blobs.add(.int8, (0..<count).map { _ in UInt8(bitPattern: Int8(Int(rng.next() % 255) - 127)) })
            sIdx = blobs.add(.fp16, fp16Bytes(Array(repeating: 0.0002, count: outCh)))
        }

        let pad = validPadding || kernel == 1 ? "valid" : "same"
        let wShape = "[\(outCh), \(wIn), \(kernel), \(kernel)]"
        func blobRef(_ type: String, _ shape: String, _ i: Int) -> String {
            "tensor<\(type), \(shape)>(BLOBFILE(path = string(\"@model_path/weights/weight.bin\"), offset = uint64(\(BlobWriter.descriptorOffset(i)))))"
        }
        var m = """
        program(1.3)
        [buildInfo = dict<string, string>({{"coremlc-component-MIL", "3510.2.1"}, {"coremlc-version", "3505.4.1"}, {"coremltools-component-milinternal", ""}, {"coremltools-version", "9.0"}})]
        {
            func main<ios18>(tensor<fp16, [1, \(cin), \(height), \(width)]> x) {
                string pt = const()[name = string("pt"), val = string("\(pad)")];
                tensor<int32, [2]> st = const()[name = string("st"), val = tensor<int32, [2]>([1, 1])];
                tensor<int32, [4]> pd = const()[name = string("pd"), val = tensor<int32, [4]>([0, 0, 0, 0])];
                tensor<int32, [2]> dl = const()[name = string("dl"), val = tensor<int32, [2]>([1, 1])];
                int32 gr = const()[name = string("gr"), val = int32(\(groups))];

        """
        if mode == .fp16 {
            m += "        tensor<fp16, \(wShape)> Wt = const()[name = string(\"Wt\"), val = \(blobRef("fp16", wShape, wIdx))];\n"
        } else {
            let sShape = "[\(outCh), 1, 1, 1]"
            m += "        tensor<int8, \(wShape)> Wq = const()[name = string(\"Wq\"), val = \(blobRef("int8", wShape, wIdx))];\n"
            m += "        tensor<fp16, \(sShape)> Ws = const()[name = string(\"Ws\"), val = \(blobRef("fp16", sShape, sIdx))];\n"
            m += "        tensor<fp16, \(wShape)> Wt = constexpr_blockwise_shift_scale(data = Wq, scale = Ws)[name = string(\"Wt\")];\n"
        }
        var cur = "x"
        if mode == .a8w8 {
            let act = "[1, \(cin), \(height), \(width)]"
            m += "        fp16 xs = const()[name = string(\"xs\"), val = fp16(0x1p-5)];\n"
            m += "        string i8 = const()[name = string(\"i8\"), val = string(\"int8\")];\n"
            m += "        tensor<int8, \(act)> xq = quantize(input = x, scale = xs, output_dtype = i8)[name = string(\"xq\")];\n"
            m += "        tensor<fp16, \(act)> xd = dequantize(input = xq, scale = xs)[name = string(\"xd\")];\n"
            cur = "xd"
        }
        var h = height, w = width
        for l in 0..<layers {
            if pad == "valid" && kernel > 1 { h -= kernel - 1; w -= kernel - 1 }
            let out = "[1, \(outCh), \(h), \(w)]"
            let name = "c\(l)"
            m += "        tensor<fp16, \(out)> \(name) = conv(dilations = dl, groups = gr, pad = pd, pad_type = pt, strides = st, weight = Wt, x = \(cur))[name = string(\"\(name)\")];\n"
            cur = name
            if mode == .a8w8 {
                m += "        tensor<int8, \(out)> \(name)q = quantize(input = \(name), scale = xs, output_dtype = i8)[name = string(\"\(name)q\")];\n"
                m += "        tensor<fp16, \(out)> \(name)d = dequantize(input = \(name)q, scale = xs)[name = string(\"\(name)d\")];\n"
                cur = name + "d"
            }
        }
        m += "        tensor<fp16, [1, \(outCh), \(h), \(w)]> y = identity(x = \(cur))[name = string(\"y\")];\n"
        m += "    } -> (y);\n}\n"

        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data(m.utf8).write(to: dir.appendingPathComponent("model.mil"))
        try blobs.build().write(to: dir.appendingPathComponent("weights/weight.bin"))
    }
}

/// MIL blob storage v2 as the ANE compiler reads it: a 64-byte header
/// {u32 count, u32 version = 2}, one 64-byte descriptor per blob
/// {u32 0xDEADBEEF, u32 dtype, u64 size, u64 data offset}, then the data,
/// each blob padded to 64 bytes. BLOBFILE offsets point at the descriptor.
struct BlobWriter {
    enum DType: UInt32 {
        case fp16 = 1
        // Every calibration run used 8 for int8 data; the compiler accepted 4 as well.
        case int8 = 8
    }
    private var blobs: [(DType, [UInt8])] = []

    static func descriptorOffset(_ i: Int) -> Int { 64 + 64 * i }

    mutating func add(_ type: DType, _ bytes: [UInt8]) -> Int {
        blobs.append((type, bytes))
        return blobs.count - 1
    }

    func build() -> Data {
        var out = Data(count: 64 + 64 * blobs.count)
        func put<T: FixedWidthInteger>(_ v: T, at o: Int) {
            withUnsafeBytes(of: v.littleEndian) { out.replaceSubrange(o..<o + MemoryLayout<T>.size, with: $0) }
        }
        put(UInt32(blobs.count), at: 0)
        put(UInt32(2), at: 4)
        for (i, (type, bytes)) in blobs.enumerated() {
            let d = Self.descriptorOffset(i)
            put(UInt32(0xDEAD_BEEF), at: d)
            put(type.rawValue, at: d + 4)
            put(UInt64(bytes.count), at: d + 8)
            put(UInt64(out.count), at: d + 16)
            out.append(contentsOf: bytes)
            out.append(Data(count: (64 - out.count % 64) % 64))
        }
        return out
    }
}

func fp16Bytes(_ v: [Float]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(v.count * 2)
    for x in v {
        let bits = Float16(x).bitPattern
        out.append(UInt8(bits & 0xff))
        out.append(UInt8(bits >> 8))
    }
    return out
}

/// Small deterministic generator so models are identical across runs.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func normal() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
