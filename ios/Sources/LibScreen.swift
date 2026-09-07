import SwiftUI

/// 我的库：学了多少、每个词练到什么程度；顺带放设置（服务器地址、离线缓存）。
struct LibScreen: View {
    @EnvironmentObject var store: Store
    @State private var lib: Api.LibResp?
    @State private var loading = true
    @State private var cacheMB = 0.0
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
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("https://192.168.8.191:8445", text: $base)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button(testing ? "连接中…" : "保存并测试") {
                        Api.base = base.trimmingCharacters(in: .whitespaces)
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
                } footer: {
                    Text("家里用局域网地址；在外面填 Cloudflare 隧道的域名。\n"
                         + "服务器开了 Basic Auth，外网访问会让你输一次账号密码。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }
}
