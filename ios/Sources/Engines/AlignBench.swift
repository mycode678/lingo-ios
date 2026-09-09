import SwiftUI

/// 离线引擎的验证屏（只在 -demo -alignbench 下出现）。
///
/// 拿一条服务器已经对齐过的例句，在手机上用 CoreML 重算一遍，逐词比对：
/// 误差多大、跑多久。这决定了"彻底不要服务器"这条路走不走得通。
@available(iOS 17.0, *)
struct AlignBenchView: View {
    @State private var lines: [String] = ["正在跑…"]
    @State private var verdict = ""
    @State private var summary = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary).font(.system(size: 15, weight: .semibold))
                    .accessibilityIdentifier("alignResult")
                if !verdict.isEmpty {
                    Text(verdict).font(.system(size: 15, weight: .bold))
                        .foregroundStyle(verdict.contains("通过") ? .green : .red)
                        .accessibilityIdentifier("alignVerdict")
                }
                Divider()
                ForEach(lines, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await run() }
    }

    private func run() async {
        struct Ref: Decodable {
            struct W: Decodable { let w: String; let s: Double; let e: Double }
            let text: String; let words: [W]
        }
        guard let ju = Bundle.main.url(forResource: "align_ref", withExtension: "json"),
              let ref = try? JSONDecoder().decode(Ref.self, from: Data(contentsOf: ju)),
              let pu = Bundle.main.url(forResource: "align_ref", withExtension: "pcm"),
              let raw = try? Data(contentsOf: pu) else {
            summary = "缺测试素材"; verdict = "不通过：没有素材"; return
        }
        // Int16 → Float
        var pcm = [Float](repeating: 0, count: raw.count / 2)
        raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let s = p.bindMemory(to: Int16.self)
            for i in 0..<pcm.count { pcm[i] = Float(s[i]) / 32768 }
        }

        let t0 = Date()
        do {
            let mine = try await Aligner.shared.align(pcm: pcm, text: ref.text)
            let ms = Date().timeIntervalSince(t0) * 1000
            var rows: [String] = []
            var maxErr = 0.0, sumErr = 0.0
            let n = min(mine.count, ref.words.count)
            for i in 0..<n {
                let a = mine[i], b = ref.words[i]
                let ds = abs(a.start - b.s) * 1000, de = abs(a.end - b.e) * 1000
                maxErr = max(maxErr, max(ds, de)); sumErr += (ds + de) / 2
                rows.append(String(format: "%-10@ 手机 %.2f-%.2f  服务器 %.2f-%.2f  差 %.0f/%.0fms  分%.2f",
                                   a.text as NSString, a.start, a.end, b.s, b.e, ds, de, a.score))
            }
            lines = rows
            summary = String(format: "%d 个词，用时 %.0f 毫秒，平均误差 %.0f 毫秒，最大 %.0f 毫秒",
                             n, ms, sumErr / Double(max(1, n)), maxErr)
            // 80 毫秒以内人耳分辨不出，算通过
            verdict = maxErr <= 80 ? "✅ 通过（最大误差 \(Int(maxErr)) 毫秒）"
                                   : "❌ 不通过（最大误差 \(Int(maxErr)) 毫秒）"
            // 打到控制台，从 Mac 上用 devicectl --console 直接读，
            // 比从 .xcresult 里掏附件可靠（新版 xcresulttool 那条路不通了）
            print("BENCH-BEGIN"); print(summary); print(verdict)
            rows.forEach { print($0) }
            print("BENCH-END")
            fflush(stdout)
        } catch {
            summary = "出错：\(error.localizedDescription)"
            verdict = "❌ 不通过"
        }
    }
}
