import Foundation
import CoreGraphics

struct DetectedFormat {
    var projection: Projection
    var layout: StereoLayout
    var source: String   // 识别依据，显示在设置页
}

/// 自动识别顺序：MP4 元数据(st3d/sv3d) → 文件名关键字 → 分辨率比例。
/// 自动识别只是默认值，设置页里始终可以手动覆盖。
enum FormatDetector {

    static func detect(url: URL, videoSize: CGSize?) -> DetectedFormat {
        var proj: Projection?
        var layout: StereoLayout?
        var sources: [String] = []

        // 1. 元数据
        if url.isFileURL, let meta = MP4SpatialMetadata.read(from: url) {
            if let p = meta.projection { proj = p }
            if let l = meta.layout { layout = l }
            if proj != nil || layout != nil { sources.append("文件元数据") }
        }

        // 2. 文件名
        let nameHint = fromFilename(url)
        if proj == nil, let p = nameHint.projection { proj = p; sources.append("文件名") }
        if layout == nil, let l = nameHint.layout { layout = l; if !sources.contains("文件名") { sources.append("文件名") } }

        // 3. 比例兜底
        var ratio: Double?
        if let s = videoSize, s.width > 0, s.height > 0 { ratio = Double(s.width / s.height) }

        if proj == nil {
            proj = guessProjection(layout: layout, ratio: ratio)
            sources.append("分辨率比例")
        }
        if layout == nil {
            layout = guessLayout(projection: proj!, ratio: ratio)
            if !sources.contains("分辨率比例") { sources.append("分辨率比例") }
        }
        return DetectedFormat(projection: proj!, layout: layout!, source: sources.joined(separator: " + "))
    }

    // MARK: 文件名

    private static func fromFilename(_ url: URL) -> (projection: Projection?, layout: StereoLayout?) {
        var base = url.deletingPathExtension().lastPathComponent.lowercased()
        if !url.isFileURL && base.isEmpty { base = url.host?.lowercased() ?? "" }
        let tokens = base.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        let sbs: Set<String> = ["lr", "sbs", "3dh", "hsbs", "fsbs", "leftright", "sidebyside"]
        let tb: Set<String> = ["tb", "ou", "3dv", "topbottom", "overunder", "htb", "hou"]

        var proj: Projection?
        var layout: StereoLayout?

        for t in tokens {
            // 跳过 360p / 720p 这类分辨率标记，避免误判成 360° 视频
            if t.hasSuffix("p"), Int(t.dropLast()) != nil { continue }

            if t.hasPrefix("180") || t == "vr180" { proj = .hemisphere180 }
            else if t.hasPrefix("360") || t == "vr360" || t == "equirect" || t == "equirectangular" { proj = .sphere360 }
            else if t == "flat" || t == "2d" { proj = .flat; layout = layout ?? .mono }

            if sbs.contains(t) { layout = .sideBySide }
            else if tb.contains(t) { layout = .topBottom }
            else if t.hasPrefix("180") || t.hasPrefix("360") {   // 例如 180lr、360tb
                if t.hasSuffix("lr") || t.hasSuffix("sbs") { layout = .sideBySide }
                if t.hasSuffix("tb") || t.hasSuffix("ou") { layout = .topBottom }
            }
            if t == "mono" { layout = .mono }
        }
        return (proj, layout)
    }

    // MARK: 比例启发

    private static func guessProjection(layout: StereoLayout?, ratio: Double?) -> Projection {
        guard let r = ratio else { return .sphere360 }
        switch layout {
        case .sideBySide?:
            if r >= 3.5 { return .sphere360 }
            if r > 1.8 && r < 2.2 { return .hemisphere180 }
            return .flat
        case .topBottom?:
            if r > 0.9 && r < 1.1 { return .sphere360 }
            if r < 0.6 { return .hemisphere180 }
            return .flat
        case .mono?:
            if r > 1.9 && r < 2.1 { return .sphere360 }
            return .flat
        case nil:
            if r >= 3.5 { return .sphere360 }               // 4:1 → 360 SBS
            if r > 1.9 && r < 2.1 { return .sphere360 }     // 2:1 → 360 单眼（也可能是 VR180 SBS，需手动切）
            if r > 0.9 && r < 1.1 { return .sphere360 }     // 1:1 → 360 TB
            return .flat
        }
    }

