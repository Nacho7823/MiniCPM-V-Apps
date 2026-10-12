//
//  MBCLIPMetadataProbe.swift
//  MiniCPM-V-demo
//
//  Reads the GGUF metadata of an mmproj (CLIP) file and reports which vision
//  tower it actually is.
//
//  Why this exists: the V4.7 demo ships a text tower (35a3_hf_v47, qwen35moe)
//  that pairs with exactly one vision tower (clip.projector_type = minicpmv4_6,
//  llava-uhd slicing).  Running it with a Qwen3-VL-shaped mmproj still *loads*
//  — both graph builders exist in the framework — but silently switches the
//  image path to Qwen's dyn_size / image_max_tokens budget, which collapses a
//  12 MP photo into ~500 vision tokens and hides the slice slider.  File-name
//  checks and MD5s cannot catch a "correct name, wrong conversion" case, so we
//  read the metadata and compare the projector type explicitly.
//
//  Only the GGUF header (KV section) is read, in chunks, so this is cheap even
//  for the 1 GiB V4.7 mmproj.
//

import Foundation

enum MBCLIPMetadataProbe {

    struct VisionInfo {
        let projectorType: String
        let hasVisionEncoder: Bool
        let imageSize: Int?
        let patchSize: Int?
        let spatialMergeSize: Int?
        let projectorScaleFactor: Int?
        let imageMaxPixels: Int?

        /// "minicpmv4_6" is the projector both MiniCPM-V 4.6 and the V4.7
        /// (35a3_hf_v47) vision tower are exported as.  It is the marker for
        /// the llava-uhd slicing path.  "minicpmv4_7" is the same tower exported
        /// by upstream llama.cpp for the V4.7 **1B** (dense) checkpoint — same
        /// graph, same slicing, so it takes the identical path.
        var usesLLaVAUHDSlicing: Bool {
            projectorType == "minicpmv4_6" || projectorType == "minicpmv4_7"
        }

        var summary: String {
            var parts: [String] = [
                "projector=\(projectorType)",
                "image_size=\(imageSize.map(String.init) ?? "-")",
                "patch=\(patchSize.map(String.init) ?? "-")"
            ]
            if let m = spatialMergeSize { parts.append("spatial_merge=\(m)") }
            if let s = projectorScaleFactor { parts.append("scale_factor=\(s)") }
            parts.append("image_max_pixels=\(imageMaxPixels.map(String.init) ?? "-")")
            return parts.joined(separator: " ")
        }
    }

