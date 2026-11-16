import Foundation

/// Writes a GGUF file (version 3) with metadata and 32-bit float tensors: what a llama.cpp LoRA adapter is. Only the parts an
/// adapter needs: string, float and integer metadata, and F32 tensors of one or two dimensions.
struct CompletionGGUFWriter {
    enum Value {
        case string(String)
        case float(Float)
        case uint32(UInt32)
    }

    /// A tensor as rows of numbers, row after row (as numpy and MLX keep a matrix). GGUF lists the dimensions the other way
    /// round, the fastest-changing first: a matrix of `rows` × `columns` is written with the dimensions [columns, rows].
    struct Tensor {
        var name: String
        var rows: Int
        var columns: Int
        var values: [Float]
    }

    static let alignment = 32
    private static let typeF32: UInt32 = 0

    private(set) var metadata: [(key: String, value: Value)] = []
    private(set) var tensors: [Tensor] = []

    mutating func add(_ key: String, _ value: Value) { metadata.append((key, value)) }

    mutating func add(_ tensor: Tensor) {
        precondition(tensor.values.count == tensor.rows * tensor.columns, "tensor \(tensor.name) has the wrong number of values")
        tensors.append(tensor)
    }

    func data() -> Data {
        var out = Data()
        out.append(contentsOf: Array("GGUF".utf8))
        out.append(le: UInt32(3))
        out.append(le: UInt64(tensors.count))
        out.append(le: UInt64(metadata.count))
        for (key, value) in metadata {
            out.append(gguf: key)
            switch value {
            case .uint32(let number):
                out.append(le: UInt32(4))
                out.append(le: number)
            case .float(let number):
                out.append(le: UInt32(6))
                out.append(le: number.bitPattern)
            case .string(let text):
                out.append(le: UInt32(8))
                out.append(gguf: text)
            }
        }
        var offset = 0
        var offsets: [Int] = []
        for tensor in tensors {
            offsets.append(offset)
            offset = Self.aligned(offset + tensor.values.count * 4)
        }
        for (tensor, start) in zip(tensors, offsets) {
            out.append(gguf: tensor.name)
            let dimensions: [Int] = tensor.rows == 1 ? [tensor.columns] : [tensor.columns, tensor.rows]
            out.append(le: UInt32(dimensions.count))
            for dimension in dimensions { out.append(le: UInt64(dimension)) }
            out.append(le: Self.typeF32)
            out.append(le: UInt64(start))
        }
        out.pad(to: Self.alignment)
        for tensor in tensors {
            tensor.values.withUnsafeBufferPointer { buffer in
                // Apple silicon and Intel Macs are little-endian, as GGUF is.
                out.append(Data(buffer: buffer))
            }
            out.pad(to: Self.alignment)
        }
        return out
    }

    private static func aligned(_ value: Int) -> Int { (value + alignment - 1) / alignment * alignment }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(gguf text: String) {
        let bytes = Array(text.utf8)
        append(le: UInt64(bytes.count))
        append(contentsOf: bytes)
    }

    mutating func pad(to alignment: Int) {
        let extra = (alignment - count % alignment) % alignment
        append(contentsOf: [UInt8](repeating: 0, count: extra))
    }
}
