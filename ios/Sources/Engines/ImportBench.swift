import SwiftUI
import AVFoundation
import Speech

/// **导入精度基准**（`-demo -usepack -importbench`）。
///
/// 回答一个问题：用户丢进来一个只有声音、没有字幕也没有文稿的文件，
/// 我们自动出的文本和词级时间戳，到底准不准？
///
/// 做法是拿"有标准答案的材料"当考卷：随包的测试材料包里 12 句，
/// 每句都带服务器对齐好的词级时间（`words` 表）。把这些句子的音频
/// **首尾拼成一整条**（句间垫 0.6 秒静音），就等于伪造了一个"用户上传的文件"，
/// 而每个词在这条长音频里的真实时间是**已知**的。
///
/// 然后走 `ImportService.analyze` —— 跟真导入**同一段代码**，不是另写一份。
///
/// 量两个数：
/// · 文本错误率（WER）：错词 + 漏词 + 多词，占标准答案词数的比例；
/// · 词边界误差：对上的词，起点/终点跟标准差多少毫秒（中位数和 p90）。
@available(iOS 17.0, *)
struct ImportBenchView: View {
    @State private var lines: [String] = ["正在跑…"]
    @State private var summary = ""
    @State private var verdict = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary).font(.system(size: 15, weight: .semibold))
                    .accessibilityIdentifier("benchResult")
                if !verdict.isEmpty {
                    Text(verdict).font(.system(size: 15, weight: .bold))
                        .foregroundStyle(verdict.contains("通过") ? .green : .red)
                        .accessibilityIdentifier("benchVerdict")
                }
                Divider()
                ForEach(lines, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await run() }
    }

    /// 拼接时句与句之间垫多少静音。太短会被当成一句连读，太长浪费时间。
    private let gap = 0.6
    private let sr = 16000.0

    private func log(_ s: String) { print(s); lines.append(s) }

    private func run() async {
        print("BENCH-BEGIN")
        defer { print("BENCH-END") }
        let cat = CatalogService.shared
        guard let pack = cat.packs().first else {
            summary = "没有装材料包"; verdict = "不通过：没素材"; print("BENCH 没有材料包"); return
        }
        let sents = cat.sentences(pack.id, limit: 200)
        guard !sents.isEmpty else {
            summary = "包里没句子"; verdict = "不通过：没素材"; print("BENCH 包里没句子"); return
        }
        lines = []
        log("考卷：\(pack.name) \(sents.count) 句")

        // ---- 拼成一条长音频，顺带记下每个词的真实时间 ----
        var big: [Float] = []
        var truth: [(w: String, s: Double, e: Double)] = []
        let silence = [Float](repeating: 0, count: Int(gap * sr))
        let imp = ImportService.shared
        for st in sents {
            guard let pcm = try? await imp.decode16k(st.audio), pcm.count > Int(sr * 0.3) else {
                log("× 读不出音频：\(st.id)"); continue
            }
            let off = Double(big.count) / sr
            for w in cat.words(pack.id, st.id) {
                truth.append((w.w, w.s + off, w.e + off))
            }
            big.append(contentsOf: pcm)
            big.append(contentsOf: silence)
        }
        guard truth.count > 5 else {
            summary = "标准答案不够"; verdict = "不通过：没素材"; print("BENCH 标准答案不够"); return
        }
        log(String(format: "拼成 %.1f 秒，标准答案 %d 个词", Double(big.count) / sr, truth.count))

        // ---- 先自检：出 0 句的时候，得当场知道是谁没干活 ----
        // （第一次跑就栽在这儿：出了 0 句 0 词，但看不出是识别没权限还是对齐没模型）
        let auth = SFSpeechRecognizer.authorizationStatus()
        let authName: String
        switch auth {
        case .authorized: authName = "给了"
        case .denied: authName = "被拒了"
        case .restricted: authName = "被限制"
        case .notDetermined: authName = "还没问过"
        @unknown default: authName = "不认识的状态"
        }
        let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        log("识别权限：\(authName)；识别器可用：\(rec?.isAvailable == true)；"
            + "本机识别支持：\(rec?.supportsOnDeviceRecognition == true)")
        log("对齐模型在不在：\(Aligner.shared.isAvailable)")
        if auth == .notDetermined {
            let ok = await Speech.shared.ask()
            log("现问了一次权限：\(ok ? "给了" : "没给")")
        }
        // 单独试一小段，把识别的真实报错打出来（analyze 里是 try? 吞掉的）
        let probe = Array(big.prefix(Int(sr * 12)))
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("bench-probe.wav")
            try imp.writeWav(probe, to: tmp)
            let text = try await Speech.shared.transcribe(tmp)
            log("试听前 12 秒：「\(text)」")
            try? FileManager.default.removeItem(at: tmp)
        } catch {
            log("试听失败：\(error.localizedDescription) —— \(error)")
        }

        // ---- 走真流水线 ----
        let t0 = Date()
        var got: [(en: String, words: [Aligner.Word])] = []
        do {
            got = try await imp.analyze(pcm: big) { text, _ in print("BENCH 进度 \(text)") }
        } catch {
            summary = "跑挂了：\(error.localizedDescription)"; verdict = "不通过"
            print("BENCH 出错 \(error)"); return
        }
        let secs = Date().timeIntervalSince(t0)
        let hyp = got.flatMap { $0.words }
        log(String(format: "跑完用 %.0f 秒（音频 %.0f 秒，%.2fx 实时）；出了 %d 句 %d 词",
                   secs, Double(big.count) / sr, secs / (Double(big.count) / sr),
                   got.count, hyp.count))

        // ---- 比对 ----
        let refW = truth.map { norm($0.w) }
        let hypW = hyp.map { norm($0.text) }
        let ops = diff(refW, hypW)
        let sub = ops.filter { $0.kind == .sub }.count
        let del = ops.filter { $0.kind == .del }.count
        let ins = ops.filter { $0.kind == .ins }.count
        let wer = Double(sub + del + ins) / Double(max(1, refW.count)) * 100

        var errS: [Double] = [], errE: [Double] = []
        for o in ops where o.kind == .ok {
            errS.append(abs(hyp[o.j].start - truth[o.i].s) * 1000)
            errE.append(abs(hyp[o.j].end - truth[o.i].e) * 1000)
        }
        let medS = median(errS), p90S = pct(errS, 0.9)
        let medE = median(errE), p90E = pct(errE, 0.9)

        summary = String(format: "文本错误率 %.1f%%（换 %d 漏 %d 多 %d / 共 %d 词）\n"
                         + "词起点误差 中位 %.0fms p90 %.0fms；终点 中位 %.0fms p90 %.0fms",
                         wer, sub, del, ins, refW.count, medS, p90S, medE, p90E)
        // 闸门：文本 2% 以内、起点中位数 50ms 以内才算"精准对齐"
        let pass = wer <= 2.0 && medS <= 50
        verdict = pass ? "通过" : "不通过（目标：错误率≤2%、起点中位≤50ms）"
        print("BENCH 结果 " + summary.replacingOccurrences(of: "\n", with: " / "))
        print("BENCH 判定 " + verdict)

        // 逐处错在哪，看得见才改得动
        log("—— 错在哪 ——")
        for o in ops where o.kind != .ok {
            switch o.kind {
            case .sub: log("  换：标准「\(refW[o.i])」→ 认成「\(hypW[o.j])」")
            case .del: log("  漏：「\(refW[o.i])」")
            case .ins: log("  多：「\(hypW[o.j])」")
            case .ok:  break
            }
        }
        log("—— 认出来的句子 ——")
        for g in got { log("  · " + g.en) }
    }

    // MARK: 小工具

    private func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }
    private func median(_ a: [Double]) -> Double { pct(a, 0.5) }
    private func pct(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return -1 }
        let s = a.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))]
    }

    private enum Kind { case ok, sub, del, ins }
    private struct Op { var kind: Kind; var i: Int; var j: Int }

    /// 词级编辑距离 + 回溯。要的不只是数字，还要"哪个词对上了哪个词"，
    /// 因为边界误差只能在**对上的词**之间算。
    private func diff(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let c = a[i - 1] == b[j - 1] ? 0 : 1
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c)
                }
            }
        }
        var out: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                out.append(Op(kind: a[i - 1] == b[j - 1] ? .ok : .sub, i: i - 1, j: j - 1))
                i -= 1; j -= 1
            } else if i > 0 && d[i][j] == d[i - 1][j] + 1 {
                out.append(Op(kind: .del, i: i - 1, j: max(0, j - 1))); i -= 1
            } else {
                out.append(Op(kind: .ins, i: max(0, i - 1), j: j - 1)); j -= 1
            }
        }
        return out.reversed()
    }
}
