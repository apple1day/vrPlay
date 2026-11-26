import Foundation

/// 投影方式
enum Projection: String, CaseIterable, Identifiable, Codable {
    case flat          // 平面 / 虚拟影院
    case sphere360     // 360° 球面（等距柱状投影）
    case hemisphere180 // VR180 半球

    var id: String { rawValue }
    var title: String {
        switch self {
        case .flat: return "平面 / 影院"
        case .sphere360: return "360° 球面"
        case .hemisphere180: return "VR180 半球"
        }
    }
}

/// 立体封装方式
enum StereoLayout: String, CaseIterable, Identifiable, Codable {
    case mono        // 单眼 / 2D
    case sideBySide  // 左右（左半=左眼）
    case topBottom   // 上下（上半=左眼）

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mono: return "2D"
        case .sideBySide: return "左右 SBS"
        case .topBottom: return "上下 TB"
        }
    }
}

/// 输出方式
enum DisplayMode: String, CaseIterable, Identifiable, Codable {
    case single // 单屏（只取左眼，触摸/陀螺仪看全景）
    case split  // VR 分屏（Cardboard）

    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: return "单屏"
        case .split: return "VR 分屏"
        }
    }
}

struct VRSettings: Codable, Equatable {
    // —— 内容参数（每个视频单独记忆）——
    var projection: Projection = .sphere360
    var layout: StereoLayout = .mono
    var swapEyes = false
    var flatScale: Float = 1.0

    // —— 观看参数（全局共用）——
    var displayMode: DisplayMode = .single
    var gyroEnabled = true
    var fov: Float = 90            // 垂直视场角（度）
    var distortionEnabled = true
    var k1: Float = 0.15           // 桶形畸变系数
    var k2: Float = 0.05
    var lensOffset: Float = 0.0    // 镜片中心水平偏移（-0.3 ~ 0.3，正=靠近鼻梁）
    var zoom: Float = 1.0
}

/// 持久化：内容参数按文件记忆，观看参数全局记忆
enum SettingsStore {
    private static let globalKey = "vr.viewer.global"

    private static func name(for url: URL) -> String {
        url.isFileURL ? url.lastPathComponent : url.absoluteString
    }
    private static func key(for url: URL) -> String { "vr.item." + name(for: url) }
    private static func posKey(for url: URL) -> String { "vr.pos." + name(for: url) }

    private static func decode(_ key: String) -> VRSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(VRSettings.self, from: data)
    }

    static func load(for url: URL) -> VRSettings? {
        guard var s = decode(key(for: url)) else { return nil }
        if let g = decode(globalKey) { applyViewer(from: g, to: &s) }
        return s
    }

    static func viewerDefaults() -> VRSettings? { decode(globalKey) }

    static func save(_ s: VRSettings, for url: URL) {
        if let d = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(d, forKey: key(for: url))
            UserDefaults.standard.set(d, forKey: globalKey)
        }
    }

    static func applyViewer(from g: VRSettings, to s: inout VRSettings) {
        s.displayMode = g.displayMode
        s.gyroEnabled = g.gyroEnabled
        s.fov = g.fov
        s.distortionEnabled = g.distortionEnabled
        s.k1 = g.k1
        s.k2 = g.k2
        s.lensOffset = g.lensOffset
        s.zoom = g.zoom
    }

    static func position(for url: URL) -> Double {
        UserDefaults.standard.double(forKey: posKey(for: url))
    }
    static func savePosition(_ t: Double, for url: URL) {
        UserDefaults.standard.set(t, forKey: posKey(for: url))
    }
}
