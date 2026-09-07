import Foundation

/// 服务端就是电脑上那套（/opt/dict 里的 dictsrv.py），一行都不用改。
/// 这里只把它的接口翻成 Swift。地址在设置里改，默认局域网那台。
enum Api {

    static var base: String {
        get { UserDefaults.standard.string(forKey: "serverBase") ?? "https://192.168.8.191:8445" }
        set { UserDefaults.standard.set(newValue, forKey: "serverBase") }
    }

    static func url(_ path: String) -> URL {
        URL(string: base + path)!
    }

    // MARK: - 模型

    struct Sentence: Codable, Identifiable, Hashable {
        var src: String
        var en: String
        var cn: String?
        var grp: String?
        var gnum: String?
        var dfe: String?
        var tag: String?
        var kind: String?
        var bold: [String]?
        var id: String { src }
    }

    struct Prog: Codable, Hashable {
        var due: Double?
        var ivl: Double?
        var reps: Int?
        var state: Int?
        var score: Double?
        var fav: Int?
        var marks: Int?
    }

    struct SentResp: Codable {
        var word: String
        var items: [Sentence]
        var prog: [String: Prog]
        var inlib: Bool?
    }

    struct Word: Codable, Hashable { var w: String; var s: Double; var e: Double }
    struct AlignResp: Codable { var words: [Word]?; var pending: Bool? }

    struct Card: Codable, Identifiable, Hashable {
        var src: String
        var word: String?
        var en: String
        var cn: String?
        var grp: String?
        var tag: String?
        var kind: String?
        var reps: Int?
        var due: Double?
        var id: String { src }
    }
    struct DueResp: Codable { var cards: [Card] }
    struct LookupResp: Codable { var word: String?; var html: String?; var error: String? }
    struct Mark: Codable, Hashable, Identifiable { var id: Int?; var s: Double; var e: Double }
    struct MarksResp: Codable { var marks: [Mark] }
    struct Counts: Codable { var words: Int; var cards: Int; var due: Int; var fresh: Int
                             var fine: Int; var fav: Int; var today: Int; var recs: Int }
    struct LibWord: Codable, Identifiable, Hashable {
        var w: String; var n: Int; var fine: Int; var due: Int; var last: Double?
        var id: String { w }
    }
    struct LibResp: Codable { var words: [LibWord]; var counts: Counts }
    struct HistWord: Codable, Identifiable, Hashable { var w: String; var n: Int; var id: String { w } }
    struct HistResp: Codable { var words: [HistWord] }
    struct GradeResp: Codable { struct C: Codable { var due: Double; var reps: Int; var ivl: Double }
                                var card: C }

    // MARK: - 传输

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c, delegate: CertTrust.shared, delegateQueue: nil)
    }()

    static func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let (d, _) = try await session.data(from: url(path))
        return try JSONDecoder().decode(T.self, from: d)
    }

    @discardableResult
    static func post<T: Decodable>(_ path: String, _ body: [String: Any], as: T.Type) async throws -> T {
        var r = URLRequest(url: url(path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, _) = try await session.data(for: r)
        return try JSONDecoder().decode(T.self, from: d)
    }

    struct OK: Codable { var ok: Bool? }

    // MARK: - 具体接口

    static func sentences(_ w: String) async throws -> SentResp {
        try await get("/api/sent?w=" + esc(w), as: SentResp.self)
    }
    static func lookup(_ w: String) async throws -> LookupResp {
        try await get("/api/lookup?w=" + esc(w), as: LookupResp.self)
    }
    static func suggest(_ q: String) async throws -> [String] {
        struct R: Codable { var words: [String] }
        return try await get("/api/suggest?q=" + esc(q) + "&n=14", as: R.self).words
    }
    static func align(_ src: String) async throws -> [Word] {
        (try await get("/api/align?src=" + esc(src), as: AlignResp.self)).words ?? []
    }
    static func due(_ n: Int = 40) async throws -> [Card] {
        try await get("/api/due?n=\(n)", as: DueResp.self).cards
    }
    static func marks(_ src: String) async throws -> [Mark] {
        try await get("/api/marks?src=" + esc(src), as: MarksResp.self).marks
    }
    static func setMarks(_ src: String, _ marks: [Mark]) async throws {
        _ = try await post("/api/marks", ["src": src,
            "marks": marks.map { ["s": $0.s, "e": $0.e] }], as: OK.self)
    }
    static func grade(_ src: String, _ q: Int, score: Double? = nil,
                      meta: [String: Any] = [:]) async throws -> GradeResp {
        var b: [String: Any] = ["src": src, "q": q]
        if let s = score { b["score"] = s }
        b.merge(meta) { a, _ in a }
        return try await post("/api/grade", b, as: GradeResp.self)
    }
    static func fav(_ src: String, _ on: Bool, meta: [String: Any] = [:]) async throws {
        var b: [String: Any] = ["src": src, "on": on]
        b.merge(meta) { a, _ in a }
        _ = try await post("/api/fav", b, as: OK.self)
    }
    static func addWord(_ w: String) async throws {
        _ = try await post("/api/word", ["w": w, "on": true], as: OK.self)
    }
    static func lib() async throws -> LibResp { try await get("/api/lib", as: LibResp.self) }
    static func counts() async throws -> Counts { try await get("/api/counts", as: Counts.self) }
    static func hist() async throws -> [HistWord] {
        try await get("/api/hist?n=40", as: HistResp.self).words
    }
    static func histAdd(_ w: String) async {
        _ = try? await post("/api/hist", ["w": w], as: OK.self)
    }
    static func uploadRec(_ src: String, data: Data, ext: String,
                          score: Double?, heard: String, dur: Double) async {
        var c = URLComponents(string: base + "/api/rec")!
        c.queryItems = [.init(name: "src", value: src), .init(name: "ext", value: ext),
                        .init(name: "heard", value: heard), .init(name: "dur", value: String(dur))]
        if let s = score { c.queryItems?.append(.init(name: "score", value: String(s))) }
        var r = URLRequest(url: c.url!)
        r.httpMethod = "POST"
        r.httpBody = data
        _ = try? await session.data(for: r)
    }
    /// 本机 whisper 听写（跟读打分用）
    static func recognize(wav: Data) async throws -> String {
        let boundary = "----lingo\(Int(Date().timeIntervalSince1970 * 1000))"
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (k, v) in [("temperature", "0"), ("response_format", "json")] {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n")
        add("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        add("\r\n--\(boundary)--\r\n")
        var r = URLRequest(url: url("/asr/inference"))
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 120
        let (d, _) = try await session.data(for: r)
        struct R: Codable { var text: String? }
        return (try? JSONDecoder().decode(R.self, from: d))?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

/// 自签证书：只对配置里的那台服务器放行，别的照常校验。
final class CertTrust: NSObject, URLSessionDelegate {
    static let shared = CertTrust()
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let host = URL(string: Api.base)?.host,
              challenge.protectionSpace.host == host
        else { completionHandler(.performDefaultHandling, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
