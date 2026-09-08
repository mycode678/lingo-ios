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
                    ForEach([0, 2, 3, 5, 10], id: \.self) { n in
                        Button {
                            loopTimes = n; player.loopTimes = n
                            if !player.loop { player.loop = true; player.play() }
                            dismiss()
                        } label: {
                            HStack {
                                Text(n == 0 ? "一直循环，直到我停" : "循环 \(n) 遍")
                                Spacer()
                                if loopTimes == n {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .foregroundStyle(Color.primary)
                    }
                    Stepper(value: Binding(get: { max(2, loopTimes) },
                                           set: { loopTimes = $0; player.loopTimes = $0 }),
                            in: 2...50) {
                        HStack { Text("自己定"); Spacer()
                            Text("\(max(2, loopTimes)) 遍").foregroundStyle(.secondary).monospacedDigit() }
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
