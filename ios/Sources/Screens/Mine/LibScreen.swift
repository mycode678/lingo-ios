import SwiftUI

/// 我的库：学了多少、每个词练到什么程度；顺带放设置（服务器地址、离线缓存）。
struct LibScreen: View {
    @EnvironmentObject var store: Store
    @State private var lib: Api.LibResp?
    @State private var loading = true
    @State private var cacheMB = 0.0
    @State private var heat: [Int: Int] = [:]
    @State private var showSettings = false
    @State private var packs: [CatalogService.Pack] = []
    @State private var showMember = false
    @State private var showPoster = false
    @State private var streak = 0
    @State private var trained = 0
    @StateObject private var ent = EntitlementService.shared

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
                // 会员 + 奖励。**这是 App 里唯一一处常驻的会员入口** ——
                // 用户批评过别家"不断的弹购买会员窗口"，所以不做定时弹窗。
                Section {
                    Button { showMember = true } label: {
                        HStack {
                            Label(ent.tier.paid ? "\(ent.tier.name)会员" : "免费用户",
                                  systemImage: ent.tier.paid ? "crown.fill" : "person")
                            Spacer()
                            if let left = ent.remaining(.sentenceDaily) {
                                Text("今天还剩 \(left) 句").font(.system(size: T.f1))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Image(systemName: "chevron.right").font(.system(size: T.f1))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("lib.member")
                    Button { showPoster = true } label: {
                        Label("生成成绩海报", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("lib.poster")
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
                Section {
                    if packs.isEmpty {
                        Text("还没装材料包。装了包就能完全离线练 —— 句子、译文、"
                             + "词边界都在包里，一次网都不用联。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    ForEach(packs, id: \.id) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(.system(size: 16, weight: .medium))
                                Text("\(p.sentences) 句" + (p.restricted ? "　·　受限" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("删除", role: .destructive) {
                                CatalogService.shared.remove(p.id)
                                packs = CatalogService.shared.packs()
                            }
                            .buttonStyle(.borderless).font(.caption)
                        }
                    }
                } header: { Text("材料包") } footer: {
                    Text("删包只删材料，练习进度、收藏、难点、录音一条都不会丢 —— "
                         + "它们记的是句子编号，包装回来还在。")
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
            .sheet(isPresented: $showMember) { MemberScreen { showMember = false } }
            .sheet(isPresented: $showPoster) {
                PosterScreen(streak: streak,
                             totalSentences: PracticeService.shared.practicedCount(),
                             todayDone: PracticeService.shared.todayCount(),
                             avgScore: nil,
                             badges: RewardService.shared.badges(
                                streak: streak, total: PracticeService.shared.practicedCount()),
                             onClose: { showPoster = false })
            }
            .refreshable { await load() }
            .task { await load(); await refreshCache(); packs = CatalogService.shared.packs() }
        }
    }

    private func stat(_ k: String, _ v: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(v)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(k).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
    }

    private func load() async {
        loading = true
        // 热力图和连续天数改成本机算（`day` 表）——
        // 以前找服务器要，断网这一屏就一片 0，看着像"你从没练过"。
        let p = PracticeService.shared
        heat = p.heat()
        streak = p.streak()
        trained = TrainService.shared.today().done
        ent.reload()
        // 词表还从服务器取（那是查词功能的一部分，本来就要联网）；取不到就空着。
        lib = try? await Api.lib()
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
    @AppStorage("ui.entryFont") private var entryFont = 18.0
    @AppStorage("ui.listFont") private var listFont = 15.0
    @AppStorage("ui.sentFont") private var sentFont = 21.0
    @AppStorage("ui.accent") private var accent = "#2f6fd0"
    @AppStorage("ui.scheme") private var scheme = "system"
    @AppStorage("owner.key") private var ownerKey = ""
    @AppStorage("ai.provider") private var aiProvider = "deepseek"
    @AppStorage("ai.key") private var aiKey = ""
    private var aiLeft: Int { CoachService.shared.remainingToday() }

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
                                let who = try? await Api.whoami()
                                result = "连上了：\(c.words) 个词 / \(c.cards) 句"
                                    + (who.map { "　·　当前账号 \($0.u)" } ?? "")
                            } catch {
                                result = "连不上：\(error.localizedDescription)"
                            }
                            testing = false
                        }
                    }
                    if let r = result { Text(r).font(.caption).foregroundStyle(.secondary) }
                    TextField("账号（必填，局域网也要）", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码（必填）", text: $pass)
                } header: {
                    Text("服务器")
                } footer: {
                    Text("家里用局域网地址；在外面填 Cloudflare 隧道的域名。\n"
                         + "账号密码是必填的，局域网也一样。收藏、进度、难点、录音都跟着账号走 —— "
                         + "换个账号登录就是另一套库。密码在电脑网页版的「我的库 → 账号」里改。")
                }

                Section {
                    fontRow("词典正文", $entryFont, 14...30)
                    fontRow("例句清单", $listFont, 13...26)
                    fontRow("精听台句子", $sentFont, 16...32)
                } header: { Text("字号") } footer: {
                    Text("拖动就能看到下面的示例跟着变，调到看着舒服为止。")
                }

                Section {
                    Picker("服务商", selection: $aiProvider) {
                        Text("DeepSeek").tag("deepseek")
                        Text("OpenRouter").tag("openrouter")
                    }
                    .pickerStyle(.segmented)
                    SecureField("API key", text: $aiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("AI 拆解") } footer: {
                    Text("填了才能用 AI 拆解跟读结果。key 只存在这台手机上。\n"
                         + "发给 AI 的只有「哪个词、原声多长、你多长、该连没连」这些数字 —— "
                         + "录音本身永远不出这台手机。\n"
                         + "免费额度每天 \(CoachService.freeDaily) 句，今天还剩 \(aiLeft) 句。")
                }

                Section {
                    // 版权受限的材料包（朗文那批）只有填了这个口令才装得上。
                    // 方案原话：「词典例句不开……当然我自己要可以用」。
                    // 真正的防线是那种包根本不往 CDN 上放，这里是第二道，
                    // 而且判断在 Service 入口，不是界面藏起来。
                    SecureField("材料口令（要装朗文的包就得填）", text: $ownerKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("受限材料") } footer: {
                    Text(ownerKey.isEmpty ? "留空就是普通用户：带版权标记的材料包装不上。"
                                          : "已填。带版权标记的材料包可以装。")
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
