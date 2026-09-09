import SwiftUI

/// 跟读结果：不光给分，要说清楚**哪个词不对、为什么、怎么改**。
///
/// 三块，从上到下按"最该先看"排：
///   ① 一句话诊断 —— 最重要，直接告诉你毛病在哪、怎么练
///   ② 逐词标色   —— 点任一个词，先放原声再放你的，来回听差别
///   ③ 三个分项   —— 音准/节奏/连读，知道自己弱在哪一项
struct CompareView: View {
    let diff: Compare
    @ObservedObject var rec = Recorder.shared
    @State private var playing: Int?
    /// 跟读结果这块的字号，用户自己调（精听设置里）。
    /// 默认 17 —— 之前按 13/15 排，他在 6.5 寸屏上还是嫌小。
    @AppStorage("ui.resultFont") private var base = 17.0
    private var fSmall: CGFloat { CGFloat(base) - 3 }
    private var fBody: CGFloat { CGFloat(base) }
    private var fWord: CGFloat { CGFloat(base) + 2 }
    private var fNum: CGFloat { CGFloat(base) + 7 }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            notes
            wordRow
            scores
            legend
        }
    }

    // MARK: ① 诊断

    private var notes: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            ForEach(diff.notes) { n in
                HStack(alignment: .top, spacing: T.s2) {
                    Image(systemName: icon(n.kind))
                        .font(.system(size: fBody))
                        .foregroundStyle(color(n.kind))
                        .frame(width: 20)
                    // 诊断是这块最该看清的东西 —— 15pt 起步，行距放开
                    Text(n.text)
                        .font(.system(size: fBody))
                        .lineSpacing(fBody * 0.22)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(T.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
    }

    private func icon(_ k: Compare.Note.Kind) -> String {
        switch k {
        case .rhythm:  return "metronome"
        case .liaison: return "link"
        case .stress:  return "waveform.path"
        case .sound:   return "ear"
        case .good:    return "checkmark.circle"
        }
    }
    private func color(_ k: Compare.Note.Kind) -> Color {
        k == .good ? T.Score.good : .orange
    }

    // MARK: ② 逐词标色，点了单独听

    private var wordRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(diff.words) { w in
                Button { play(w) } label: { chip(w) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func chip(_ w: Compare.WordDiff) -> some View {
        let c = T.Score.of(w.accuracy)
        let slow = w.isFunction && w.durRatio > 1.6      // 虚词念太长：中式英语的头号特征
        return VStack(spacing: 2) {
            Text(w.text)
                .font(.system(size: fWord, weight: w.natStressed ? .semibold : .regular))
                .foregroundStyle(playing == w.id ? Color.white : c)
            // 底下那条线的长短＝你念的时长相对原声。超过一格说明念长了。
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(c.opacity(0.18)).frame(height: 2)
                    Capsule().fill(slow ? Color.orange : c)
                        .frame(width: min(g.size.width, g.size.width * w.durRatio), height: 2)
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(playing == w.id ? c : c.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(w.linkAfter && !w.myLinkAfter ? Color.orange : .clear,
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// 点一个词：先放原声那半秒，再放你念的那半秒 —— 差别最听得出来
    private func play(_ w: Compare.WordDiff) {
        playing = w.id
        rec.playWordAB(nat: w.natStart...max(w.natStart + 0.08, w.natEnd),
                       mine: w.myStart...max(w.myStart + 0.08, w.myEnd)) {
            DispatchQueue.main.async { if playing == w.id { playing = nil } }
        }
    }

    // MARK: ③ 三个分项

    /// 三个分项等宽排一行。
    /// 必须**顶部对齐 + 等宽**：字号调大后有的说明折两行、有的一行，
    /// 默认的居中对齐会让没折行的那项浮在半空（他截图里"连读 63"就是）。
    private var scores: some View {
        HStack(alignment: .top, spacing: T.s2) {
            item("音准", diff.soundScore, "发音像不像")
            item("节奏", diff.rhythmScore, "轻重快慢")
            item("连读", diff.linkScore, "该连的连了没")
        }
    }

    private func item(_ k: String, _ v: Int, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(k).font(.system(size: fBody)).foregroundStyle(.secondary)
                Text("\(v)").font(.system(size: fNum, weight: .semibold))
                    .monospacedDigit().foregroundStyle(T.Score.of(v))
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            Text(hint)
                .font(.system(size: fSmall)).foregroundStyle(.tertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legend: some View {
        Text("点任意一个词：先听母语者，再听你的。橙色下划线＝这个虚词念太长，"
             + "虚线框＝这儿该和下个词连读。")
            .font(.system(size: fSmall)).foregroundStyle(.tertiary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
