import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// 音量键切句。
///
/// iOS 不给 App"监听按键"的接口，所以做法是：盯住系统音量（AVAudioSession.outputVolume），
/// 一变化就说明用户按了音量键 —— 变大＝下一句，变小＝上一句 —— 然后立刻把音量拨回原值，
/// 用户听感上音量没动。这是 iOS 上唯一可行的路子，每日英语听力那类 App 也是这么干的。
///
/// 几个坑（都处理了）：
/// - 复位音量本身也会触发一次回调，要用标志位吞掉，否则会连锁触发。
/// - 音量已经在 0 或 1 时按键不会产生变化，所以开启时先把音量停在 0.5 附近留出余量。
/// - 只在"随身模式"开着的时候接管，关掉立刻还给系统。
@MainActor
final class VolumeKeys: NSObject, ObservableObject {
    static let shared = VolumeKeys()

    @Published private(set) var enabled = false
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?

    private var observation: NSKeyValueObservation?
    private let volumeView = MPVolumeView(frame: .init(x: -4000, y: -4000, width: 1, height: 1))
    private var slider: UISlider?
    private var baseline: Float = 0.5
    private var ignoreNext = false
    private var lastFire = Date.distantPast

    private override init() { super.init() }

    func enable(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard !enabled else { return }
        // 隐藏的 MPVolumeView：拿到系统音量滑块，用来悄悄复位
        if slider == nil {
            volumeView.showsRouteButton = false
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first?.addSubview(volumeView)
            slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        baseline = min(0.85, max(0.15, session.outputVolume))   // 两头留余量，按到底也还能再按
        setSystemVolume(baseline)
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, let v = change.newValue else { return }
            Task { @MainActor in self.volumeChanged(v) }
        }
        enabled = true
    }

    private func stop() {
        observation?.invalidate(); observation = nil
        enabled = false
    }

    private func volumeChanged(_ v: Float) {
        if ignoreNext { ignoreNext = false; return }
        // 200ms 内只算一次，防止一次按键抖出两个事件
        guard Date().timeIntervalSince(lastFire) > 0.2 else { setSystemVolume(baseline); return }
        lastFire = Date()
        if v > baseline { onUp?() } else if v < baseline { onDown?() }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        setSystemVolume(baseline)
    }

    private func setSystemVolume(_ v: Float) {
        ignoreNext = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.slider?.value = v
            // 复位那一下有时不触发回调，200ms 后把标志放掉，免得吞掉真正的按键
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.ignoreNext = false }
        }
    }
}
