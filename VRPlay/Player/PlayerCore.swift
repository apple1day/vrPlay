import AVFoundation
import Combine
import CoreVideo
import UIKit

/// 播放核心：AVPlayer + AVPlayerItemVideoOutput。
/// 不使用 AVPlayerLayer，而是把每一帧的 CVPixelBuffer 交给 Metal 渲染器。
/// 之后要支持 MKV 等格式，只需要换掉这一层，保持 copyLatestFrame() 接口不变。
final class PlayerCore: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var errorText: String?

    let player = AVPlayer()
    private var output: AVPlayerItemVideoOutput?
    private var timeObserver: Any?
    private var bag = Set<AnyCancellable>()
    private var itemBag = Set<AnyCancellable>()
    private var endObserver: NSObjectProtocol?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            let s = t.seconds
            if s.isFinite { self?.currentTime = s }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = (status != .paused)
                self?.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
            }
            .store(in: &bag)
    }

    deinit {
        if let t = timeObserver { player.removeTimeObserver(t) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
    }

    func load(url: URL, startAt: Double = 0, autoplay: Bool = true) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        itemBag.removeAll()
        errorText = nil
        videoSize = .zero
        duration = 0
        currentTime = 0

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        output = out

        let item = AVPlayerItem(url: url)
        item.add(out)

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item else { return }
                if status == .failed {
                    self.errorText = item.error?.localizedDescription ?? "无法播放该文件"
                }
            }
            .store(in: &itemBag)

        item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                if size.width > 0, size.height > 0 { self?.videoSize = size }
            }
            .store(in: &itemBag)

        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in
                if d.seconds.isFinite { self?.duration = d.seconds }
            }
            .store(in: &itemBag)

        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.pause()
            self?.player.seek(to: .zero)
        }

        player.replaceCurrentItem(with: item)
        if startAt > 1 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if autoplay { player.play() }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        output = nil
        itemBag.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func togglePlay() { isPlaying ? player.pause() : player.play() }
    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func skip(by delta: Double) {
        let target = min(max(0, currentTime + delta), max(duration, 0))
        seek(to: target)
    }

    /// 渲染循环每帧调用；返回 nil 表示没有新帧，渲染器继续使用上一帧
    func copyLatestFrame() -> CVPixelBuffer? {
        guard let out = output else { return nil }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        guard t.isValid, out.hasNewPixelBuffer(forItemTime: t) else { return nil }
        return out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    }
}
