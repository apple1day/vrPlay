import Foundation
import Combine
import UIKit
import simd

/// 一次播放会话：播放核心 + 观看设置 + 视角状态。渲染器和 UI 都读它。
/// 注意：本类的读写都发生在主线程（MTKView 的 draw 默认也在主线程）。
final class PlayerSession: ObservableObject {
    let player = PlayerCore()
    let tracker = HeadTracker()

    @Published var settings = VRSettings() {
        didSet {
            guard settings != oldValue else { return }
            if Self.tracking(settings) != Self.tracking(oldValue) { recenter() }
            if item != nil && (settings.projection != oldValue.projection || settings.layout != oldValue.layout) {
                hasSavedSettings = true
                detectionTask?.cancel()
            }
            persist()
        }
    }
    @Published private(set) var detectionNote = ""

    private(set) var item: VideoItem?
    private var hasSavedSettings = false
    private var detectionTask: Task<Void, Never>?
    private var detectionID = UUID()
    private var inverseReferenceHead: simd_float3x3?
    private var referenceOrientation: UIInterfaceOrientation?
    private var relativeHead = matrix_identity_float3x3
    private var yawOffset: Float = 0
    private var pitch: Float = 0
    private var bag = Set<AnyCancellable>()

    // MARK: 生命周期

    func open(_ item: VideoItem) {
        bag.removeAll()
        detectionTask?.cancel()
        detectionNote = ""
        self.item = nil   // 先置空，避免下面赋值触发持久化

        if let saved = SettingsStore.load(for: item.url) {
            hasSavedSettings = true
            settings = saved
        } else {
            hasSavedSettings = false
            var defaults = VRSettings()
            if let viewer = SettingsStore.viewerDefaults() { SettingsStore.applyViewer(from: viewer, to: &defaults) }
            settings = defaults
        }
        self.item = item
        recenter()

        player.load(url: item.url, startAt: SettingsStore.position(for: item.url))
        tracker.start()

        player.$videoSize
            .filter { $0.width > 0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                guard let self, !self.hasSavedSettings else { return }
                self.applyDetection(size: size)
            }
            .store(in: &bag)

        // 每 5 秒记一次播放位置
        player.$currentTime
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] t in self?.savePosition(t) }
            .store(in: &bag)
    }

    func close() {
        detectionTask?.cancel()
        savePosition(player.currentTime)
        item = nil
        tracker.stop()
        player.stop()
        bag.removeAll()
    }

    private func savePosition(_ t: Double) {
        guard let item else { return }
        let d = player.duration
        SettingsStore.savePosition((d > 0 && t > d - 5) ? 0 : t, for: item.url)
    }

    private func persist() {
        guard let item else { return }
        SettingsStore.save(settings, for: item.url)
    }

    // MARK: 格式识别

    func autoDetect() {
        applyDetection(size: player.videoSize == .zero ? nil : player.videoSize)
    }

    private func applyDetection(size: CGSize?) {
        guard let item else { return }
        detectionTask?.cancel()
        let id = UUID()
        detectionID = id
        let url = item.url
        detectionTask = Task.detached(priority: .utility) { [weak self] in
            let format = FormatDetector.detect(url: url, videoSize: size)
            guard !Task.isCancelled else { return }
            await self?.apply(format, for: url, id: id)
        }
    }

    @MainActor private func apply(_ format: DetectedFormat, for url: URL, id: UUID) {
        guard item?.url == url, detectionID == id, detectionTask?.isCancelled == false else { return }
        detectionTask = nil
        detectionNote = "识别依据：\(format.source)"
        var updated = settings
        updated.projection = format.projection
        updated.layout = format.layout
        updated.swapEyes = false
        settings = updated
    }

    // MARK: 视角

    private static func tracking(_ s: VRSettings) -> Bool {
        // 平面 + 单屏时陀螺仪会让屏幕“跑掉”，所以忽略陀螺仪
        s.gyroEnabled && !(s.projection == .flat && s.displayMode == .single)
    }
    var trackingActive: Bool { Self.tracking(settings) }

    /// 单屏平面视频时不响应拖动
    var panAllowed: Bool { !(settings.projection == .flat && settings.displayMode == .single && !trackingActive) }

    func recenter() {
        inverseReferenceHead = nil
        relativeHead = matrix_identity_float3x3
        yawOffset = 0
        pitch = 0
    }

    func drag(dx: Float, dy: Float) {
        guard panAllowed else { return }
        yawOffset += dx * 0.005
        pitch = min(max(pitch + dy * 0.005, -1.5), 1.5)
    }

    func pinch(scale: Float) {
        guard scale > 0 else { return }
        settings.fov = min(max(settings.fov / scale, 40), 130)
    }

    static func interfaceOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .landscapeRight
    }

    /// 渲染器每帧调用
    func viewMatrix() -> simd_float4x4 {
        if trackingActive {
            let orientation = Self.interfaceOrientation()
            if let head = tracker.headRotation(orientation: orientation) {
                if let inverseReferenceHead, referenceOrientation == orientation {
                    relativeHead = inverseReferenceHead * head
                } else {
                    // Neutralize all three axes, including the tilt of a phone lying on a desk.
                    // Capture only the gyro baseline; keep any touch drag made before the first sample.
                    inverseReferenceHead = head.transpose
                    referenceOrientation = orientation
                    relativeHead = matrix_identity_float3x3
                }
            }
        }
        let rot = rotationY(yawOffset) * relativeHead * rotationX(pitch)
        return simd_float4x4(rotation: rot.transpose)   // 视图矩阵 = 相机旋转的逆
    }
}
