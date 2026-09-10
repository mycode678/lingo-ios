import SwiftUI

/// 训练首页 —— 七个练法摆在这儿，外加一个"今天练十分钟"的现成组合。
///
/// 为什么单独一屏而不是塞进精听台：精听台是"抠一句"的地方（波形、选区、跟读），
/// 训练是"过一批"的地方（出题、答题、判卷）。两种节奏，混在一起谁都用不顺手。
///
/// 布局按用户定的原则来：**最高频的动作在最下面**（拇指够得着），
/// 每个练法都是图标＋名字＋一句"治什么"，不让人猜。
struct TrainHomeScreen: View {
    @EnvironmentObject var nav: Nav
    @StateObject private var svc = TrainService.shared
    @State private var running: TrainMode?
    /// 走「今日训练」时记到第几步了；单项练习时是 nil。
    /// 一轮练完自动接上下一步 —— 用户不该练完一步还得回来自己点下一个。
    @State private var planStep: Int?
    @State private var stat = TrainService.Stat(done: 0, right: 0, total: 0)
    @State private var showTutorial = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: T.s3) {
                    todayCard
                    tutorialCard
                    Text("单项练习")
                        .font(.system(size: T.f2, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, T.s2)
                    ForEach(TrainMode.allCases) { m in
                        modeRow(m)
                    }
                    footer
                }
                .padding(T.side)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("训练")
            .fullScreenCover(item: $running) { m in
                TrainSessionScreen(mode: m) { finishOne() }
            }
            .sheet(isPresented: $showTutorial) {
                TutorialScreen { showTutorial = false }
            }
            .onAppear {
                refresh()
                // 云端截图用：-mode blank 直接把那个练法打开
                if let m = Demo.trainMode, running == nil { running = m }
            }
        }
    }

    // MARK: 今日训练

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日训练").font(.system(size: T.f4, weight: .semibold))
                Spacer()
                Text("约 10 分钟").font(.system(size: T.f1)).foregroundStyle(.secondary)
            }
            // 三步走：先"听得见"，再"听得懂结构"，最后"说得出"
            VStack(spacing: T.s2) {
                ForEach(Array(TrainService.dailyPlan.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: T.s3) {
                        Text("\(i + 1)")
                            .font(.system(size: T.f2, weight: .bold)).monospacedDigit()
                            .frame(width: 22, height: 22)
                            .background(Color.accentColor.opacity(0.14))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Circle())
                        Text(step.mode.title).font(.system(size: T.f3))
                        Spacer(minLength: 0)
                        Text("\(step.count) 句 · \(step.minutes) 分钟")
                            .font(.system(size: T.f1)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if stat.done > 0 {
                Text("今天已练 \(stat.done) 题，答对 \(stat.right)/\(stat.total)")
                    .font(.system(size: T.f1)).foregroundStyle(.secondary).monospacedDigit()
            }
            Button {
                planStep = 0
                running = TrainService.dailyPlan.first?.mode
            } label: {
                Text("开始今日训练").frame(maxWidth: .infinity, minHeight: T.hBig)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("train.start")
        }
        .padding(T.s4)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    /// 教程入口。放在练法前面是有道理的：
    /// 用户说过"这个认知是所有学习精听的基础"——不明白母语者怎么说话，
    /// 练法只是机械做题。
    private var tutorialCard: some View {
        Button { showTutorial = true } label: {
            HStack(spacing: T.s3) {
                Image(systemName: "book.fill").font(.system(size: T.f4))
                    .frame(width: 40, height: 40)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("听懂英语这件事（8 课）")
                        .font(.system(size: T.f3, weight: .medium))
                    Text("母语者到底怎么说话、你为什么听不懂——带真音频例子和配套练习")
                        .font(.system(size: T.f1)).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: T.f1))
                    .foregroundStyle(.tertiary)
            }
            .padding(T.s3).frame(maxWidth: .infinity).cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("train.tutorial")
    }

    // MARK: 单个练法

    private func modeRow(_ m: TrainMode) -> some View {
        Button { planStep = nil; running = m } label: {
            HStack(spacing: T.s3) {
                Image(systemName: m.icon)
                    .font(.system(size: T.f4))
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.system(size: T.f3, weight: .medium))
                    Text(m.cure).font(.system(size: T.f1)).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: T.f1)).foregroundStyle(.tertiary)
            }
            .padding(T.s3)
            .frame(maxWidth: .infinity)
            .cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("train.mode." + m.rawValue)
    }

    private var footer: some View {
        Text("题目只从「绝大部分人够得着」的句子里出：不超过 18 个词，"
             + "九成以上是常用词。听不懂不是你的错，是材料没分级。")
            .font(.system(size: T.f1)).foregroundStyle(.secondary)
            .padding(.top, T.s2).padding(.horizontal, T.s2)
    }

    private func refresh() { stat = svc.today() }

    /// 一轮练完：在「今日训练」里就自动进下一步，练完三步才收工
    private func finishOne() {
        refresh()
        guard let step = planStep, step + 1 < TrainService.dailyPlan.count else {
            planStep = nil; running = nil; return
        }
        planStep = step + 1
        // 上一层浮层还在收，这时候直接换 item，SwiftUI 会把新的那次"吃掉"
        // （表现是：第一步练完就回到首页，第二步压根不出来）。等它收完再开。
        let next = TrainService.dailyPlan[step + 1].mode
        running = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            running = next
        }
    }
}
