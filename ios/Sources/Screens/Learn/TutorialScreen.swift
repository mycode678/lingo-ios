import SwiftUI

/// 教程：八课，理论 + 真音频例子 + 配套练习。
///
/// 三个设计取舍：
/// ① **例子用用户自己装的材料**，不预录假音频 —— 讲"the 只有 60 毫秒"的时候，
///    放的是他手机里真有的那一句，点一下就听见，理论立刻落地。
/// ② **每课末尾直接能开练**，不是"读完了自己去找练习"。
/// ③ 一课只讲一件事，标题就是结论。用户要的是"重点突出、逻辑清晰、简明实用"。
struct TutorialScreen: View {
    @State private var open: String?
    var onClose: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: T.s3) {
                    intro
                    ForEach(Tutorial.lessons) { l in
                        NavigationLink { LessonScreen(lesson: l) } label: { row(l) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tutorial." + l.id)
                    }
                }
                .padding(T.side)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("听懂英语这件事")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭", action: onClose) }
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Text("先把道理搞明白，再练").font(.system(size: T.f4, weight: .semibold))
            Text("八课，每课两三分钟。讲的是母语者到底怎么说话、"
                 + "中国人听不懂和说不像的原因在哪儿。\n"
                 + "每一课都有真音频例子（点了就播），末尾直接能开练。")
                .font(.system(size: T.f2)).foregroundStyle(.secondary)
        }
        .padding(T.s4).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    private func row(_ l: Tutorial.Lesson) -> some View {
        HStack(spacing: T.s3) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l.title).font(.system(size: T.f3, weight: .medium))
                    .multilineTextAlignment(.leading)
                Text(l.oneLine).font(.system(size: T.f1)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: T.f1)).foregroundStyle(.tertiary)
        }
        .padding(T.s3).frame(maxWidth: .infinity).cardStyle()
    }
}

/// 一课
struct LessonScreen: View {
    let lesson: Tutorial.Lesson
    @StateObject private var svc = TutorialService.shared
    @State private var practicing: TrainMode?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.s4) {
                Text(lesson.oneLine)
                    .font(.system(size: T.f3, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                ForEach(lesson.blocks.indices, id: \.self) { i in
                    block(lesson.blocks[i])
                }
            }
            .padding(T.side)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $practicing) { m in
            TrainSessionScreen(mode: m) { practicing = nil }
        }
        .onDisappear { svc.stop() }
    }

    @ViewBuilder private func block(_ b: Tutorial.Block) -> some View {
        switch b {
        case .text(let s):
            RichText(s).font(.system(size: T.f3))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .key(let s):
            HStack(alignment: .top, spacing: T.s3) {
                Image(systemName: "lightbulb.fill").foregroundStyle(.orange)
                RichText(s).font(.system(size: T.f3, weight: .medium))
            }
            .padding(T.s3).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: T.card, style: .continuous))

        case .compare(let cn, let native):
            VStack(alignment: .leading, spacing: T.s2) {
                Label(cn, systemImage: "xmark.circle.fill")
                    .font(.system(size: T.f2)).foregroundStyle(T.Score.bad)
                Label(native, systemImage: "checkmark.circle.fill")
                    .font(.system(size: T.f2)).foregroundStyle(T.Score.good)
            }
            .padding(T.s3).frame(maxWidth: .infinity, alignment: .leading).cardStyle()

        case .example(let phrase, let why):
            ExampleCard(phrase: phrase, why: why)

        case .practice(let mode, let why):
            Button { practicing = mode } label: {
                HStack(spacing: T.s3) {
                    Image(systemName: mode.icon).font(.system(size: T.f4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("练一下：\(mode.title)")
                            .font(.system(size: T.f3, weight: .medium))
                        Text(why).font(.system(size: T.f1)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(T.s3).frame(maxWidth: .infinity)
                .background(Color.accentColor.opacity(0.12))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: T.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lesson.practice")
        }
    }
}

/// 真音频例子。找不到合适的句子就只显示文字 ——
/// 不能因为"用户还没装材料"就让整课打不开。
struct ExampleCard: View {
    let phrase: String
    let why: String
    @StateObject private var svc = TutorialService.shared
    @State private var found: TrainService.Item?
    @State private var missing = false

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Label("例子", systemImage: "waveform").font(.system(size: T.f1))
                .foregroundStyle(.secondary)
            if let it = found {
                // 命中的那几个词标出来 —— 光放音频，用户不知道该听哪儿
                RichText(highlight(it.en)).font(.system(size: T.f3))
                Text(why).font(.system(size: T.f1)).foregroundStyle(.secondary)
                HStack(spacing: T.s2) {
                    Button { svc.play(it) } label: {
                        Label("播放整句", systemImage: "play.fill")
                            .frame(minHeight: T.hCtl).padding(.horizontal, T.s3)
                    }
                    .buttonStyle(.bordered)
                    Button { svc.playPhrase(it, phrase) } label: {
                        Label("只听「\(phrase)」", systemImage: "scope")
                            .frame(minHeight: T.hCtl).padding(.horizontal, T.s3)
                    }
                    .buttonStyle(.bordered)
                }
            } else if missing {
                Text("这一条要用你装的材料举例。去「材料」里装一个包，回来就有真音频了。")
                    .font(.system(size: T.f2)).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(T.s3).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
        .task {
            found = svc.find(phrase)
            missing = found == nil
        }
    }

    private func highlight(_ s: String) -> String {
        guard let r = s.range(of: phrase, options: .caseInsensitive) else { return s }
        return s.replacingCharacters(in: r, with: "**" + String(s[r]) + "**")
    }
}

/// 极简的 `**加粗**` 渲染。
/// 用 SwiftUI 自带的 Markdown（`AttributedString(markdown:)`）就够了，
/// 不引第三方；解析不了时原样显示，绝不因为一个星号让整课空白。
struct RichText: View {
    let raw: String
    init(_ raw: String) { self.raw = raw }
    var body: some View {
        if let a = try? AttributedString(markdown: raw,
                                         options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(a)
        } else {
            Text(raw)
        }
    }
}
