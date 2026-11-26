import Foundation
import AVFoundation
import CoreVideo

// Run: xcrun swift /tmp/VRAssetProbe.swift Tests/Fixtures/VRPlaySmoke_360_LR.mp4
// Picture types below were read from this fixture with ffprobe. Decoder samples arrive in PTS order.
let times: [(Double, String)] = [(0, "I"), (0.25, "B"), (1, "P"), (2, "I"), (3, "P"),
                                  (4, "I"), (4.25, "B"), (5, "P"), (6, "I"), (6.25, "B"), (7, "P")]
func problem(_ message: String) -> NSError {
    NSError(domain: "VRAssetProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func sample(_ pb: CVPixelBuffer, at x: Int, _ y: Int) throws -> String {
    let format = CVPixelBufferGetPixelFormatType(pb)
    if format == kCVPixelFormatType_32BGRA, let raw = CVPixelBufferGetBaseAddress(pb) {
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let i = y * CVPixelBufferGetBytesPerRow(pb) + 4 * x
        return "RGB=(\(bytes[i+2]),\(bytes[i+1]),\(bytes[i]))"
    }
    guard (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
          CVPixelBufferGetPlaneCount(pb) == 2, let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
          let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else {
        throw problem("Unexpected format: \(String(format: "%08X", format))")
    }
    let luma = yBase.assumingMemoryBound(to: UInt8.self)[y * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + x]
    let c = cBase.assumingMemoryBound(to: UInt8.self)
    let i = (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(pb, 1) + (x / 2) * 2
    return "YUV=(\(luma),\(c[i]),\(c[i+1]))"
}

func run(_ url: URL, _ requested: OSType, _ label: String) throws {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else { throw problem("No video track") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: requested),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw problem("Cannot attach \(label) output") }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? problem("Cannot read \(label)") }
    var count = 0
    while let sb = output.copyNextSampleBuffer() {
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if t > 7.01 { break }
        guard let entry = times.first(where: { abs($0.0 - t) < 0.01 }) else { continue }
        guard let pb = CMSampleBufferGetImageBuffer(sb),
              CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { throw problem("Unreadable sample at \(t)") }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let a = try sample(pb, at: w / 4, h / 2), b = try sample(pb, at: 3 * w / 4, h / 2)
        let actual = String(format: "%08X", CVPixelBufferGetPixelFormatType(pb))
        print("VRPROBE \(label) fmt=0x\(actual) \(w)x\(h) pts=\(String(format: "%.2f", t)) \(entry.1) L.\(a) R.\(b)")
        count += 1
    }
    if reader.status == .failed { throw reader.error ?? problem("Decoder failed") }
    if reader.status == .reading { reader.cancelReading() }
    guard count == times.count else { throw problem("Missing samples for \(label): \(count)/\(times.count)") }
}
do {
    guard CommandLine.arguments.count == 2 else { throw problem("Expected fixture path") }
    let file = URL(fileURLWithPath: CommandLine.arguments[1])
    try run(file, kCVPixelFormatType_32BGRA, "BGRA")
    try run(file, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "NV12")
} catch {
    print("VRPROBE error: \(error.localizedDescription)")
    exit(1)
}
