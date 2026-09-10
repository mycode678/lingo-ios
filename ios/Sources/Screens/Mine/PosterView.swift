import SwiftUI

/// 成绩海报 —— 用户要的"美美的截图"，能直接发微信/朋友圈/QQ/小红书/微博。
///
/// > 分享那个很有必要，是扩大用户量的最佳路径……
/// > 既满足了用户炫耀的情绪需求、又扩展了潜在用户，是个很好的闭环
///
/// 三条讲究：
/// ① **数字是真的**。连了几天、练了多少句、跟读平均多少分，全是本机库里的实数，
///    一个字不编（"你超过了 92% 的用户"这种我们没有数据，编了就是骗人）。
/// ② **App 信息要在**，不然分享出去没人知道这是什么 —— 但只占底部一条，
///    不能喧宾夺主，广告味太重用户就不发了。
/// ③ 用 `ImageRenderer` 出图，`scale = 3`：发到微信被压过一次之后还得清楚。
struct Poster: View {
    var streak: Int
    var totalSentences: Int
    var todayDone: Int
    var avgScore: Int?
    var badges: [RewardService.Badge]

    /// 分享尺寸：竖版 3:4，朋友圈和小红书都不会被裁掉重点
    static let size = CGSize(width: 750, height: 1000)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.16, blue: 0.31),
                                    Color(red: 0.16, green: 0.32, blue: 0.52)],
                           startPoint: .top, endPoint: .bottom)
            // 波形是这个 App 的视觉符号，压在底纹上做背景
            WavePattern().stroke(Color.white.opacity(0.10), lineWidth: 3)
                .frame(height: 260).offset(y: 150)

            VStack(spacing: 0) {
                Text("我的精听成绩")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 74)

                Text("\(streak)")
                    .font(.system(size: 170, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("天没断过")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.8))

                HStack(spacing: 26) {
                    stat("累计", "\(totalSentences)", "句")
                    stat("今天", "\(todayDone)", "句")
                    if let a = avgScore { stat("跟读", "\(a)", "分") }
                }
                .padding(.top, 46)

                let got = badges.filter(\.got)
                if !got.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(got.prefix(4)) { b in
                            VStack(spacing: 6) {
                                Image(systemName: b.icon).font(.system(size: 30))
                                Text(b.name).font(.system(size: 19))
                            }
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 138, height: 100)
                            .background(.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                    .padding(.top, 44)
                }

                Spacer(minLength: 0)

                VStack(spacing: 8) {
                    Text("听说训练台")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                    Text("把听不懂的那半秒，抠到听得懂")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.bottom, 64)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func stat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 21)).foregroundStyle(.white.opacity(0.6))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 21))
            }
            .foregroundStyle(.white)
        }
    }

    /// 一段起伏的波形底纹（画出来的，不放图片资源）
    private struct WavePattern: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            let n = 46
            let w = r.width / CGFloat(n)
            for i in 0..<n {
                let x = r.minX + CGFloat(i) * w + w / 2
                // 固定的伪随机高度：每次画出来都一样，海报不会忽高忽低
                let k = CGFloat((i * 37 % 17)) / 17
                let h = r.height * (0.15 + 0.85 * k)
                p.move(to: CGPoint(x: x, y: r.midY - h / 2))
                p.addLine(to: CGPoint(x: x, y: r.midY + h / 2))
            }
            return p
        }
    }
}

/// 海报那一屏：预览 + 分享。分享走系统面板 ——
/// 微信、QQ、小红书、微博只要装了就在里面，**不用接任何一家的 SDK**
/// （接了就要带三个闭源库、要它们的隐私清单，审核和体积都是代价）。
struct PosterScreen: View {
    var streak: Int
    var totalSentences: Int
    var todayDone: Int
    var avgScore: Int?
    var badges: [RewardService.Badge]
    var onClose: () -> Void

    @State private var image: Image?
    @State private var file: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: T.s4) {
                    (image ?? Image(systemName: "photo"))
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: T.card, style: .continuous))
                        .accessibilityIdentifier("poster.image")
                    Text("数字都是你自己的真实记录，没有一个是编的。")
                        .font(.system(size: T.f1)).foregroundStyle(.secondary)
                }
                .padding(T.side)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("成绩海报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭", action: onClose) }
            }
            .safeAreaInset(edge: .bottom) {
                if let file {
                    ShareLink(item: file) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: T.hBig)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(T.side)
                    .accessibilityIdentifier("poster.share")
                }
            }
            .task { render() }
        }
    }

    @MainActor private func render() {
        let r = ImageRenderer(content: Poster(streak: streak, totalSentences: totalSentences,
                                              todayDone: todayDone, avgScore: avgScore,
                                              badges: badges))
        r.scale = 3                      // 发到微信会被压一次，2 倍出来边缘发糊
        guard let ui = r.uiImage else { return }
        image = Image(uiImage: ui)
        // 分享要给**文件**不是 UIImage：给 UIImage 时部分 App 只收到一张没有名字的图，
        // 存到相册里叫 "IMG_xxxx"；给 png 文件名字是我们定的，落地更体面。
        if let data = ui.pngData() {
            let u = FileManager.default.temporaryDirectory
                .appendingPathComponent("听说训练台-成绩.png")
            try? data.write(to: u)
            file = u
        }
    }
}