    private static func guessLayout(projection: Projection, ratio: Double?) -> StereoLayout {
        guard let r = ratio else { return .mono }
        switch projection {
        case .sphere360:
            if r >= 3.5 { return .sideBySide }
            if r > 0.9 && r < 1.1 { return .topBottom }
            return .mono
        case .hemisphere180:
            if r >= 1.8 { return .sideBySide }
            if r <= 0.6 { return .topBottom }
            return .mono
        case .flat:
            if r >= 3.0 { return .sideBySide }   // 32:9
            if r <= 0.95 { return .topBottom }   // 16:18
            return .mono
        }
    }
}

// MARK: - 极简 MP4 box 解析（st3d / sv3d）

struct MP4SpatialMetadata {
    var projection: Projection?
    var layout: StereoLayout?

    private static let videoEntries: Set<String> = [
        "avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "av01", "vp09", "mp4v",
        "apch", "apcn", "apcs", "apco", "ap4h"
    ]

    /// Only read box headers and the few bytes describing the projection. A large
    /// mdat (media) or moov (sample tables) never needs to be copied into memory.
    static func read(from url: URL) -> MP4SpatialMetadata? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd() else { return nil }
        var remainingBoxes = 16_384
        var result = MP4SpatialMetadata()
        visit(file, start: 0, end: length, depth: 0, budget: &remainingBoxes, result: &result)
        return (result.projection != nil || result.layout != nil) ? result : nil
    }

    private static func bytes(_ file: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        do {
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else { return nil }
            return Array(data)
        } catch {
            return nil
        }
    }

    private static func integer(_ data: ArraySlice<UInt8>) -> UInt64 {
        data.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func visit(_ file: FileHandle, start: UInt64, end: UInt64, depth: Int,
                              budget: inout Int, result: inout MP4SpatialMetadata) {
        guard depth < 16 else { return }
        var offset = start
        while offset <= end, end - offset >= 8, budget > 0, !Task.isCancelled {
            budget -= 1
            guard let header = bytes(file, at: offset, count: 8) else { return }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var size = integer(header[0..<4])
            var headerSize: UInt64 = 8
            if size == 1 {
                guard end - offset >= 16,
                      let extended = bytes(file, at: offset + 8, count: 8) else { return }
                size = integer(extended[...])
                headerSize = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= headerSize, size <= end - offset else { return }
            let body = offset + headerSize
            let next = offset + size
            let payload = next - body
            switch type {
            case "moov", "trak", "mdia", "minf", "stbl", "sv3d", "proj":
                visit(file, start: body, end: next, depth: depth + 1, budget: &budget, result: &result)
            case "stsd" where payload >= 8:
                visit(file, start: body + 8, end: next, depth: depth + 1, budget: &budget, result: &result)
            case "st3d" where payload >= 5:
                if let mode = bytes(file, at: body + 4, count: 1)?.first {
                    switch mode {
                    case 0: result.layout = .mono
                    case 1: result.layout = .topBottom
                    case 2: result.layout = .sideBySide
                    default: break
                    }
                }
            case "equi" where payload >= 20:
                if let bounds = bytes(file, at: body + 12, count: 8) {
                    let cropped = integer(bounds[0..<4]) + integer(bounds[4..<8])
                    result.projection = Double(cropped) / 4294967296.0 > 0.25 ? .hemisphere180 : .sphere360
                }
            case _ where videoEntries.contains(type) && payload >= 78:
                visit(file, start: body + 78, end: next, depth: depth + 1, budget: &budget, result: &result)
            default: break
            }
            offset = next
        }
    }
}
