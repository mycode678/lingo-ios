import Foundation

/// AI 教练：拿原声和你的录音的**逐词差异**去问大模型，要一段能照着练的话。
///
/// 用户的原话：「我一直在想让非英语母语的人能够从声音上拆解句子，
/// 能让他们分辨出母语人士说和自己说之间的差别，并能据此纠正……
/// 这个是我接下来重点考虑的，也是这款 app 的核心之一」。
///
/// 设计上的两个要点：
/// 1. **不把音频发出去**。发的只有"哪个词、原声多长、你多长、该连没连"这些数字。
///    录音永远不出这台手机（方案红线），也让隐私政策写得干净。
/// 2. 断网、没 key、超额度，一律**降级不报错** —— 本机那套逐词打分和一句话诊断
///    照常给，AI 只是锦上添花。
@MainActor
final class CoachService: ObservableObject {
    static let shared = CoachService(db: .user)
    private let db: DB
    init(db: DB) { self.db = db }

    enum Provider: String, CaseIterable {
        case deepseek, openrouter
        var url: URL {
            switch self {
            case .deepseek:   return URL(string: "https://api.deepseek.com/chat/completions")!
            case .openrouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            }
        }
        var model: String {
            switch self {
            case .deepseek:   return "deepseek-chat"
            case .openrouter: return "deepseek/deepseek-chat"
            }
        }
        var display: String { self == .deepseek ? "DeepSeek" : "OpenRouter" }
    }

    enum Err: LocalizedError {
        case noKey, quota(Int), http(Int, String), empty
        var errorDescription: String? {
            switch self {
            case .noKey:            return "还没填 AI 的 key（在「我的 → 设置」里填）"
            case .quota(let n):     return "今天的 AI 拆解用完了（每天 \(n) 句）"
            case .http(let c, let m): return m.isEmpty ? "AI 服务返回 \(c)" : m
            case .empty:            return "AI 没给出内容"
            }
        }
    }

    // MARK: key

    var provider: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: "ai.provider") ?? "") ?? .deepseek
    }
    var key: String { UserDefaults.standard.string(forKey: "ai.key") ?? "" }
    var hasKey: Bool { !key.isEmpty }

    // MARK: 额度
    //
    // 方案：免费用户「每天最多 100 个，最多用 7 天」。
    // 计数落本机（脱离服务器是第一原则），跨天自动归零。

    static let freeDaily = 100

    /// 额度统一交给 `EntitlementService` 管 —— 会员档位不同、免费的还是七天试用，
    /// 这些规则只该有一处。（原来这儿自己记一套，加了会员之后就会两套数打架。）
    private var ent: EntitlementService { .shared }

    func usedToday() -> Int { ent.used(.ai) }
    func remainingToday() -> Int { ent.remaining(.ai) ?? Int.max }
    private func bump() { ent.consume(.ai) }

    // MARK: 拆解

    /// 把逐词比对的结果讲成人话。返回 Markdown 风格的纯文本。
    func explain(sentence: String, diff: Compare) async throws -> String {
        guard hasKey else { throw Err.noKey }
        guard ent.allowed(.ai) else { throw Err.quota(ent.cap(.ai) ?? 0) }

        // 只发数字，不发音频。每个词一行：原声多长、你多长、准不准、该连没连。
        var lines: [String] = []
        for w in diff.words {
            let nat = Int((w.natEnd - w.natStart) * 1000)
            let mine = Int((w.myEnd - w.myStart) * 1000)
            var tags: [String] = []
            if w.isFunction { tags.append("虚词") }
            if w.natWeak { tags.append("原声弱读") }
            if w.linkAfter { tags.append(w.myLinkAfter ? "该连已连" : "该连没连") }
            if w.natStressed { tags.append("原声重读") }
            lines.append("\(w.text)｜原声\(nat)ms｜你\(mine)ms｜准确度\(w.accuracy)"
                         + (tags.isEmpty ? "" : "｜" + tags.joined(separator: "、")))
        }

        let prompt = """
        你是英语听说教练，学生是中国人。下面是他跟读一句话的逐词测量数据（不是音频）。

        原句：\(sentence)
        总分 \(diff.overall)（音准 \(diff.soundScore) 节奏 \(diff.rhythmScore) 连读 \(diff.linkScore)）

        逐词数据：
        \(lines.joined(separator: "\n"))

        请用**中文大白话**回答，不要术语堆砌，不要客套，直接说问题：
        1. 最该先改的一个毛病是什么（只说一个，说清楚为什么这么判断）
        2. 怎么练：给一个具体到"念哪几个词、怎么念"的练法，一句话
        3. 把这句话按意群切成 2–4 块，标出每块里该重读的词（用大写标出来）

        总共不超过 200 字。
        """

        var req = URLRequest(url: provider.url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": provider.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.3,
            "max_tokens": 400,
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            var msg = ""
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = j["error"] as? [String: Any], let m = e["message"] as? String {
                msg = m
            }
            if h.statusCode == 401 { msg = "key 不对（401）" + (msg.isEmpty ? "" : "：" + msg) }
            if h.statusCode == 402 { msg = "余额不足（402）" }
            if h.statusCode == 429 { msg = "被限流了，过一会儿再试" }
            throw Err.http(h.statusCode, msg)
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = j["choices"] as? [[String: Any]],
              let m = choices.first?["message"] as? [String: Any],
              let text = m["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Err.empty }

        bump()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
