import SwiftUI

/// 精听台 —— 这个 App 的主场。
/// 从上到下就是练一句话的动作顺序：看句子 → 挑一个小句 → 在波形上圈准 → 反复听 → 打分。
/// 播放控制钉在底部，走路时拇指够得到。
struct DrillScreen: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: Player
    @StateObject private var vm = DrillModel()
    @State private var showText = true
    @State private var showWalk = false
    @State private var graded: String?

    var body: some View {
        NavigationStack {
            Group {
                if let s = store.current {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            header(s)
                            sentenceCard(s)
                            if !vm.chunks.isEmpty { chunkRow }
                            waveBlock
                            selectionBar
                            gradeRow(s)
                            Color.clear.frame(height: 96)      // 给底部控制条留位置
                        }
                        .padding(.horizontal, 14)
                    }
                    .safeAreaInset(edge: .bottom) { transport }
                    .task(id: s.src) { await vm.load(s) }
                } else {
                    ContentUnavailableView("还没选句子",
                        systemImage: "waveform",
                        description: Text("去「查词」查一个词，点它的例句；或者去「复习」拿今天到期的。"))
                }
            }
            .navigationTitle("精听")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showWalk = true } label: { Image(systemName: "headphones") }
                }
            }
            .sheet(isPresented: $showWalk) {
                WalkScreen(startSegment: vm.selection)
            }
        }
    }

    // MARK: - 各块

    private func header(_ s: Api.Sentence) -> some View {
        HStack(spacing: 10) {
            Text(store.word).font(.title3.weight(.semibold))
            Text("\(store.index + 1) / \(store.items.count)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.bordered).disabled(store.index == 0)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.bordered).disabled(store.index >= store.items.count - 1)
        }
        .padding(.top, 4)
    }

    private func sentenceCard(_ s: Api.Sentence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let g = s.grp, !g.isEmpty {
                Text(g).font(.caption).foregroundStyle(.secondary)
            }
            Text(s.en)
                .font(.system(size: 21, weight: .regular))
                .blur(radius: showText ? 0 : 9)
                .animation(.easeInOut(duration: 0.18), value: showText)
                .onTapGesture { showText.toggle() }
            if let cn = s.cn, !cn.isEmpty, showText {
                Text(cn).font(.system(size: 15)).foregroundStyle(.secondary)
            }
            if let d = s.dfe, !d.isEmpty, showText {
                Divider()
                Text(d).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(showText ? "遮住原文（先盲听）" : "显示原文") { showText.toggle() }
                    .font(.caption)
                Spacer()
                if vm.loading { ProgressView().controlSize(.small) }
                else if !vm.note.isEmpty {
                    Text(vm.note).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// 小句：听不懂整句时，先抠一个意群
    private var chunkRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("小句　点一下就只听这一段").font(.caption2).foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(Array(vm.chunks.enumerated()), id: \.offset) { i, c in
                    let a = vm.words[c.0].s, b = vm.words[c.1].e
                    let on = vm.selection.map { abs($0.lowerBound - a) < 0.02 && abs($0.upperBound - b) < 0.02 } ?? false
                    Button { vm.selectChunk(i) } label: {
                        HStack(spacing: 6) {
                            Text(vm.words[c.0...c.1].map(\.w).joined(separator: " "))
                                .lineLimit(1)
                            Text(String(format: "%.1fs", b - a))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 14))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(on ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(
                            on ? Color.accentColor : Color.clear, lineWidth: 1.5))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var waveBlock: some View {
        VStack(spacing: 6) {
            WaveView(vm: vm)
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 12) {
                Text(fmt(player.position)).monospacedDigit()
                Text("/").foregroundStyle(.secondary)
                Text(fmt(player.duration)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if let s = vm.selection {
                    Text(String(format: "选区 %.2f–%.2fs（%.2fs）",
                                s.lowerBound, s.upperBound, s.upperBound - s.lowerBound))
                        .monospacedDigit()
                } else {
                    Text("选区：整句").foregroundStyle(.secondary)
                }
                if !vm.marks.isEmpty {
                    Text("难点 \(vm.marks.count)").foregroundStyle(.red)
                }
            }
            .font(.caption)
            Text("单指拖＝平移　双指捏＝缩放　点一下＝把最近的边界挪过来　长按拖＝画新选区")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    private var selectionBar: some View {
        HStack(spacing: 6) {
            Button("设 A") { vm.setEdgeAtHead("a") }
            Button("A−") { vm.nudge("a", -0.08) }
            Button("A+") { vm.nudge("a", 0.08) }
            Button("B−") { vm.nudge("b", -0.08) }
            Button("B+") { vm.nudge("b", 0.08) }
            Button("设 B") { vm.setEdgeAtHead("b") }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .font(.system(size: 13))
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) { EmptyView() }
    }

    private func gradeRow(_ s: Api.Sentence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("练完了，给自己打个分 —— 系统按这个决定下次什么时候再问你")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                grade(1, "没听懂", .red)
                grade(2, "勉强", .orange)
                grade(3, "会了", .blue)
                grade(4, "脱口而出", .green)
            }
            if let g = graded { Text(g).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
    private func grade(_ q: Int, _ t: String, _ c: Color) -> some View {
        Button {
            Task {
                guard let s = store.current else { return }
                if let r = try? await Api.grade(s.src, q, meta: store.meta(s)) {
                    let d = (r.card.due - Date().timeIntervalSince1970) / 86400
                    graded = d < 1 ? "下次 \(max(1, Int(d * 24))) 小时后"
                                   : "下次 \(Int(d.rounded())) 天后"
                    await store.refreshProgress()
                }
            }
        } label: {
            Text(t).font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 44)
                .background(c.opacity(0.14)).foregroundStyle(c)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 底部常驻控制条
    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .frame(width: 58, height: 50)
                }
                .buttonStyle(.borderedProminent)

                Button { player.loop.toggle(); if player.loop { player.play() } } label: {
                    Image(systemName: "repeat")
                        .frame(width: 46, height: 50)
                }
                .buttonStyle(player.loop ? .borderedProminent : .bordered)

                ForEach([1.0, 0.75, 0.6, 0.5], id: \.self) { r in
                    Button {
                        player.rate = Float(r)
                        if player.isPlaying { player.play() }
                    } label: {
                        Text(String(format: r == 1 ? "%.0fx" : "%.2gx", r))
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(abs(Double(player.rate) - r) < 0.01 ? .borderedProminent : .bordered)
                }
            }
            HStack(spacing: 8) {
                Button { Task { await vm.toggleMark() } } label: {
                    Label("标难点", systemImage: "flag").font(.system(size: 13))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }.buttonStyle(.bordered)
                Button { vm.nextMark() } label: {
                    Label("下一处", systemImage: "arrow.right.to.line").font(.system(size: 13))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }.buttonStyle(.bordered).disabled(vm.marks.isEmpty)
                Button { vm.zoomToSelection() } label: {
                    Label("放满", systemImage: "arrow.left.and.right").font(.system(size: 13))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }.buttonStyle(.bordered).disabled(vm.selection == nil)
                Button { vm.setSelection(a: nil, b: nil, play: false); vm.zoomAll() } label: {
                    Label("整句", systemImage: "rectangle.expand.vertical").font(.system(size: 13))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
        .background(.bar)
    }

    private func step(_ d: Int) {
        let i = max(0, min(store.items.count - 1, store.index + d))
        guard i != store.index else { return }
        store.index = i
        graded = nil
        showText = true
    }
    private func fmt(_ t: Double) -> String {
        String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

/// 会换行的横向排列（小句块用）。SwiftUI 到 iOS 16 才有 Layout 协议，这里自己实现一个。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
