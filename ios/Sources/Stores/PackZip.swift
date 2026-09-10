import Foundation

/// 解材料包用的最小 zip 读取器。
///
/// 为什么自己写而不是引库：iOS 没有自带解 zip 的 API，而开发原则写了
/// "不要为了炫技引入不必要的第三方库"。所以打包那头（mkpack.py）就约定
/// **一律不压缩**（ZIP_STORED）—— mp3 本来压不动，sqlite 那点收益也不值当，
/// 传输时让 CDN 在网络层压。这样这边只要会读目录、按偏移拷字节，
/// 几十行、没有依赖、不会出错。
///
/// 碰到压缩过的条目会明确报错，不会解出半个坏文件。
enum PackZip {
    enum Err: LocalizedError {
        case notZip, compressed(String), truncated, badName(String)
        var errorDescription: String? {
            switch self {
            case .notZip:            return "这不是一个材料包"
            case .compressed(let n): return "包里的 \(n) 是压缩过的，这个版本只认不压缩的包"
            case .truncated:         return "包不完整，可能没下全"
            case .badName(let n):    return "包里有不安全的路径：\(n)"
            }
        }
    }

    /// 解到 dst 目录下。只认 stored，遇到别的直接报错。
    static func unzip(_ src: URL, to dst: URL) throws {
        let d = try Data(contentsOf: src, options: .mappedIfSafe)
        guard d.count > 22 else { throw Err.notZip }

        // 从尾巴往前找"中央目录结束记录"（EOCD，签名 PK\x05\x06）
        var eocd = -1
        let lower = max(0, d.count - 66_000)
        var i = d.count - 22
        while i >= lower {
            if d[i] == 0x50, d[i+1] == 0x4B, d[i+2] == 0x05, d[i+3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Err.notZip }

        let count = Int(u16(d, eocd + 10))
        var p = Int(u32(d, eocd + 16))          // 中央目录起点

        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        for _ in 0..<count {
            guard p + 46 <= d.count,
                  d[p] == 0x50, d[p+1] == 0x4B, d[p+2] == 0x01, d[p+3] == 0x02
            else { throw Err.truncated }
            let method = Int(u16(d, p + 10))
            let size   = Int(u32(d, p + 24))
            let nameLen = Int(u16(d, p + 28))
            let extraLen = Int(u16(d, p + 30))
            let cmtLen = Int(u16(d, p + 32))
            let localOff = Int(u32(d, p + 42))
            guard p + 46 + nameLen <= d.count else { throw Err.truncated }
            let name = String(decoding: d[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + cmtLen

            if name.hasSuffix("/") { continue }                 // 目录条目
            guard method == 0 else { throw Err.compressed(name) }
            // 不许跳出目标目录（zip slip）
            guard !name.hasPrefix("/"), !name.contains("..") else { throw Err.badName(name) }

            // 本地文件头：名字和 extra 的长度可能跟中央目录里的不一样，得重新读
            guard localOff + 30 <= d.count,
                  d[localOff] == 0x50, d[localOff+1] == 0x4B,
                  d[localOff+2] == 0x03, d[localOff+3] == 0x04
            else { throw Err.truncated }
            let lNameLen = Int(u16(d, localOff + 26))
            let lExtraLen = Int(u16(d, localOff + 28))
            let start = localOff + 30 + lNameLen + lExtraLen
            guard start + size <= d.count else { throw Err.truncated }

            let out = dst.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try d[start..<(start + size)].write(to: out)
        }
    }

    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[i]) | UInt16(d[i+1]) << 8
    }
    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i+1]) << 8 | UInt32(d[i+2]) << 16 | UInt32(d[i+3]) << 24
    }
}
