import AVFoundation
import Combine
import CoreVideo
import UIKit

/// All playback controls, output delegate callbacks and MTKView frame pulls run on the main queue.
final class PlayerCore: NSObject, ObservableObject, AVPlayerItemOutputPullDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var errorText: String?
    @Published private(set) var startupMessage: String?
    @Published private(set) var hasPresentedVideo = false
    @Published private(set) var usesSystemDisplay = false
    @Published private(set) var videoGeneration = UUID()

    let player = AVPlayer()
    private var url: URL?
    private var output: AVPlayerItemVideoOutput?
    private var requestedPlayback = false
    private var pendingSeek: Double?
    private var seeking: UUID?
    private var triedCompatibleOutput = false
    private var copiedFrame = false
    private var nextFirstFrameProbe: CFTimeInterval = 0
    private var startupTimer: Timer?
    private var foregroundSeconds = 0
    private var timeObserver: Any?
    private var bag = Set<AnyCancellable>()
    private var itemBag = Set<AnyCancellable>()
    private var trackInspection: Task<Void, Never>?
    #if targetEnvironment(simulator)
    private var localAVCTrack: AVAssetTrack?
    private var stillTask: Task<Void, Never>?
    private var stillRequest: UUID?
    private var pendingStill: CVPixelBuffer?
    #endif

    override init() {
        super.init()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            guard let self, self.seeking == nil, self.pendingSeek == nil,
                  let item = self.player.currentItem, item.status == .readyToPlay else { return }
            let seconds = item.currentTime().seconds
            if seconds.isFinite { self.currentTime = max(0, seconds) }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let status = self.player.timeControlStatus
                self.isPlaying = status != .paused
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
            .store(in: &bag)
    }

    deinit {
        startupTimer?.invalidate()
        trackInspection?.cancel()
        #if targetEnvironment(simulator)
        stillTask?.cancel()
        #endif
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func load(url: URL, startAt: Double = 0, autoplay: Bool = true) {
        open(url, startAt: startAt, autoplay: autoplay, systemDisplay: false)
    }

    private func open(_ url: URL, startAt: Double, autoplay: Bool, systemDisplay: Bool) {
        tearDownItem()
        self.url = url
        usesSystemDisplay = systemDisplay
        requestedPlayback = autoplay
        triedCompatibleOutput = false
        errorText = nil
        currentTime = startAt.isFinite ? max(0, startAt) : 0
        pendingSeek = currentTime > 0 ? currentTime : nil
        videoSize = .zero
        duration = 0
        beginWaiting("正在读取视频…")

        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback)
        try? audio.setActive(true)

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        item.publisher(for: \.status, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] _ in
                guard let self, let item, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.prepareReadyItem(item)
                case .failed:
                    self.fail(Self.itemError(item.error))
                default: break
                }
            }
            .store(in: &itemBag)
        item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] size in
                guard let self, let item, self.player.currentItem === item, size.width > 0, size.height > 0 else { return }
                self.videoSize = size
            }
            .store(in: &itemBag)
        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] d in
                guard let self, let item, self.player.currentItem === item, d.seconds.isFinite else { return }
                self.duration = max(0, d.seconds)
            }
            .store(in: &itemBag)

        let center = NotificationCenter.default
        center.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] note in
                guard let self, let item, self.player.currentItem === item else { return }
                self.fail(Self.itemError(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error ?? item.error))
            }
            .store(in: &itemBag)
        center.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] _ in
                guard let self, let item, self.player.currentItem === item, self.errorText == nil else { return }
                if !self.hasPresentedVideo {
                    // A short track can finish before the first-frame watchdog fires.
                    if !self.usesSystemDisplay && !self.triedCompatibleOutput && !self.copiedFrame {
                        self.retryCompatibleOutput(item)
                        self.seek(to: 0)
                    } else {
                        self.fail("媒体已经播完，但未显示任何视频帧。" + self.sizeDescription)
                    }
                    return
                }
                self.pause()
                self.seek(to: 0)
            }
            .store(in: &itemBag)

        // A local audio-only file can be "ready to play" forever without producing a video frame.
        // HLS variant tracks may appear dynamically, so only use this test for local files.
        if url.isFileURL {
            trackInspection = Task { @MainActor [weak self, weak item] in
                guard let item, let tracks = try? await item.asset.loadTracks(withMediaType: .video),
                      !Task.isCancelled, let self, self.player.currentItem === item else { return }
                if tracks.isEmpty { self.fail("文件中没有可读取的视频轨道。") }
                #if targetEnvironment(simulator)
                // Only local AVC needs a substitute still. Normal playback always uses AVPlayer.
                let selected = item.tracks.first { $0.isEnabled && $0.assetTrack?.mediaType == .video }?.assetTrack
                guard let track = selected ?? tracks.first,
                      let formats = try? await track.load(.formatDescriptions), !Task.isCancelled,
                      self.player.currentItem === item,
                      formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 })
                else { return }
                self.localAVCTrack = track
                self.requestPausedStill()
                #endif
            }
        }
    }

    private static func itemError(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "AVFoundation 无法播放此媒体。" }
        return "AVFoundation：\(error.localizedDescription)（\(error.domain) \(error.code)）"
    }

    private func prepareReadyItem(_ item: AVPlayerItem) {
        guard errorText == nil else { return }
        if !usesSystemDisplay, output == nil { attachOutput(to: item) }
        foregroundSeconds = 0
        startupMessage = usesSystemDisplay ? "正在等待系统播放器显示画面…" : "正在解码视频首帧…"
        if let saved = pendingSeek {
            // A URL may now refer to a shorter/replaced file.
            let end = item.duration.seconds
            seek(to: end.isFinite && end > 0 && saved >= end ? 0 : saved)
        } else {
            applyPlaybackIntent()
        }
    }

    private func attachOutput(to item: AVPlayerItem) {
        detachOutput()
        // Let the decoder vend its native depth/range (including 10-bit HEVC).
        // Force NV12 only on a bounded retry if native delivery or texture creation fails.
        var attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        if triedCompatibleOutput {
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let newOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        newOutput.suppressesPlayerRendering = true
        newOutput.setDelegate(self, queue: .main)
        output = newOutput
        item.add(newOutput)
        newOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
    }

    private func detachOutput() {
        if let output {
            output.setDelegate(nil, queue: nil)
            if let item = player.currentItem, item.outputs.contains(where: { $0 === output }) {
                item.remove(output)
            }
        }
        output = nil
    }

    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        if sender === output { nextFirstFrameProbe = 0 }
    }

    func outputSequenceWasFlushed(_ sender: AVPlayerItemOutput) {
        guard sender === output else { return }
        copiedFrame = false
        nextFirstFrameProbe = 0
    }

    func copyLatestFrame() -> CVPixelBuffer? {
        guard !usesSystemDisplay, errorText == nil, seeking == nil, pendingSeek == nil,
              let output, let item = player.currentItem, item.status == .readyToPlay else { return nil }
        #if targetEnvironment(simulator)
        if stillRequest != nil {
            // Retain the renderer’s last frame while reading. After delivering the still once,
            // keep it displayed until playback or a seek makes this request obsolete.
            guard let still = pendingStill else { return nil }
            pendingStill = nil
            copiedFrame = true
            return still
        }
        #endif
        let now = CACurrentMediaTime()
        let mappedTime = output.itemTime(forHostTime: now)
        let itemTime = item.currentTime()
        let time = mappedTime.isNumeric && mappedTime.seconds >= 0 ? mappedTime : itemTime
        guard time.isNumeric else { return nil }
        let isNew = output.hasNewPixelBuffer(forItemTime: time)
        // A paused item or a freshly attached output may lack a host-clock mapping or a "new" flag.
        // Until acquisition, also ask for the current item frame at most ten times per second.
        guard isNew || (!copiedFrame && now >= nextFirstFrameProbe) else { return nil }
        nextFirstFrameProbe = now + 0.1
        var frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        if frame == nil, !copiedFrame, itemTime.isNumeric, CMTimeCompare(time, itemTime) != 0 {
            frame = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        }
        if frame != nil { copiedFrame = true }
        return frame
    }

    private func beginWaiting(_ message: String) {
        #if targetEnvironment(simulator)
        cancelPausedStill()
        #endif
        videoGeneration = UUID()
        copiedFrame = false
        nextFirstFrameProbe = 0
        hasPresentedVideo = false
        startupMessage = message
        foregroundSeconds = 0
        startupTimer?.invalidate()
        startupTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkStartup()
        }
    }

    private func checkStartup() {
        guard UIApplication.shared.applicationState == .active, let item = player.currentItem,
              errorText == nil, !hasPresentedVideo else { return }
        foregroundSeconds += 1
        if item.status != .readyToPlay || seeking != nil {
            if foregroundSeconds >= 30 {
                fail(seeking == nil ? "等待媒体就绪超过 30 秒。请检查文件或网络后重试。" : "等待定位播放位置超过 30 秒。")
            }
            return
        }
        if url?.isFileURL == false, player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            if foregroundSeconds >= 45 { fail("网络视频缓冲超过 45 秒，尚未显示画面。") }
            return
        }
        if usesSystemDisplay {
            if foregroundSeconds >= 12 { fail("系统播放器也未显示视频首帧。\(sizeDescription)") }
        } else if !copiedFrame && !triedCompatibleOutput && foregroundSeconds >= 5 {
            retryCompatibleOutput(item)
        } else if foregroundSeconds >= 12 {
            let detail = copiedFrame ? "已获取视频帧，但 Metal 尚未将画面显示到屏幕。" : "AVFoundation 尚未输出可显示的视频帧。"
            fail(detail + sizeDescription)
        }
    }

    private var sizeDescription: String {
        guard videoSize.width > 0, videoSize.height > 0 else { return "" }
        return "（\(Int(videoSize.width)) × \(Int(videoSize.height))）"
    }

    private func retryCompatibleOutput(_ item: AVPlayerItem) {
        triedCompatibleOutput = true
        beginWaiting("正在使用兼容像素格式重新获取画面…")
        attachOutput(to: item)
        // Re-request the current sample when the clock is paused; a running clock will advance naturally.
        if player.timeControlStatus == .paused {
            let position = item.currentTime()
            if position.isNumeric { item.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil) }
        }
    }

    func videoTextureFailed(_ detail: String) {
        guard !usesSystemDisplay, errorText == nil, let item = player.currentItem else { return }
        if triedCompatibleOutput { fail(detail + sizeDescription) }
        else { retryCompatibleOutput(item) }
    }

    func reportRenderFailure(_ message: String) {
        if !usesSystemDisplay, player.currentItem != nil, errorText == nil { fail(message) }
    }

    func didPresentVideoFrame() {
        if !usesSystemDisplay { markPresented() }
    }

    func didPresentSystemFrame() {
        if usesSystemDisplay { markPresented() }
    }

    private func markPresented() {
        guard player.currentItem != nil, errorText == nil, !hasPresentedVideo else { return }
        hasPresentedVideo = true
        startupMessage = nil
        startupTimer?.invalidate()
        startupTimer = nil
    }

    private func fail(_ message: String) {
        errorText = message
        startupMessage = nil
        startupTimer?.invalidate()
        startupTimer = nil
        player.pause()
    }

    private var recoveryPosition: Double {
        let position = pendingSeek ?? currentTime
        if duration > 0, position >= duration - 0.05 { return 0 }
        return position
    }

    func retry() {
        guard let url else { return }
        open(url, startAt: recoveryPosition, autoplay: requestedPlayback, systemDisplay: false)
    }

    func useSystemDisplay() {
        guard !usesSystemDisplay, let item = player.currentItem, let url else { return }
        if item.status == .failed || (errorText != nil && item.status != .readyToPlay) {
            open(url, startAt: recoveryPosition, autoplay: requestedPlayback, systemDisplay: true)
            return
        }
        detachOutput()
        usesSystemDisplay = true
        errorText = nil
        beginWaiting("正在等待系统播放器显示画面…")
        if pendingSeek != nil || recoveryPosition != currentTime { seek(to: recoveryPosition) }
        else { applyPlaybackIntent() }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, let item = player.currentItem else { return }
        let end = item.duration.seconds
        let target = end.isFinite && end > 0 ? min(max(0, seconds), end) : max(0, seconds)
        currentTime = target
        guard item.status == .readyToPlay else { pendingSeek = target; return }
        pendingSeek = nil
        let token = UUID()
        seeking = token
        if !usesSystemDisplay, errorText == nil {
            beginWaiting("正在定位视频画面…")
        }
        let time = CMTime(seconds: target, preferredTimescale: 600)
        // A small tolerance allows efficient seeks near sync samples in long-GOP HEVC files.
        let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
        item.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak item] _ in
            DispatchQueue.main.async {
                guard let self, let item, self.seeking == token, self.player.currentItem === item else { return }
                self.seeking = nil
                self.foregroundSeconds = 0
                self.output?.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
                self.applyPlaybackIntent()
            }
        }
    }

    private func applyPlaybackIntent() {
        guard errorText == nil, seeking == nil, player.currentItem?.status == .readyToPlay else { return }
        if requestedPlayback {
            player.play()
        } else {
            player.pause()
            #if targetEnvironment(simulator)
            requestPausedStill()
            #endif
        }
    }

    func togglePlay() {
        let preparing = player.currentItem?.status != .readyToPlay || seeking != nil
        let running = preparing ? requestedPlayback : player.timeControlStatus != .paused
        if running { pause() } else { play() }
    }
    func play() {
        #if targetEnvironment(simulator)
        cancelPausedStill()
        #endif
        requestedPlayback = true
        applyPlaybackIntent()
    }
    func pause() {
        requestedPlayback = false
        player.pause()
        #if targetEnvironment(simulator)
        requestPausedStill()
        #endif
    }

    #if targetEnvironment(simulator)
    private func cancelPausedStill() {
        stillTask?.cancel()
        stillTask = nil
        stillRequest = nil
        pendingStill = nil
    }

    /// On Simulator, AVPlayerItemVideoOutput can produce incorrect chroma for a paused
    /// local H.264 frame in both NV12 and BGRA. Read just that frame independently.
    private func requestPausedStill() {
        guard !requestedPlayback, !usesSystemDisplay, stillRequest == nil,
              errorText == nil, pendingSeek == nil, seeking == nil, let track = localAVCTrack,
              let item = player.currentItem, item.status == .readyToPlay else { return }
        let time = item.currentTime()
        guard time.isNumeric else { return }
        let asset = item.asset
        let request = UUID()
        stillRequest = request
        stillTask = Task.detached(priority: .userInitiated) { [weak self] in
            let frame = await Self.readStill(asset: asset, track: track, at: time)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.stillRequest == request else { return }
                self.stillTask = nil
                self.pendingStill = frame
                if frame == nil { self.stillRequest = nil } // Resume normal video output on failure.
            }
        }
    }

    private static func readStill(asset: AVAsset, track: AVAssetTrack, at time: CMTime) async -> CVPixelBuffer? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        // Include the preceding sample interval: the pause rarely lands exactly on a PTS.
        let lookback = CMTime(seconds: 0.5, preferredTimescale: 600)
        let start = CMTimeMaximum(.zero, CMTimeSubtract(time, lookback))
        reader.timeRange = CMTimeRange(start: start, end: CMTimeAdd(time, lookback))
        return await withTaskCancellationHandler {
            guard !Task.isCancelled, reader.startReading() else { return nil }
            defer { reader.cancelReading() }
            var preceding: CVPixelBuffer?
            for _ in 0..<256 {
                guard !Task.isCancelled, let sample = output.copyNextSampleBuffer(),
                      let image = CMSampleBufferGetImageBuffer(sample) else { break }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if CMTimeCompare(pts, time) > 0 { return preceding ?? image }
                preceding = image
                let duration = CMSampleBufferGetDuration(sample)
                if duration.isNumeric, CMTimeCompare(CMTimeAdd(pts, duration), time) > 0 { return image }
            }
            return preceding
        } onCancel: {
            reader.cancelReading()
        }
    }
    #endif

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    private func tearDownItem() {
        itemBag.removeAll()
        trackInspection?.cancel()
        trackInspection = nil
        #if targetEnvironment(simulator)
        cancelPausedStill()
        localAVCTrack = nil
        #endif
        startupTimer?.invalidate()
        startupTimer = nil
        seeking = nil
        pendingSeek = nil
        player.pause()
        detachOutput()
        player.replaceCurrentItem(with: nil)
    }

    func stop() {
        tearDownItem()
        url = nil
        videoGeneration = UUID()
        hasPresentedVideo = false
        startupMessage = nil
        errorText = nil
        requestedPlayback = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
