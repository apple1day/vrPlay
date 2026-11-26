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

    static func read(from url: URL) -> MP4SpatialMetadata? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let fileSize = try? fh.seekToEnd() else { return nil }

        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try? fh.seek(toOffset: offset)
            guard let head = try? fh.read(upToCount: 16), head.count >= 8 else { break }
            let b = [UInt8](head)
            var size = UInt64(be32(b, 0))
            let type = fourcc(b, 4)
            var headerLen: UInt64 = 8
            if size == 1 {
                guard b.count >= 16 else { break }
                size = be64(b, 8); headerLen = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= headerLen else { break }

            if type == "moov" {
                guard size <= 128 * 1024 * 1024 else { return nil }
                try? fh.seek(toOffset: offset + headerLen)
                guard let body = try? fh.read(upToCount: Int(size - headerLen)) else { return nil }
                let bytes = [UInt8](body)
                var result = MP4SpatialMetadata()
                parse(bytes, 0, bytes.count, &result)
                return (result.projection != nil || result.layout != nil) ? result : nil
            }
            offset += size
        }
        return nil
    }

    private static func parse(_ b: [UInt8], _ start: Int, _ end: Int, _ r: inout MP4SpatialMetadata) {
        var p = start
        while p + 8 <= end {
            var size = Int(be32(b, p))
            let type = fourcc(b, p + 4)
            var hl = 8
            if size == 1 {
                guard p + 16 <= end else { return }
                size = Int(be64(b, p + 8)); hl = 16
            } else if size == 0 {
                size = end - p
            }
            guard size >= hl, p + size <= end else { return }
            let bs = p + hl, be = p + size

            switch type {
            case "trak", "mdia", "minf", "stbl", "sv3d", "proj":
                parse(b, bs, be, &r)
            case "stsd":
                parseSampleEntries(b, bs + 8, be, &r)
            case "st3d":
                if bs + 5 <= be {
                    switch b[bs + 4] {
                    case 0: r.layout = .mono
                    case 1: r.layout = .topBottom
                    case 2: r.layout = .sideBySide
                    default: break
                    }
                }
            case "equi":
                if bs + 20 <= be {
                    let l = Double(be32(b, bs + 12)), rr = Double(be32(b, bs + 16))
                    let coverage = 1.0 - (l + rr) / 4294967296.0
                    r.projection = coverage < 0.75 ? .hemisphere180 : .sphere360
                }
            default: break
            }
            p += size
        }
    }

    private static func parseSampleEntries(_ b: [UInt8], _ start: Int, _ end: Int, _ r: inout MP4SpatialMetadata) {
        var p = start
        while p + 8 <= end {
            let size = Int(be32(b, p))
            let type = fourcc(b, p + 4)
            guard size >= 8, p + size <= end else { return }
            if videoEntries.contains(type), size > 8 + 78 {
                parse(b, p + 8 + 78, p + size, &r)
            }
            p += size
        }
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }
    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
        (UInt64(be32(b, i)) << 32) | UInt64(be32(b, i + 4))
    }
    private static func fourcc(_ b: [UInt8], _ i: Int) -> String {
        guard i + 4 <= b.count else { return "" }
        return String(bytes: b[i..<(i + 4)], encoding: .isoLatin1) ?? ""
    }
}
