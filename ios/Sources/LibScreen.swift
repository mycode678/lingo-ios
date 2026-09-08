import SwiftUI

/// 我的库：学了多少、每个词练到什么程度；顺带放设置（服务器地址、离线缓存）。
struct LibScreen: View {
    @EnvironmentObject var store: Store
    @State private var lib: Api.LibResp?
    @State private var loading = true
    @State private var cacheMB = 0.0
    @State private var heat: [Int: Int] = [:]
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if let c = lib?.counts {
                    Section {
                        LazyVGrid(columns: [.init(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                            stat("词", c.words); stat("句子", c.cards)
                            stat("今天该复习", c.due); stat("没练过", c.fresh)
                            stat("已经熟了", c.fine); stat("收藏", c.fav)
                            stat("今天练了", c.today); stat("录音", c.recs)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("学习中的词") {
                    if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                    ForEach(lib?.words ?? []) { w in
                        Button { Task { await store.look(w.w) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(w.w).font(.system(size: 16, weight: .medium))
                                    Text("\(w.n) 句　熟 \(w.fine)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if w.due > 0 {
                                    Text("\(w.due) 到期").font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.red.opacity(0.15))
                                        .foregroundStyle(.red).clipShape(Capsule())
                                }
                                ProgressView(value: Double(w.fine), total: Double(max(1, w.n)))
                                    .frame(width: 60)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("最近 30 天") {
                    HeatStrip(days: heat)
                        .frame(height: 34)
                        .padding(.vertical, 2)
                }
                Section("离线") {
                    HStack {
                        Text("已缓存音频")
                        Spacer()
                        Text(String(format: "%.1f MB", cacheMB)).foregroundStyle(.secondary)
                    }
                    Button("把当前这个词的例句下到手机") {
                        Task {
                            await Cache.shared.prefetch(store.items.map(\.src))
                            await refreshCache()
                        }
                    }
                    .disabled(store.items.isEmpty)
                    Button("清空缓存", role: .destructive) {
                        Task { await Cache.shared.clear(); await refreshCache() }
                    }
                }
            }
            .navigationTitle("我的库")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsScreen() }
            .refreshable { await load() }
            .task { await load(); await refreshCache() }
        }
    }

    private func stat(_ k: String, _ v: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(v)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(k).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func load() async {
        loading = true
        lib = try? await Api.lib()
        heat = (try? await Api.heat()) ?? [:]
        loading = false
        await store.loadDueCount()
    }
    private func refreshCache() async {
        cacheMB = Double(await Cache.shared.size()) / 1_048_576
    }
}

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var base = Api.base
    @State private var user = Api.user
    @State private var pass = Api.pass
    @State private var testing = false
    @State private var result: String?
    @AppStorage("ui.entryFont") private var entryFont = 17.0
    @AppStorage("ui.listFont") private var listFont = 15.0
    @AppStorage("ui.sentFont") private var sentFont = 21.0
    @AppStorage("ui.accent") private var accent = "#2f6fd0"
    @AppStorage("ui.scheme") private var scheme = "system"

    private let accents: [(String, String)] = [
        ("#2f6fd0", "蓝"), ("#105f6e", "墨绿"), ("#c0392b", "砖红"),
        ("#7a5510", "琥珀"), ("#5b3fa8", "紫"), ("#1f9d55", "绿")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://192.168.8.191:8445", text: $base)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button(testing ? "连接中…" : "保存并测试") {
                        Api.base = base.trimmingCharacters(in: .whitespaces)
                        Api.user = user.trimmingCharacters(in: .whitespaces)
                        Api.pass = pass
                        testing = true
                        Task {
                            do {
                                let c = try await Api.counts()
                                result = "连上了：\(c.words) 个词 / \(c.cards) 句"
                            } catch {
                                result = "连不上：\(error.localizedDescription)"
                            }
                            testing = false
                        }
                    }
                    if let r = result { Text(r).font(.caption).foregroundStyle(.secondary) }
                    TextField("账号（局域网留空）", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $pass)
                } header: {
                    Text("服务器")
                } footer: {
                    Text("家里用局域网地址；在外面填 Cloudflare 隧道的域名。\n"
                         + "服务器开了 Basic Auth，外网访问会让你输一次账号密码。")
                }

                Section {
                    fontRow("词典正文", $entryFont, 13...26)
                    fontRow("例句清单", $listFont, 12...22)
                    fontRow("精听台句子", $sentFont, 16...32)
                } header: { Text("字号") } footer: {
                    Text("拖动就能看到下面的示例跟着变，调到看着舒服为止。")
                }

                Section {
                    LazyVGrid(columns: [.init(.adaptive(minimum: 56), spacing: 12)], spacing: 12) {
                        ForEach(accents, id: \.0) { hex, name in
                            Button { accent = hex } label: {
                                VStack(spacing: 5) {
                                    Circle().fill(Color(hex: hex)).frame(width: 32, height: 32)
                                        .overlay(
                                            Circle().stroke(Color.primary.opacity(accent == hex ? 0.85 : 0),
                                                            lineWidth: 2).padding(-3))
                                    Text(name).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    Picker("深浅", selection: $scheme) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                } header: { Text("外观") }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }

    /// 一行字号：滑块 + 当前值 + 一句用这个字号写的示例，边拖边看
    private func fontRow(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(v.wrappedValue))").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: v, in: range, step: 1)
            Text("Excuse me, can you tell me the way…")
                .font(.system(size: v.wrappedValue))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

extension Color {
    init(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let n = UInt64(h, radix: 16) ?? 0x2f6fd0
        self.init(.sRGB,
                  red: Double((n >> 16) & 0xff) / 255,
                  green: Double((n >> 8) & 0xff) / 255,
                  blue: Double(n & 0xff) / 255)
    }
}


/// 30 天练习热力图：越绿练得越多，一眼看出有没有断更
struct HeatStrip: View {
    var days: [Int: Int]
    var body: some View {
        let today = Int(Date().timeIntervalSince1970 / 86400)
        let maxN = max(1, days.values.max() ?? 1)
        HStack(spacing: 3) {
            ForEach((0..<30).reversed(), id: \.self) { back in
                let d = today - back
                let n = days[d] ?? 0
                RoundedRectangle(cornerRadius: 3)
                    .fill(n == 0 ? Color(.tertiarySystemFill)
                                 : Color.green.opacity(0.25 + 0.75 * Double(n) / Double(maxN)))
                    .frame(maxWidth: .infinity)
                    .help("\(n) 次")
            }
        }
    }
}
