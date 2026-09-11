import Foundation
import Speech

/// 本机语音识别（iOS 自带）。
///
/// 为什么换掉服务器那个 whisper：
///   · 服务器跑的是 base.en 小模型，把 "Excuse me" 听成 "i could kill"（真机上就这样）
///   · 每条录音要上传、等结果、再传回来，慢，而且没网就用不了
///   · 录音离开手机，隐私上说不清楚
///
/// 系统自带的这个：iOS 17 起支持完全离线（requiresOnDeviceRecognition），
/// 零体积、不要钱、比 base.en 准，而且**录音不出手机**。
///
/// 要用得先要一次权限（第一次跟读时弹窗）。用户拒了也不影响别的功能，
/// 逐词比对那套不依赖它。
@MainActor
final class Speech {
    static let shared = Speech()
    private init() {}

    enum Err: LocalizedError {
        case denied, unavailable, empty
        var errorDescription: String? {
            switch self {
            case .denied:      return "没给语音识别权限（设置里可以打开）"
            case .unavailable: return "这台设备的英语识别不可用"
            case .empty:       return "没听清你说了什么"
            }
        }
    }

    /// 问一次权限。用户拒了就一直是拒了，不反复骚扰。
    func ask() async -> Bool {
        let st = SFSpeechRecognizer.authorizationStatus()
        if st == .authorized { return true }
        if st != .notDetermined { return false }
        return await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// 听写的结果：文字，外加**它到底认到了第几秒**。
    /// 认到哪儿这件事很关键：实测同样一段 18 秒的音频，
    /// 这个识别器隔一次就只认出开头一小截（37 词 / 7 词 / 3 词 交替出现），
    /// 不看覆盖到哪儿，就只能眼睁睁把后面那些话丢掉。
    struct Heard {
        var text: String
        var covered: Double        // 最后一个词结束在第几秒；拿不到就是 0
    }

    /// 把一段录音听写成文字，并告诉调用方认到了第几秒。
    func transcribeDetailed(_ url: URL) async throws -> Heard {
        guard await ask() else { throw Err.denied }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              rec.isAvailable else { throw Err.unavailable }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.taskHint = .dictation
        if #available(iOS 16.0, *) { req.addsPunctuation = false }
        return try await withCheckedThrowingContinuation { c in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let error { done = true; c.resume(throwing: error); return }
                guard let result, result.isFinal else { return }
                done = true
                let t = result.bestTranscription
                let text = t.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                let covered = t.segments.last.map { $0.timestamp + $0.duration } ?? 0
                if text.isEmpty { c.resume(throwing: Err.empty) }
                else { c.resume(returning: Heard(text: text, covered: covered)) }
            }
        }
    }

    /// 把一段录音听写成文字。全程离线。
    func transcribe(_ url: URL) async throws -> String {
        guard await ask() else { throw Err.denied }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              rec.isAvailable else { throw Err.unavailable }

        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = true      // 强制本机：不联网、录音不外传
        req.shouldReportPartialResults = false
        req.taskHint = .dictation
        // 逐词时间戳也要 —— 将来可以拿它跟对齐结果互相印证
        if #available(iOS 16.0, *) { req.addsPunctuation = false }

        return try await withCheckedThrowingContinuation { c in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let error {
                    done = true; c.resume(throwing: error); return
                }
                guard let result, result.isFinal else { return }
                done = true
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { c.resume(throwing: Err.empty) }
                else { c.resume(returning: text) }
            }
        }
    }
}
