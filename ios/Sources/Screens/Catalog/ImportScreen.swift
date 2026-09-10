import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 导入自己的材料。四条路，覆盖用户点名的那几个渠道：
///
/// | 用户说的 | 这里怎么走 |
/// |---|---|
/// | iOS 手机 / iPad 上的文件 | 系统「文件」选择器 |
/// | iCloud | 同上（iCloud 云盘就是文件 App 里的一个位置） |
/// | 百度网盘 / Google 云盘 | 同上 —— 这两个 App 都往文件 App 里注册了"位置"，
///   在选择器左上角「浏览」里能直接进去。**不用接它们的 SDK** |
/// | 电脑浏览器上传 | 手机自己开个 HTTP 口，电脑上打开一个网址就能传（不过服务器） |
/// | iPhone/iPad 播客 | 贴一个播客的 RSS 地址，选一集下下来 |
/// | 相册里的视频 | 系统相册选择器 |
struct ImportScreen: View {
    @StateObject private var svc = ImportService.shared
    @StateObject private var server = UploadServer()
    @StateObject private var ent = EntitlementService.shared
    @State private var picking = false
    @State private var photo: PhotosPickerItem?
    @State private var showServer = false
    @State private var showPodcast = false
    @State private var pending: (url: URL, name: String)?
    @State private var title = ""
    @State private var error: String?
    @State private var doneName: String?
    var onClose: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: T.s3) {
                    if svc.running { progressCard } else { channels }
                    quotaLine
                    Text("导进来的材料会在手机上自己听写、自己切词，"
                         + "然后跟预置材料一样能精听、能出七个练法的题。**全程不联网。**")
                        .font(.system(size: T.f1)).foregroundStyle(.secondary)
                        .padding(.horizontal, T.s2)
                }
                .padding(T.side)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("导入材料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭", action: onClose) }
                }
            }
            .fileImporter(isPresented: $picking,
                          allowedContentTypes: [.audio, .movie, .mpeg4Movie, .mp3, .wav],
                          allowsMultipleSelection: false) { r in
                if case .success(let urls) = r, let u = urls.first {
                    pending = (u, u.deletingPathExtension().lastPathComponent)
                    title = pending!.name
                }
                if case .failure(let e) = r { error = e.localizedDescription }
            }
            .sheet(isPresented: $showServer) { serverSheet }
            .sheet(isPresented: $showPodcast) {
                PodcastSheet { u, n in
                    showPodcast = false
                    pending = (u, n); title = n
                }
            }
            .alert("要导入什么名字？", isPresented: Binding(
                get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                TextField("材料名字", text: $title)
                Button("开始") { start() }
                Button("取消", role: .cancel) { pending = nil }
            }
            .alert("没导成", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .alert("导好了", isPresented: Binding(
                get: { doneName != nil }, set: { if !$0 { doneName = nil } })) {
                Button("好", role: .cancel) { doneName = nil }
            } message: { Text("「\(doneName ?? "")」已经进材料库，可以练了。") }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            .onDisappear { server.stop() }
        }
    }

    // MARK: 四条路

    private var channels: some View {
        VStack(spacing: T.s2) {
            row("从文件导入", "folder", "本机、iCloud 云盘、百度网盘、Google 云盘都在这里面") {
                picking = true
            }
            PhotosPicker(selection: $photo, matching: .any(of: [.videos])) {
                rowLabel("从相册选视频", "photo.on.rectangle", "自己拍的、存下来的都行")
            }
            .buttonStyle(.plain)
            row("从电脑浏览器传", "desktopcomputer",
                "手机和电脑连同一个 WiFi，电脑上打开一个网址就能传") {
                server.start(); showServer = true
            }
            row("从播客导入", "antenna.radio.waves.left.and.right",
                "贴一个播客的 RSS 地址，挑一集下下来") { showPodcast = true }
        }
    }

    private func row(_ t: String, _ icon: String, _ sub: String,
                     _ go: @escaping () -> Void) -> some View {
        Button(action: go) { rowLabel(t, icon, sub) }.buttonStyle(.plain)
            .accessibilityIdentifier("import." + icon)
    }

    private func rowLabel(_ t: String, _ icon: String, _ sub: String) -> some View {
        HStack(spacing: T.s3) {
            Image(systemName: icon).font(.system(size: T.f4))
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: T.f3, weight: .medium))
                Text(sub).font(.system(size: T.f1)).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: T.f1)).foregroundStyle(.tertiary)
        }
        .padding(T.s3).frame(maxWidth: .infinity).cardStyle()
    }

    // MARK: 处理中

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text("正在处理").font(.system(size: T.f4, weight: .semibold))
            ProgressView(value: svc.step?.fraction ?? 0)
            Text(svc.step?.text ?? "准备中")
                .font(.system(size: T.f2)).foregroundStyle(.secondary)
            Text("听写和切词都在这台手机上算，长一点的材料要等几分钟。"
                 + "这一屏别关，插着电更快。")
                .font(.system(size: T.f1)).foregroundStyle(.secondary)
        }
        .padding(T.s4).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    private var quotaLine: some View {
        Group {
            if let left = ent.remaining(.importFile) {
                Text("还能导入 \(left) 份（\(ent.tier.name)）")
                    .font(.system(size: T.f1)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    // MARK: 电脑上传那一屏

    private var serverSheet: some View {
        VStack(spacing: T.s4) {
            Image(systemName: "wifi").font(.system(size: 40)).foregroundStyle(Color.accentColor)
            Text("在电脑浏览器里打开").font(.system(size: T.f4, weight: .semibold))
            Text(server.address ?? "正在开…")
                .font(.system(size: T.f5, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            Text(server.address == nil
                 ? "开不起来 —— 检查一下手机连着 WiFi 没有。"
                 : "手机和电脑要连同一个 WiFi。文件直接进这台手机，不经过任何服务器。")
                .font(.system(size: T.f2)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("关掉这个口") { server.stop(); showServer = false }
                .buttonStyle(.bordered)
        }
        .padding(T.s6)
        .onAppear {
            server.onFile = { url, name in
                showServer = false
                server.stop()
                pending = (url, name)
                title = (name as NSString).deletingPathExtension
            }
        }
    }

    // MARK: 动作

    private func start() {
        guard let p = pending else { return }
        let name = title.isEmpty ? p.name : title
        pending = nil
        Task {
            do {
                let pack = try await svc.importMedia(from: p.url, title: name)
                doneName = pack.name
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        // 相册里的视频要先落地成文件才能读音轨
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            error = "这段视频读不出来"; return
        }
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-\(UUID().uuidString).mov")
        try? data.write(to: u)
        photo = nil
        pending = (u, "相册视频")
        title = "相册视频"
    }
}

/// 播客：贴 RSS 地址 → 列集数 → 选一集下下来。
/// 不做播客搜索目录 —— 那要么接第三方 API，要么自己维护一份榜单，
/// 都跟"服务器干最少的活"冲突。用户从播客 App 里复制一个 RSS 地址就够了。
struct PodcastSheet: View {
    var onPick: (URL, String) -> Void
    @State private var feed = ""
    @State private var items: [(title: String, url: URL)] = []
    @State private var loading = false
    @State private var note: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("播客的 RSS 地址", text: $feed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button(loading ? "读取中…" : "读取") { Task { await load() } }
                        .disabled(feed.isEmpty || loading)
                } footer: {
                    Text("在播客 App 里长按节目 →「拷贝节目链接」，多数节目给的就是 RSS。")
                }
                if let note { Text(note).font(.system(size: T.f2)).foregroundStyle(.secondary) }
                if !items.isEmpty {
                    Section("选一集") {
                        ForEach(items.indices, id: \.self) { i in
                            Button {
                                Task { await download(items[i]) }
                            } label: {
                                Text(items[i].title).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("从播客导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } } }
        }
    }

    private func load() async {
        loading = true; note = nil
        defer { loading = false }
        guard let u = URL(string: feed.trimmingCharacters(in: .whitespaces)) else {
            note = "地址不对"; return
        }
        do {
            let (d, _) = try await URLSession.shared.data(from: u)
            items = Array(RSS.parse(d).prefix(50))
            if items.isEmpty { note = "这个地址里没找到音频集数" }
        } catch {
            note = "读不到：\(error.localizedDescription)"
        }
    }

    private func download(_ it: (title: String, url: URL)) async {
        loading = true
        defer { loading = false }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: it.url)
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("pod-\(UUID().uuidString)." + it.url.pathExtension)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            onPick(dst, it.title)
        } catch {
            note = "下载失败：\(error.localizedDescription)"
        }
    }
}

/// 只抠两样：每集的标题和音频地址。RSS 花样很多，抠不到就当没有，不报错。
enum RSS {
    static func parse(_ data: Data) -> [(title: String, url: URL)] {
        let p = XMLParser(data: data)
        let d = Delegate()
        p.delegate = d
        p.parse()
        return d.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [(title: String, url: URL)] = []
        private var inItem = false
        private var title = ""
        private var url: URL?
        private var cur = ""

        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String]) {
            cur = e
            if e == "item" { inItem = true; title = ""; url = nil }
            if e == "enclosure", inItem, let s = a["url"] { url = URL(string: s) }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) {
            if inItem, cur == "title" { title += s }
        }
        func parser(_ p: XMLParser, foundCDATA b: Data) {
            if inItem, cur == "title" { title += String(decoding: b, as: UTF8.self) }
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if e == "item" {
                if let u = url {
                    items.append((title.trimmingCharacters(in: .whitespacesAndNewlines), u))
                }
                inItem = false
            }
            cur = ""
        }
    }
}
