import SwiftUI

/// 文字样式：字体、字号、颜色。精听台和复习页共用同一套设置 ——
/// 两边各存一份迟早不一致，而且用户也不会理解"为什么复习页字又小了"。
enum TX {
    static func face(_ name: String, _ size: Double) -> Font {
        switch name {
        case "rounded": return .system(size: size, design: .rounded)
        case "serif":   return .system(size: size, design: .serif)
        case "mono":    return .system(size: size, design: .monospaced)
        default:        return .system(size: size)
        }
    }
    static func color(_ hex: String) -> Color? { hex.isEmpty ? nil : Color(hex: hex) }
}

/// 原文/译文样式面板。哪一屏打开的都一样，改完两边一起变。
struct StyleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ui.sentFont") private var sentFont = 21.0
    @AppStorage("ui.sentFace") private var sentFace = "system"
    @AppStorage("ui.sentColor") private var sentColor = ""
    @AppStorage("ui.cnFont") private var cnFont = 16.0
    @AppStorage("ui.cnFace") private var cnFace = "system"
    @AppStorage("ui.cnColor") private var cnColor = ""
    @AppStorage("ui.cardBg") private var cardBg = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("预览") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Excuse me, can you tell me the way to the museum please?")
                            .font(TX.face(sentFace, sentFont))
                            .foregroundStyle(TX.color(sentColor) ?? Color.primary)
                        Text("劳驾，请问去博物馆怎么走？")
                            .font(TX.face(cnFace, cnFont))
                            .foregroundStyle(TX.color(cnColor) ?? Color.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TX.color(cardBg) ?? Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Section("原文") {
                    Picker("字体", selection: $sentFace) { faceOptions }
                    sizeRow("字号", $sentFont, 14...48)
                    colorRow("颜色", $sentColor)
                }
                Section("译文") {
                    Picker("字体", selection: $cnFace) { faceOptions }
                    sizeRow("字号", $cnFont, 11...40)
                    colorRow("颜色", $cnColor)
                }
                Section("卡片底色") { colorRow("底色", $cardBg) }
                Section {
                    Button("全部恢复默认") {
                        sentFace = "system"; sentFont = 21; sentColor = ""
                        cnFace = "system"; cnFont = 16; cnColor = ""; cardBg = ""
                    }
                } footer: {
                    Text("精听台和复习页用的是同一套样式。")
                }
            }
            .navigationTitle("原文样式").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() } } }
        }
    }

    @ViewBuilder private var faceOptions: some View {
        Text("系统").tag("system"); Text("圆体").tag("rounded")
        Text("衬线").tag("serif");  Text("等宽").tag("mono")
    }
    private func sizeRow(_ t: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        HStack {
            Text(t)
            Slider(value: v, in: r, step: 1)
            Text("\(Int(v.wrappedValue))").foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }
    private func colorRow(_ t: String, _ hex: Binding<String>) -> some View {
        HStack {
            ColorPicker(t, selection: Binding(
                get: { TX.color(hex.wrappedValue) ?? Color.primary },
                set: { hex.wrappedValue = $0.hexString }))
            if !hex.wrappedValue.isEmpty {
                Button("默认") { hex.wrappedValue = "" }.font(.caption).buttonStyle(.bordered)
            }
        }
    }
}

/// 循环几遍。精听台和复习页共用：长按循环键打开。
struct LoopSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var player: Player
    @AppStorage("drill.times") private var loopTimes = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // 顺序按"几遍"从少到多，无限放最后
                    ForEach([1, 2, 3, 5, 10, 0], id: \.self) { n in
                        Button {
                            loopTimes = n; player.loopTimes = n
                            if !player.loop { player.loop = true; player.play() }
                            dismiss()
                        } label: {
                            HStack {
                                Text(n == 0 ? "无限循环" : (n == 1 ? "只放一遍" : "循环 \(n) 遍"))
                                Spacer()
                                if loopTimes == n {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .foregroundStyle(Color.primary)
                    }
                    Stepper(value: Binding(get: { max(1, loopTimes) },
                                           set: { loopTimes = $0; player.loopTimes = $0 }),
                            in: 1...50) {
                        HStack { Text("自定义"); Spacer()
                            Text("\(max(1, loopTimes)) 遍").foregroundStyle(.secondary).monospacedDigit() }
                    }
                } footer: {
                    Text("循环键长按就到这儿。设了遍数以后，循环键上会显示数字。")
                }
            }
            .navigationTitle("循环几遍").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() } } }
        }
        .presentationDetents([.height(400)])
    }
}


/// 循环键：点一下开关循环，**按住 0.5 秒**弹出"循环几遍"。
///
/// 别把 .onLongPressGesture 挂在 Button 上 —— 按钮自己会吃掉长按，
/// 结果变成"按住再挪一下手指"才触发，谁也猜不到（2026-09-08 就这么翻过车）。
/// 0.5 秒是 iOS 系统级长按的时长，手感跟别的 App 一致。
struct LoopButton: View {
    @ObservedObject var player: Player
    var times: Int
    var onToggle: () -> Void
    var onHold: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "repeat")
            if player.loop && times > 0 {
                Text("\(times)").font(.system(size: 10, weight: .semibold))
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(player.loop ? Color.accentColor : Color.primary.opacity(0.55))
        .frame(width: 44, height: 34)
        .background(player.loop ? Color.accentColor.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 30, perform: onHold)
    }
}
