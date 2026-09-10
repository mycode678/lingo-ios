import SwiftUI

/// 今日 —— 新的首页。
///
/// 解决两件事：
/// ① 新用户打开 App 不知道干什么（以前是一片空白，词典还锁着）
/// ② 老用户每天打开要先想"今天练啥"（以前得自己去翻）
///
/// 一进来就三件事摆在眼前：今天练了多少、接下来练什么、再练多少能领奖励。
struct TodayScreen: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @State private var showReview = false
    @State private var dueN = 0
    @State private var freshN = 0
    @State private var streak = 0
    @State private var todayDone = 0
    @State private var trained = 0
    @State private var justRewarded = 0
    @AppStorage("today.goal") private var goal = 50

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: T.s3) {
                    progressCard
                    tasks
                    rewardHint
                }
                .padding(T.side)
            }
            .navigationTitle("今天")
            .background(Color(.systemGroupedBackground))
            // ReviewScreen 自带 NavigationStack，这里别再套一层
            .fullScreenCover(isPresented: $showReview) {
                ReviewScreen(onClose: { showReview = false })
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: 进度卡

    private var progressCard: some View {
        VStack(spacing: T.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(todayDone)")
                    .font(.system(size: T.f6, weight: .bold)).monospacedDigit()
                Text("/ \(goal) 句").font(.system(size: T.f3)).foregroundStyle(.secondary)
                Spacer()
                if streak > 0 {
                    Label("\(streak) 天", systemImage: "flame.fill")
                        .font(.system(size: T.f2, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            ProgressView(value: Double(min(todayDone, goal)), total: Double(goal))
                .tint(todayDone >= goal ? T.Score.good : Color.accentColor)
            if todayDone >= goal {
                Text("今天的目标完成了 🎉").font(.system(size: T.f2)).foregroundStyle(T.Score.good)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(T.s4)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    // MARK: 今天练什么

    @ViewBuilder private var tasks: some View {
        VStack(spacing: T.s2) {
            if dueN == 0 && freshN == 0 && trained == 0 {
                emptyGuide
            } else {
                // 「训练」排在最前面：这是这个 App 跟别家不一样的地方，
                // 也是每天最该先做的事（先听得见，再抠细节）。
                task("分级听力训练", "七个练法", "figure.run",
                     "从你够得着的句子里出题，不拿听不懂的材料硬灌") { nav.tab = 3 }
                if dueN > 0 {
                    task("该复习了", "\(dueN) 句", "arrow.triangle.2.circlepath",
                         "记忆曲线到点了，趁还记得赶紧过一遍") { showReview = true }
                }
                if freshN > 0 {
                    task("没练过的", "\(freshN) 句", "waveform",
                         "圈出听不懂的半秒，反复听到听清") { nav.tab = 2 }
                }
                task("跟读打分", "随时", "mic",
                     "念一遍，看看哪个词跟母语者差得最远") { nav.tab = 2 }
            }
        }
    }

    private var emptyGuide: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text("先挑点材料").font(.system(size: T.f4, weight: .semibold))
            Text("去「材料」里选一篇合你水平的，或者导入你自己的音频。\n"
                 + "选好之后，这里就会告诉你今天该练什么。")
                .font(.system(size: T.f2)).foregroundStyle(.secondary)
            Button { nav.tab = 1 } label: {
                Text("去挑材料").frame(maxWidth: .infinity, minHeight: T.hBig)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(T.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func task(_ title: String, _ badge: String, _ icon: String,
                      _ desc: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: T.s3) {
                Image(systemName: icon)
                    .font(.system(size: T.f4))
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: T.s1) {
                        Text(title).font(.system(size: T.f3, weight: .medium))
                        Text(badge).font(.system(size: T.f1)).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(desc).font(.system(size: T.f1)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: T.f1))
                    .foregroundStyle(.tertiary)
            }
            .padding(T.s3)
            .frame(maxWidth: .infinity)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    // MARK: 今天还差多少

    // 原来这儿写的是"再练 N 句就能领今日奖励"——可发奖那套（D4）一行代码都还没有，
    // 练满了什么也不会发生。对用户许了愿不兑现，比不说更糟。
    // 先改成只说进度，等 D4 做完再把"奖励"两个字加回来。
    @ViewBuilder private var rewardHint: some View {
        if justRewarded > 0 {
            HStack(spacing: T.s2) {
                Image(systemName: "gift.fill").foregroundStyle(T.Score.good)
                Text("今天练满了，多送你 \(justRewarded) 句解锁额度")
                    .font(.system(size: T.f2)).foregroundStyle(T.Score.good)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, T.s2)
        } else if todayDone < goal {
            HStack(spacing: T.s2) {
                Image(systemName: "target").foregroundStyle(.orange)
                Text("离今天的目标还差 \(goal - todayDone) 句")
                    .font(.system(size: T.f2)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, T.s2)
        }
    }

    /// 全部本机算 —— 断网、飞行模式下这一屏的数字照样是对的。
    /// （以前这里是 `Api.counts()` + `Api.heat()`，服务器一挂就显示"你一天都没练过"。）
    private func load() async {
        let p = PracticeService.shared
        dueN = p.dueCount()
        todayDone = p.todayCount()
        streak = p.streak()
        trained = TrainService.shared.today().done
        // 「没练过的」= 装了的材料包里还没碰过的句子
        let packs = CatalogService.shared.packs()
        freshN = max(0, packs.reduce(0) { $0 + $1.sentences } - p.practicedCount())
        // 练够了就把今天的奖励发掉。**许了愿就得兑现** ——
        // 这行字在 D4 之前挂过一次而没有发奖那套，等于对用户放空话。
        justRewarded = RewardService.shared.settleToday(done: todayDone, streak: streak)
    }
}
