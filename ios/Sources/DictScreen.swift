import SwiftUI
import WebKit

/// 查词。词典正文那一块用 WKWebView 渲染 —— 朗文的排版（义项、搭配框、同义词框、
/// 音标、插图）本来就是 HTML+CSS，让 Safari 排是最准也最快的，这里它就是个"富文本控件"。
/// 例句清单、播放、加词、跳转全是原生的。
struct DictScreen: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: Player
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage("ui.scheme") private var scheme = "system"
    @AppStorage("ui.entryFont") private var entryFont = 17.0
    @AppStorage("ui.listFont") private var listFont = 15.0
    @State private var q = ""
    @State private var suggestions: [String] = []
    @State private var showList = false
    @State private var playingSrc: String?
    @State private var filter = "all"          // 清单过滤：全部/收藏/没练过/有难点/该复习
    @State private var seqPlaying = false      // 整条连播
    @AppStorage("dict.rep") private var rep = 2        // 每句几遍
    @AppStorage("dict.gap") private var gap = 0.8      // 两遍之间

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if store.entryHTML.isEmpty {
                        welcome
                    } else {
                        EntryWebView(html: store.entryHTML, fontSize: entryFont,
                                     dark: effectiveDark, onWord: { w in
                            Task { await store.look(w) }
                        }, onSound: { src in
                            if let it = store.items.first(where: { $0.src == src }) { playOne(it) }
                            else { playRaw(src) }
                        })
                        .ignoresSafeArea(edges: .bottom)
                    }
                }
                if !store.items.isEmpty { listHandle }
            }
            .navigationTitle(store.word.isEmpty ? "查词" : store.word)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $q, prompt: "查一个词（中文也能查）")
            .searchSuggestions {
                ForEach(suggestions, id: \.self) { s in
                    Text(s).searchCompletion(s)
                }
                if q.isEmpty {
                    Section("最近查过") {
                        ForEach(store.hist.prefix(12)) { h in
                            Text(h.w).searchCompletion(h.w)
                        }
                    }
                }
            }
            .onChange(of: q) { _, v in
                Task {
                    guard v.count >= 1 else { suggestions = []; return }
                    suggestions = (try? await Api.suggest(v)) ?? []
                }
            }
            .onSubmit(of: .search) { Task { await store.look(q) } }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { cycleScheme() } label: {
                        Image(systemName: scheme == "system" ? "circle.lefthalf.filled"
                                        : (scheme == "light" ? "sun.max" : "moon"))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !store.word.isEmpty {
                        Button {
                            Task { await store.addWord() }
                        } label: {
                            Label(store.inLib ? "已在计划" : "学这个词",
                                  systemImage: store.inLib ? "checkmark.circle.fill" : "plus.circle")
                        }
                        .disabled(store.inLib)
                    }
                }
            }
            .sheet(isPresented: $showList) { sentenceList }
        }
    }

    /// 白天 → 夜间 → 跟随系统，一个按钮循环切
    private func cycleScheme() {
        scheme = scheme == "system" ? "light" : (scheme == "light" ? "dark" : "system")
    }
    private var effectiveDark: Bool {
        scheme == "dark" ? true : (scheme == "light" ? false : systemScheme == .dark)
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("把词典当教材，一句一句练").font(.title3.weight(.semibold))
                Text("查一个词 → 点右上角「学这个词」，它在词典里的每条例句都会变成一张卡；\n"
                     + "点例句进「精听」：波形上圈出听不懂的那半秒反复听、放慢、标难点；\n"
                     + "练完打个分，系统按记忆曲线安排下次复习。")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                if !store.hist.isEmpty {
                    Text("最近查过").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    FlowLayout(spacing: 8) {
                        ForEach(store.hist.prefix(20)) { h in
                            Button { Task { await store.look(h.w) } } label: { Pill(text: h.w) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    private var listHandle: some View {
        Button { showList = true } label: {
            HStack {
                Text("\(store.word) · \(store.items.count) 条例句").font(.system(size: 14, weight: .medium))
                Spacer()
                Image(systemName: "chevron.up")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.bar)
        }
        .buttonStyle(.plain)
    }

    private var filtered: [(Int, Api.Sentence)] {
        Array(store.items.enumerated()).filter { _, s in
            let p = store.prog[s.src]
            switch filter {
            case "fav":  return (p?.fav ?? 0) == 1
            case "new":  return (p?.reps ?? 0) == 0
            case "mark": return (p?.marks ?? 0) > 0
            case "due":  return (p?.reps ?? 0) > 0 && (p?.due ?? 0) <= Date().timeIntervalSince1970
            default:     return true
            }
        }
    }

    private var sentenceList: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach([("all","全部"),("fav","★ 收藏"),("new","没练过"),
                                     ("mark","有难点"),("due","该复习")], id: \.0) { k, n in
                                Button { filter = k } label: {
                                    Text(n).font(.system(size: 12.5))
                                        .padding(.horizontal, 11).padding(.vertical, 6)
                                        .background(filter == k ? Color.accentColor : Color(.secondarySystemBackground))
                                        .foregroundStyle(filter == k ? Color.white : Color.primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            seqPlaying ? stopSequence() : playAll()
                        } label: {
                            Label(seqPlaying ? "停止连播" : "整条连播",
                                  systemImage: seqPlaying ? "stop.fill" : "play.fill")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Stepper("每句 \(rep) 遍", value: $rep, in: 1...10).font(.system(size: 12.5))
                    }
                }
                ForEach(filtered, id: \.1.src) { idx, s in
                    Section {
                        Button {
                            store.index = idx
                            playOne(s)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    dot(for: s)
                                    Text(s.en).font(.system(size: listFont))
                                        .foregroundStyle(playingSrc == s.src ? Color.accentColor : .primary)
                                }
                                if let cn = s.cn, !cn.isEmpty {
                                    Text(cn).font(.system(size: listFont - 2)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("精听") { store.index = idx; showList = false }.tint(.accentColor)
                        }
                    } header: {
                        if idx == 0 || store.items[idx - 1].grp != s.grp {
                            Text(s.gnum ?? s.grp ?? "").font(.caption)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("例句")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("收起") { showList = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func dot(for s: Api.Sentence) -> some View {
        let p = store.prog[s.src]
        let c: Color = (p?.state ?? 0) == 2 ? .green : ((p?.reps ?? 0) > 0 ? .orange : .gray.opacity(0.4))
        return Circle().fill(c).frame(width: 8, height: 8)
    }

    /// 点一句：按设定的遍数循环播它（PC 版那颗 ↻ 的手机版）
    private func playOne(_ s: Api.Sentence) {
        seqPlaying = false
        playingSrc = s.src
        Task {
            Player.shared.claim(loop: rep > 1, times: rep, onEnd: { playingSrc = nil })
            Player.shared.gapIn = gap
            try? await Player.shared.load(src: s.src)
            Player.shared.play(from: 0)
        }
    }

    /// 整条连播：这个词（当前过滤下）的例句从上到下依次播，每句 N 遍
    private func playAll() {
        let list = filtered.map { $0.1 }
        guard !list.isEmpty else { return }
        seqPlaying = true
        var i = 0
        func step() {
            guard seqPlaying, i < list.count else { seqPlaying = false; playingSrc = nil; return }
            let s = list[i]; i += 1
            playingSrc = s.src
            if let k = store.items.firstIndex(where: { $0.src == s.src }) { store.index = k }
            Task {
                Player.shared.claim(loop: rep > 1, times: rep, onEnd: { step() })
                Player.shared.gapIn = gap
                try? await Player.shared.load(src: s.src)
                Player.shared.play(from: 0)
            }
        }
        step()
    }
    /// 词条里那些不在例句清单里的音频（比如单词读音），直接放一遍
    private func playRaw(_ src: String) {
        seqPlaying = false
        playingSrc = src
        Task {
            Player.shared.claim()
            try? await Player.shared.load(src: src)
            Player.shared.play(from: 0)
        }
    }
    private func stopSequence() {
        seqPlaying = false
        playingSrc = nil
        Player.shared.claim()
    }
}

/// 词条正文。链接（查别的词）和喇叭（放音）都拦下来交给原生处理。
struct EntryWebView: UIViewRepresentable {
    var html: String
    var fontSize: Double = 17
    /// 词条正文是网页渲染的，它的夜间样式原来只认系统外观；
    /// App 里强制切白天/夜间时就对不上了，所以由外面告诉它到底是黑还是白。
    var dark: Bool = false
    var onWord: (String) -> Void
    var onSound: (String) -> Void

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        let v = WKWebView(frame: .zero, configuration: c)
        v.navigationDelegate = context.coordinator
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.contentInsetAdjustmentBehavior = .always
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html
                || context.coordinator.lastFont != fontSize
                || context.coordinator.lastDark != dark else { return }
        context.coordinator.lastHTML = html
        context.coordinator.lastFont = fontSize
        context.coordinator.lastDark = dark
        v.loadHTMLString(page(html), baseURL: URL(string: Api.base))
    }

    /// 词典自带的 lm6.css 是按白纸写的，夜间要把写死的黑字和浅色框整体换掉 ——
    /// 跟网页版同一套映射，这里内联进去。
    private func page(_ body: String) -> String {
        """
        <!doctype html><html class="\(dark ? "night" : "day")"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <link rel="stylesheet" href="\(Api.base)/res/lm6.css">
        <style>
        html.day{color-scheme:light}
        html.night{color-scheme:dark}
        :root{--ink:#1c2530;--dim:#68788c;--ex:#1a49a6;--num:#1a4f9c;--card:#fff;--line:#dde4ec;--hi:#eef3f9}
        html.night{--ink:#dde5ee;--dim:#8b9aab;--ex:#8ab4f8;--num:#7fb0f0;--card:#1c1c1e;--line:#333c46;--hi:#2a323b}
        body{margin:0;padding:14px 16px 90px;background:transparent;color:var(--ink);
          font:\(fontSize)px/1.85 -apple-system,"PingFang SC",system-ui}
        .entry{color:var(--ink)!important;font-family:inherit!important;line-height:1.85!important}
        .example{color:var(--ex)!important;display:block;margin:2px 0}
        .expcn,.defcn,.collocn,.gramcn,.explcn{color:var(--dim)!important;margin-left:.8em!important}
        .sensenum{color:var(--num)!important;font-weight:700}
        .subsense{font-weight:400}
        a.snd{display:inline-block;width:26px;height:26px;vertical-align:-6px;margin-right:6px;
          border-radius:50%;background:rgba(90,140,220,.22);position:relative;text-decoration:none}
        a.snd img{display:none}
        a.snd::after{content:"";position:absolute;left:9px;top:7px;border-style:solid;
          border-width:6px 0 6px 9px;border-color:transparent transparent transparent var(--ex)}
        img{max-width:100%;height:auto}
        /* 词典自带的 css 是照白纸写的，夜间要把写死的黑字和浅色框整体换掉 */
        html.night .collobox .section,html.night .thesbox .section,
        html.night .collocations .section,html.night .thesaurus .section,
        html.night .usagebox .expl,html.night .grambox .expl{
          background-color:var(--hi)!important;color:var(--ink)!important}
        html.night .gloss,html.night .collgloss,html.night .neutral,
        html.night .italic,html.night .entry{color:var(--ink)!important}
        html.night .colloc,html.night .keycollo,html.night .deriv,
        html.night .phrvbhwd,html.night .homnum{color:var(--ex)!important}
        html.night .gram,html.night .pos{color:#6fce8f!important}
        html.night .geo,html.night .registerlab{color:#c9a3e6!important}
        html.night .freq,html.night .level,html.night .frequent,html.night .cross{color:#ef6a63!important}
        </style></head><body>\(body)
        <script>
        document.addEventListener("click", function(e){
          var a = e.target.closest("a"); if(!a) return;
          e.preventDefault();
          var h = a.getAttribute("href") || "";
          if (a.classList.contains("snd")) { window.webkit.messageHandlers.snd.postMessage(h); return; }
          if (a.classList.contains("ent")) {
            var t = h.replace(/^#/, "");
            if (/^\\d|^[0-9a-f]{20,}/.test(t)) {
              var el = document.getElementById(t) || document.getElementsByName(t)[0];
              if (el) el.scrollIntoView({block:"start", behavior:"smooth"});
              return;
            }
            window.webkit.messageHandlers.word.postMessage(decodeURIComponent(t));
          }
        });
        </script></body></html>
        """
    }

    final class Coord: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: EntryWebView
        var lastHTML = ""
        var lastFont: Double = 0
        var lastDark: Bool?
        init(_ p: EntryWebView) {
            parent = p
            super.init()
        }
        /// 服务器是自签证书。URLSession 那边已经放行了，WKWebView 得单独再放一次 ——
        /// 不放的话样式表和插图会静默加载失败，词条就变成没排版的一坨（踩过）。
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                   URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let t = challenge.protectionSpace.serverTrust,
               challenge.protectionSpace.host == URL(string: Api.base)?.host {
                completionHandler(.useCredential, URLCredential(trust: t)); return
            }
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
               !Api.user.isEmpty {
                completionHandler(.useCredential,
                    URLCredential(user: Api.user, password: Api.pass, persistence: .forSession))
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let c = webView.configuration.userContentController
            c.removeAllScriptMessageHandlers()
            c.add(self, name: "snd")
            c.add(self, name: "word")
        }
        func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let s = m.body as? String else { return }
            if m.name == "snd" { parent.onSound(s) } else { parent.onWord(s) }
        }
    }
}
