import Foundation

/// 音频缓存：听过的句子留在手机里，走路时没网也能练。
/// 词典的例句音频都很小（平均 2.3 秒，约 20KB），一个词 30 条也就 600KB，
/// 所以策略很简单：按需下载 + 整词预取，超过上限按最久没用的删。
actor Cache {
    static let shared = Cache()

    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var limitBytes: Int64 = 400 * 1024 * 1024
    private var inflight: [String: Task<URL, Error>] = [:]

    private func fileURL(for src: String) -> URL {
        // /res/exa/bre/d/p008-001228035.mp3 → res_exa_bre_d_p008-001228035.mp3
        let name = src.dropFirst().replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent(String(name))
    }

    func isCached(_ src: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: src).path)
    }

    /// 本地有就直接给，没有就下（同一条并发只下一次）
    func localURL(for src: String) async throws -> URL {
        let f = fileURL(for: src)
        if FileManager.default.fileExists(atPath: f.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
            return f
        }
        if let t = inflight[src] { return try await t.value }
        let task = Task<URL, Error> {
            var req = URLRequest(url: Api.url(src))
            if let a = Api.authHeader { req.setValue(a, forHTTPHeaderField: "Authorization") }
            let (tmp, _) = try await URLSession(configuration: .default,
                                                delegate: CertTrust.shared, delegateQueue: nil)
                .download(for: req)
            try? FileManager.default.removeItem(at: f)
            try FileManager.default.moveItem(at: tmp, to: f)
            return f
        }
        inflight[src] = task
        defer { inflight[src] = nil }
        let url = try await task.value
        Task { await trim() }
        return url
    }

    /// 把一个词的所有例句先下下来，出门前点一下就行
    func prefetch(_ srcs: [String], progress: (@Sendable (Int, Int) -> Void)? = nil) async {
        var done = 0
        for s in srcs {
            _ = try? await localURL(for: s)
            done += 1
            progress?(done, srcs.count)
        }
    }

    func size() -> Int64 {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
            .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
    }

    func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 超了上限就按"最久没听过"删到八成
    private func trim() {
        guard size() > limitBytes else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys)) ?? []
        files.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
        var total = size()
        for f in files where total > Int64(Double(limitBytes) * 0.8) {
            let sz = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: f)
            total -= sz
        }
    }
}
