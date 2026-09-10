import SwiftUI
import WebKit

/// YouTube 词级跟随。
///
/// 用户定的边界很清楚：
/// > 不要youtube的音视频，只提供给用户一个词级跟随的界面，
/// > 播放/下载视频都在用户自己的手机和网络上
///
/// 所以这一屏做的是：**视频用官方播放器在他自己手机上播**（我们不下载、不转存、
/// 不代理），我们只干两件事 ——
/// ① 把字幕拿回来（也是从他的手机发的请求），
/// ② 按播放进度把当前那个词点亮，点哪个词就跳到哪儿。
///
/// 方案 B（让用户自己下载文件再导入）用户明确否掉了：「用户都是小白」。
struct VideoFollowScreen: View {
    @StateObject private var m = VideoFollowModel()
    @State private var link = ""
    var onClose: (() -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if m.videoID == nil {
                    entry
                } else {
                    player
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("视频跟读")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭", action: onClose) }
                }
                if m.videoID != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("换一个") { m.reset(); link = "" }
                    }
                }
            }
        }
    }

    // MARK: 贴链接

    private var entry: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.s4) {
                VStack(alignment: .leading, spacing: T.s2) {
                    Text("贴一个 YouTube 链接").font(.system(size: T.f4, weight: .semibold))
                    TextField("https://www.youtube.com/watch?v=…", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(T.s3)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                        .accessibilityIdentifier("yt.link")
                    Button {
                        m.open(link)
                    } label: {
                        Text("打开").frame(maxWidth: .infinity, minHeight: T.hBig)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(link.isEmpty)
                    .accessibilityIdentifier("yt.open")
                }
                .padding(T.s4).frame(maxWidth: .infinity, alignment: .leading).cardStyle()

                if let e = m.error {
                    Text(e).font(.system(size: T.f2)).foregroundStyle(T.Score.bad)
                        .padding(.horizontal, T.s2)
                }

                VStack(alignment: .leading, spacing: T.s2) {
                    Label("视频在你自己的手机和网络上播", systemImage: "iphone")
                    Label("我们只取字幕，不下载、不转存视频", systemImage: "captions.bubble")
                    Label("带自动字幕的视频，跟随能精确到词", systemImage: "text.word.spacing")
                }
                .font(.system(size: T.f2)).foregroundStyle(.secondary)
                .padding(.horizontal, T.s2)
            }
            .padding(T.side)
        }
    }

    // MARK: 播放 + 跟随

    private var player: some View {
        VStack(spacing: 0) {
            YTPlayer(videoID: m.videoID ?? "", model: m)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)

            if m.loadingCaptions {
                HStack(spacing: T.s2) {
                    ProgressView()
                    Text("在取字幕…").font(.system(size: T.f2)).foregroundStyle(.secondary)
                }
                .padding(T.s3)
            } else if let e = m.error {
                Text(e).font(.system(size: T.f2)).foregroundStyle(.secondary)
                    .padding(T.s4).multilineTextAlignment(.center)
            } else {
                accuracyNote
                transcript
                controls
            }
            Spacer(minLength: 0)
        }
    }

    /// 词级还是估算，如实说 —— 对不上的时候用户得知道是字幕的问题，不是他耳朵的问题
    @ViewBuilder private var accuracyNote: some View {
        if let t = m.track {
            HStack(spacing: T.s2) {
                Image(systemName: t.wordLevel ? "checkmark.seal.fill" : "info.circle")
                    .foregroundStyle(t.wordLevel ? T.Score.good : .secondary)
                Text(t.wordLevel
                     ? "这个视频的字幕自带词级时间戳，跟随是准的"
                     : "这个视频只有整句字幕，词的位置是按词长估的，会有偏差")
                    .font(.system(size: T.f1)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, T.side).padding(.vertical, T.s2)
        }
    }

    private var transcript: some View {
        ScrollViewReader { sp in
            ScrollView {
                VStack(alignment: .leading, spacing: T.s3) {
                    ForEach(m.track?.cues ?? []) { cue in
                        FlowRow(spacing: 6) {
                            ForEach(cue.words.indices, id: \.self) { i in
                                let w = cue.words[i]
                                let on = m.currentCue == cue.id && m.currentWord == i
                                Text(w.text)
                                    .font(.system(size: T.f4))
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .background(on ? Color.accentColor.opacity(0.22) : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(m.currentCue == cue.id ? Color.primary : .secondary)
                                    .onTapGesture { m.seek(w.start) }
                                    // Text 拼的控件系统不当按钮，VoiceOver 也读不出来
                                    .accessibilityElement()
                                    .accessibilityLabel(w.text)
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                        .id(cue.id)
                    }
                }
                .padding(T.side)
            }
            .onChange(of: m.currentCue) { _, c in
                guard let c, m.autoScroll else { return }
                withAnimation(T.anim) { sp.scrollTo(c, anchor: .center) }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: T.s2) {
            Button { m.toggle() } label: {
                Label(m.playing ? "停" : "播", systemImage: m.playing ? "pause.fill" : "play.fill")
                    .frame(minWidth: 84, minHeight: T.hCtl)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("yt.play")

            Button { m.repeatCue() } label: {
                Label("重听这句", systemImage: "arrow.counterclockwise")
                    .frame(minHeight: T.hCtl).padding(.horizontal, T.s2)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("yt.repeat")

            ForEach([0.75, 1.0], id: \.self) { r in
                Button { m.setRate(r) } label: {
                    Text(r == 1.0 ? "1x" : "0.75x").monospacedDigit()
                        .frame(minHeight: T.hCtl).padding(.horizontal, T.s2)
                }
                .buttonStyle(QuietButton(on: abs(m.rate - r) < 0.01))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.side).padding(.vertical, T.s2)
        .background(.bar)
    }
}

// MARK: - 状态

@MainActor
final class VideoFollowModel: ObservableObject {
    @Published var videoID: String?
    @Published var track: YouTube.Track?
    @Published var loadingCaptions = false
    @Published var error: String?
    @Published var currentCue: Int?
    @Published var currentWord: Int?
    @Published var playing = false
    @Published var rate = 1.0
    @Published var autoScroll = true

    /// 给 WebView 发指令用；由 `YTPlayer` 在建好之后塞进来
    var run: ((String) -> Void)?

    func open(_ link: String) {
        guard let id = YouTube.videoID(link) else {
            error = YouTube.Err.badLink.errorDescription; return
        }
        error = nil
        videoID = id
        loadingCaptions = true
        Task {
            do { track = try await YouTube.captions(id) }
            catch { self.error = error.localizedDescription }
            loadingCaptions = false
        }
    }

    func reset() {
        run?("stop()")
        videoID = nil; track = nil; currentCue = nil; currentWord = nil
        playing = false; error = nil
    }

    /// 播放器每 100 毫秒报一次时间 —— 再密没意义（人眼分辨不出），
    /// 再稀就会看见词跳着走。
    func tick(_ t: Double) {
        guard let cues = track?.cues else { return }
        // 先找当前这条字幕，再在里面找词。整条字幕列表可能几千个词，
        // 每一帧全表扫会明显掉帧。
        if let c = currentCue, c < cues.count,
           t >= cues[c].start - 0.05, t <= cues[c].end + 0.35 {
            currentWord = YouTube.wordIndex(cues[c].words, at: t)
            return
        }
        if let i = cues.lastIndex(where: { $0.start <= t + 0.05 }), t <= cues[i].end + 0.5 {
            currentCue = i
            currentWord = YouTube.wordIndex(cues[i].words, at: t)
        } else {
            currentWord = nil
        }
    }

    func toggle() {
        run?(playing ? "p.pauseVideo()" : "p.playVideo()")
        playing.toggle()
    }
    func seek(_ t: Double) {
        run?("p.seekTo(\(t), true); p.playVideo()")
        playing = true
    }
    func setRate(_ r: Double) {
        rate = r
        run?("p.setPlaybackRate(\(r))")
    }
    /// 从当前这条字幕的开头重放 —— 精听里最常用的动作
    func repeatCue() {
        guard let c = currentCue, let cue = track?.cues[c] else { return }
        seek(cue.start)
    }
}

// MARK: - 官方 iframe 播放器

/// 用 YouTube 官方的 iframe 播放器：这是**唯一符合他们服务条款**的嵌入方式，
/// 也正好满足用户「播放在他自己手机和网络上」的要求 —— 视频流是浏览器直接去拿的，
/// 我们既不代理也不缓存。
struct YTPlayer: UIViewRepresentable {
    let videoID: String
    let model: VideoFollowModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true                 // 不加会强制全屏，跟读就没法看词了
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.userContentController.add(context.coordinator, name: "yt")
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        context.coordinator.web = web
        model.run = { [weak web] js in web?.evaluateJavaScript(js, completionHandler: nil) }
        // baseURL 必须是 youtube.com：iframe API 会按来源校验，用 about:blank 起不来
        web.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var web: WKWebView?
        let model: VideoFollowModel
        init(model: VideoFollowModel) { self.model = model }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let d = m.body as? [String: Any] else { return }
            Task { @MainActor in
                if let t = d["t"] as? Double { model.tick(t) }
                if let s = d["s"] as? Int { model.playing = (s == 1) }
            }
        }
    }

    private var html: String {
        """
        <!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:#000;height:100%}#p{width:100%;height:100%}</style>
        <div id=p></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var p;
        function onYouTubeIframeAPIReady(){
          p = new YT.Player('p', {
            videoId: '\(videoID)',
            playerVars: {playsinline:1, rel:0, modestbranding:1, cc_load_policy:0},
            events: {
              onReady: function(){ setInterval(tick, 100); },
              onStateChange: function(e){
                window.webkit.messageHandlers.yt.postMessage({s: e.data});
              }
            }
          });
        }
        function tick(){
          if(!p || !p.getCurrentTime) return;
          window.webkit.messageHandlers.yt.postMessage({t: p.getCurrentTime()});
        }
        function stop(){ if(p && p.stopVideo) p.stopVideo(); }
        </script>
        """
    }
}