    enum ProbeError: LocalizedError {
        case notGGUF
        case unsupportedVersion(UInt32)
        case truncated(String)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .notGGUF:
                return "不是 GGUF 文件（magic 不匹配）"
            case .unsupportedVersion(let v):
                return "GGUF 版本 \(v) 暂不支持解析"
            case .truncated(let where_):
                return "GGUF 头在 \(where_) 处被截断"
            case .io(let msg):
                return "读取失败：\(msg)"
            }
        }
    }

    static func readVisionInfo(at url: URL) throws -> VisionInfo {
        let reader = try GGUFKVReader(url: url)

        let magic = try reader.readString(length: 4)
        guard magic == "GGUF" else { throw ProbeError.notGGUF }
        let version = try reader.readU32()
        guard version <= 3 else { throw ProbeError.unsupportedVersion(version) }
        _ = try reader.readU64()               // n_tensors
        let nKV = try reader.readU64()

        var projectorType = ""
        var imageSize: Int?
        var patchSize: Int?
        var spatialMerge: Int?
        var scaleFactor: Int?
        var maxPixels: Int?
        var hasVision = false

        for _ in 0..<min(nKV, 4096) {
            let key = try reader.readString()
            let type = try reader.readU32()

            switch (key, type) {
            case ("clip.projector_type", 8):
                projectorType = try reader.readString()
            case ("clip.has_vision_encoder", 7):
                hasVision = try reader.readBool()
            case ("clip.vision.image_size", 4), ("clip.vision.image_size", 5):
                imageSize = Int(try reader.readU32())
            case ("clip.vision.patch_size", 4), ("clip.vision.patch_size", 5):
                patchSize = Int(try reader.readU32())
            case ("clip.vision.spatial_merge_size", 4), ("clip.vision.spatial_merge_size", 5):
                spatialMerge = Int(try reader.readU32())
            case ("clip.vision.projector.scale_factor", 4), ("clip.vision.projector.scale_factor", 5):
                scaleFactor = Int(try reader.readU32())
            case ("clip.vision.image_max_pixels", 4), ("clip.vision.image_max_pixels", 5):
                maxPixels = Int(try reader.readU32())
            default:
                try reader.skipValue(type: type)
            }
        }

        return VisionInfo(
            projectorType: projectorType,
            hasVisionEncoder: hasVision,
            imageSize: imageSize,
            patchSize: patchSize,
            spatialMergeSize: spatialMerge,
            projectorScaleFactor: scaleFactor,
            imageMaxPixels: maxPixels
        )
    }

    // MARK: - Minimal GGUF KV reader

    /// GGUF value type ids (see gguf-py/gguf/constants.py).
    private enum GGUFType: UInt32 {
        case uint8 = 0, int8 = 1, uint16 = 2, int16 = 3, uint32 = 4, int32 = 5
        case float32 = 6, bool = 7, string = 8, array = 9, uint64 = 10, int64 = 11, float64 = 12
    }

    private final class GGUFKVReader {
        private let handle: FileHandle
        private var buffer = Data()
        private var consumed = 0        // bytes of `buffer` already used
        private var eof = false
        private let chunkSize: Int

        init(url: URL, chunkSize: Int = 1 << 20) throws {
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw ProbeError.io(error.localizedDescription)
            }
            self.chunkSize = chunkSize
        }

        deinit {
            try? handle.close()
        }

        private func fill(_ needed: Int) throws {
            while buffer.count - consumed < needed && !eof {
                guard let more = try? handle.read(upToCount: chunkSize), !more.isEmpty else {
                    eof = true
                    break
                }
                // drop already-consumed prefix so the buffer does not grow
                if consumed > 0 {
                    buffer.removeSubrange(0..<consumed)
                    consumed = 0
                }
                buffer.append(more)
            }
            if buffer.count - consumed < needed {
                throw ProbeError.truncated("metadata")
            }
        }

        private func take(_ n: Int) throws -> Data {
            try fill(n)
            let slice = buffer.subdata(in: consumed..<(consumed + n))
            consumed += n
            return slice
        }

        func readU32() throws -> UInt32 {
            let d = try take(4)
            return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }

        func readU64() throws -> UInt64 {
            let d = try take(8)
            return d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }

        func readBool() throws -> Bool {
            try take(1)[0] != 0
        }

        func readString(length: Int) throws -> String {
            String(decoding: try take(length), as: UTF8.self)
        }

        /// GGUF strings are u64 length + raw bytes (no NUL terminator).
        func readString() throws -> String {
            let len = Int(try readU64())
            guard len >= 0, len <= 1 << 20 else { throw ProbeError.truncated("string length \(len)") }
            return try readString(length: len)
        }

        func skipValue(type: UInt32) throws {
            guard let t = GGUFType(rawValue: type) else {
                throw ProbeError.truncated("unknown gguf type \(type)")
            }
            switch t {
            case .uint8, .int8, .bool:   _ = try take(1)
            case .uint16, .int16:        _ = try take(2)
            case .uint32, .int32, .float32: _ = try take(4)
            case .uint64, .int64, .float64: _ = try take(8)
            case .string:                _ = try readString()
            case .array:
                let elemType = try readU32()
                let count = Int(try readU64())
                guard count >= 0, count <= 1 << 24 else { throw ProbeError.truncated("array count \(count)") }
                for _ in 0..<count {
                    try skipValue(type: elemType)
                }
            }
        }
    }
}
