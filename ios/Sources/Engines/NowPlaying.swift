import Foundation
import MediaPlayer

/// 锁屏 / 控制中心 / 耳机 / 车机上的那块播放控制。
/// 走路练习时屏幕多半是黑的，这块就是主界面：谁在念、念到哪儿、上一句下一句。
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    /// 当前这句的展示信息，由 Walk 设置
    var title = ""          // 英文句子（盲听时故意不写出来）
    var subtitle = ""       // 词 + 义项
    var blind = false
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onToggle: (() -> Void)?     // 锁屏/耳机上的播放键
    var onPause: (() -> Void)?      // 真正的暂停（系统打断、控制中心的暂停）
    var onReplay: (() -> Void)?     // 重听这一句/这一段

    private var wired = false

    func wire() {
        guard !wired else { return }
        wired = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.onToggle?(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in (self?.onPause ?? self?.onToggle)?(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onToggle?(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.onNext?(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.onPrev?(); return .success }
        // 耳机上的"后退"给"再听一遍这一段"，走路时最常用
        c.skipBackwardCommand.preferredIntervals = [5]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.onReplay?(); return .success }
        c.skipForwardCommand.preferredIntervals = [5]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.onNext?(); return .success }
        for cmd in [c.seekForwardCommand, c.seekBackwardCommand, c.changePlaybackRateCommand] {
            cmd.isEnabled = false
        }
    }

    func update() {
        let p = Player.shared
        let seg = p.segment
        let a = seg?.lowerBound ?? 0
        let b = seg?.upperBound ?? p.duration
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: blind ? "（盲听）\(subtitle)" : (title.isEmpty ? subtitle : title),
            MPMediaItemPropertyArtist: subtitle,
            MPMediaItemPropertyAlbumTitle: "朗文6双解 · 听说训练台",
            MPMediaItemPropertyPlaybackDuration: max(0.01, b - a),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, min(b - a, p.position - a)),
            MPNowPlayingInfoPropertyPlaybackRate: p.isPlaying ? Double(p.rate) : 0.0,
        ]
        if let img = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = p.isPlaying ? .playing : .paused
    }

    private lazy var artwork: UIImage? = UIImage(named: "AppIcon")
}
