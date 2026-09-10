import SwiftUI

/// 材料库：**按身份挑、按难度挑**，点开能预览，决定了再下整包。
///
/// 用户的原话：「根据不同的人士当前的状态提供一个可预览的学习材料列表，
/// 并且材料要分级，有了列表和分级，不用学习者自己花时间精力去搜集材料，
/// 按图索骥，点开列表直接进行按步就班学习就好了。」
struct PackStoreScreen: View {
    @EnvironmentObject var store: Store
    @StateObject private var cat = CatalogService.shared

    @AppStorage("me.who") private var who = ""       // 我是谁：空＝不筛
    @State private var remote: [CatalogService.RemoteItem] = []
    @State private var installed: [CatalogService.Pack] = []
    @State private var busy: String?                  // 正在下哪个包
    @State private var err: String?
    @State private var loading = true
    @State private var preview: CatalogService.RemoteItem?
    @State private var showImport = false
    @State private var showVideo = false

    /// 身份。方案里他列的就是这几类人。
    private let whoList = ["入门", "日常口语", "出国", "雅思", "TED", "VOA"]

    private var shown: [CatalogService.RemoteItem] {
        who.isEmpty ? remote : remote.filter { $0.who.contains(who) }
    }
    private func isOn(_ id: String) -> Bool { installed.contains { $0.id == id } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: T.s2) {
                            chip("全部", on: who.isEmpty) { who = "" }
                            ForEach(whoList, id: \.self) { w in
                                chip(w, on: who == w) { who = w }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: T.side, bottom: 6, trailing: 0))
                    // 自己的材料两条路：导进来（转成材料包）或者跟着视频读。
                    // 放在最上面 —— 预置材料总有练完的一天，这两条是无限的。
                    HStack(spacing: T.s2) {
                        miniCard("导入自己的", "square.and.arrow.down") { showImport = true }
                        miniCard("视频跟读", "play.rectangle") { showVideo = true }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: T.side, bottom: 6, trailing: T.side))
                } header: {
                    Text("你现在在学什么")
                } footer: {
                    Text("挑一个，下面只显示适合你的材料。不确定就选「全部」。")
                }

                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let err {
                    ContentUnavailableView {
                        Label("拿不到材料目录", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(err + "\n已经装好的包在下面，断网也能练。")
                    } actions: {
                        Button("重试") { Task { await load() } }.buttonStyle(.borderedProminent)
                    }
                } else if shown.isEmpty {
                    Text("这一类暂时还没有材料。").foregroundStyle(.secondary)
                }

                ForEach(shown) { it in
                    packRow(it)
                }
            }
            .navigationTitle("材料库")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { DictScreen() } label: { Image(systemName: "character.book.closed") }
                        .accessibilityLabel("查词")
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $preview) { previewSheet($0) }
            .sheet(isPresented: $showVideo) { VideoFollowScreen { showVideo = false } }
            .sheet(isPresented: $showImport) {
                ImportScreen { showImport = false; Task { await load() } }
            }
        }
    }

    private func miniCard(_ t: String, _ icon: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: T.f4))
                Text(t).font(.system(size: T.f2, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color.accentColor.opacity(0.10))
            .foregroundStyle(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: T.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("packs." + icon)
    }

    // MARK: 一行一个包

    @ViewBuilder private func packRow(_ it: CatalogService.RemoteItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.name).font(.system(size: 16, weight: .medium))
                    Text("\(it.sentences) 句　·　\(String(format: "%.1f", Double(it.bytes) / 1e6)) MB"
                         + (it.restricted ? "　·　受限" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isOn(it.id) {
                    Label("已装", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(T.Score.good).labelStyle(.iconOnly)
                        .accessibilityLabel("已装")
                } else if busy == it.id {
                    ProgressView()
                } else {
                    Button("下载") { Task { await get(it) } }
                        .buttonStyle(.bordered).font(.caption)
                        .disabled(busy != nil)
                }
            }
            // 难度条：一眼看出这个包偏难还是偏易
            levelBar(it.levels)
            Button("先看看里面有什么") { preview = it }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(.vertical, 2)
    }

    /// 难度分布做成一条彩带，比写一串数字直观
    private func levelBar(_ levels: [String: Int]) -> some View {
        let total = max(1, levels.values.reduce(0, +))
        return HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { lv in
                let n = levels[String(lv)] ?? 0
                if n > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(levelColor(lv))
                        .frame(width: max(4, CGFloat(n) / CGFloat(total) * 220), height: 5)
                }
            }
            Spacer(minLength: 0)
        }
    }
    private func levelColor(_ lv: Int) -> Color {
        switch lv {
        case 1: return T.Score.good
        case 2: return T.Score.great
        case 3: return Color.accentColor
        case 4: return T.Score.ok
        default: return T.Score.bad
        }
    }

    private func chip(_ t: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Text(t)
            .font(.system(size: T.f2, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
            .padding(.horizontal, 12).frame(height: 34)
            .background(on ? Color.accentColor : Color.primary.opacity(0.06))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture(perform: tap)
    }

    // MARK: 预览：不下整包也能看看里面是什么

    @ViewBuilder private func previewSheet(_ it: CatalogService.RemoteItem) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(it.name).font(.system(size: 18, weight: .semibold))
                    Text("\(it.sentences) 句，\(String(format: "%.1f", Double(it.bytes) / 1e6)) MB")
                        .font(.caption).foregroundStyle(.secondary)
                    levelBar(it.levels)
                }
                if isOn(it.id) {
                    Section("里面的句子") {
                        ForEach(cat.sentences(it.id, limit: 30)) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.en).font(.system(size: 15))
                                if !s.cn.isEmpty {
                                    Text(s.cn).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text("这个包还没装。装了才能看里面的句子 —— "
                             + "包是一次下完的，装完全程离线，不再联网。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Button(busy == it.id ? "正在下…" : "下载并安装") {
                            Task { await get(it); preview = nil }
                        }
                        .disabled(busy != nil)
                    }
                }
            }
            .navigationTitle("预览").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button("关闭") { preview = nil } } }
        }
    }

    // MARK: 动作

    private func load() async {
        loading = true; err = nil
        installed = cat.packs()
        do { remote = try await cat.fetchCatalog() }
        catch { err = error.localizedDescription }
        loading = false
    }

    private func get(_ it: CatalogService.RemoteItem) async {
        busy = it.id; err = nil
        do { _ = try await cat.download(it); installed = cat.packs() }
        catch { err = error.localizedDescription }
        busy = nil
    }
}
