import Foundation
import Network

/// 「从电脑浏览器上传」——**手机自己当服务器**。
///
/// 用户要的渠道里有一条是"电脑浏览器上传"。别家的做法是传到自己的服务器上再下发，
/// 那跟这个 App「完全脱离服务器」的方向是反的，而且用户的音频要过一遍别人的机器。
///
/// 这里的做法：手机和电脑在同一个 WiFi 下，手机上临时开一个 HTTP 口，
/// 电脑浏览器打开 `http://手机IP:8828` 就是一个上传页面，文件**直接进手机**，
/// 一个字节都不经过外网。关掉这一屏，口就关了。
///
/// 只在这一屏开着的时候监听，不常驻 —— 常驻一个开放端口是安全问题。
@MainActor
final class UploadServer: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var address: String?
    /// 收到文件了：给出临时文件路径和原始文件名
    var onFile: ((URL, String) -> Void)?

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8828

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, port: port)
            l.newConnectionHandler = { [weak self] c in
                Task { @MainActor in self?.serve(c) }
            }
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    switch st {
                    case .ready:
                        self?.running = true
                        self?.address = Self.localIP().map { "http://\($0):8828" }
                    case .failed, .cancelled:
                        self?.running = false; self?.address = nil
                    default: break
                    }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            running = false
            address = nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        address = nil
    }

    // MARK: 一条连接

    private func serve(_ c: NWConnection) {
        c.start(queue: .global(qos: .userInitiated))
        var buf = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
                if let data { buf.append(data) }
                guard err == nil else { c.cancel(); return }

                // 头收全了没
                guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if done { c.cancel() } else { read() }
                    return
                }
                let head = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self)
                let bodyStart = headEnd.upperBound
                let need = Self.contentLength(head) ?? 0
                let have = buf.count - bodyStart

                if head.hasPrefix("GET") {
                    Self.send(c, status: "200 OK", type: "text/html; charset=utf-8",
                              body: Data(Self.page.utf8))
                    return
                }
                guard have >= need else {          // 大文件要收几十次才收得完
                    if done { c.cancel() } else { read() }
                    return
                }
                let body = buf[bodyStart..<(bodyStart + need)]
                Task { @MainActor in
                    self?.handleUpload(head: head, body: Data(body))
                    Self.send(c, status: "200 OK", type: "text/plain; charset=utf-8",
                              body: Data("收到了，回手机上看".utf8))
                }
            }
        }
        read()
    }

    /// 从 multipart/form-data 里抠出文件本体和文件名。
    /// 只认一个文件字段 —— 上传页面就只有一个 input，不做通用解析。
    private func handleUpload(head: String, body: Data) {
        guard let bLine = head.split(separator: "\n").first(where: { $0.contains("boundary=") }),
              let b = bLine.components(separatedBy: "boundary=").last?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let boundary = Data(("--" + b).utf8)
        guard let first = body.range(of: boundary) else { return }
        let rest = body[first.upperBound...]
        guard let partHeadEnd = rest.range(of: Data("\r\n\r\n".utf8)) else { return }
        let partHead = String(decoding: rest[..<partHeadEnd.lowerBound], as: UTF8.self)
        let name = partHead.components(separatedBy: "filename=\"").last?
            .components(separatedBy: "\"").first ?? "upload.m4a"
        let after = rest[partHeadEnd.upperBound...]
        guard let end = after.range(of: boundary) else { return }
        // 结尾要去掉分隔符前面那个 \r\n，否则文件尾部多两个字节
        let fileData = after[after.startIndex..<end.lowerBound].dropLast(2)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("up-" + name)
        try? Data(fileData).write(to: url)
        onFile?(url, name)
    }

    // MARK: 小工具

    private static func contentLength(_ head: String) -> Int? {
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func send(_ c: NWConnection, status: String, type: String, body: Data) {
        var h = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n"
        h += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    /// 找本机在 WiFi 上的地址（en0）
    static func localIP() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0, let first = addr else { return nil }
        defer { freeifaddrs(addr) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let f = p.pointee
            guard f.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: f.ifa_name)
            guard name == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(f.ifa_addr, socklen_t(f.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found = String(cString: host)
            }
        }
        return found
    }

    /// 电脑上看到的那一页。故意做得极简 —— 用户是小白，页面上只能有一个按钮。
    private static let page = """
    <!doctype html><meta charset=utf-8>
    <meta name=viewport content="width=device-width,initial-scale=1">
    <title>传给听说训练台</title>
    <style>
    body{font:16px/1.6 -apple-system,system-ui,"PingFang SC",sans-serif;
         max-width:520px;margin:12vh auto;padding:0 20px;color:#222}
    h1{font-size:22px;margin:0 0 6px}p{color:#666;margin:0 0 24px}
    label{display:block;border:2px dashed #bbb;border-radius:14px;padding:38px 20px;
          text-align:center;cursor:pointer;background:#fafafa}
    input{display:none}button{margin-top:18px;width:100%;padding:14px;font-size:17px;
          border:0;border-radius:12px;background:#2f6fd0;color:#fff}
    #s{margin-top:14px;color:#2f6fd0}
    @media (prefers-color-scheme:dark){body{background:#111;color:#eee}
      label{background:#1c1c1e;border-color:#444}p{color:#999}}
    </style>
    <h1>传一段音频或视频到手机</h1>
    <p>文件直接进你的手机，不经过任何服务器。</p>
    <form id=f>
      <label for=x id=lb>点这里选文件<br><small>mp3 / m4a / wav / mp4 / mov</small></label>
      <input id=x type=file name=file accept="audio/*,video/*">
      <button type=submit>上传</button>
    </form>
    <div id=s></div>
    <script>
    const x=document.getElementById('x'),s=document.getElementById('s'),lb=document.getElementById('lb');
    x.onchange=()=>{ if(x.files[0]) lb.textContent=x.files[0].name; };
    document.getElementById('f').onsubmit=e=>{
      e.preventDefault();
      if(!x.files[0]){ s.textContent='先选个文件'; return; }
      const fd=new FormData(); fd.append('file',x.files[0]);
      const r=new XMLHttpRequest();
      r.upload.onprogress=ev=>{ s.textContent='上传中 '+Math.round(ev.loaded/ev.total*100)+'%'; };
      r.onload=()=>{ s.textContent='传好了，回手机上继续'; };
      r.onerror=()=>{ s.textContent='传失败了，看看手机上那一屏还开着吗'; };
      r.open('POST','/up'); r.send(fd);
    };
    </script>
    """
}
