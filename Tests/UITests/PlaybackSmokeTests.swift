import AVFoundation
import Metal
import UIKit
import XCTest

final class PlaybackSmokeTests: XCTestCase {
    private let brokenClip = "VRPlaySmoke_Invalid"

    @MainActor
    func testH264DisplaysChangingFramesAndBothEyes() throws {
        try verifySingleAndSplitPlayback(of: "VRPlayColor_360_LR")
    }

    @MainActor
    func test8KMain10VideoDisplaysChangingFrames() throws {
        try verifySingleAndSplitPlayback(of: "VRPlay_8K_Main10_360_LR")
    }

    @MainActor
    func testSaturatedH264MatchesSystemDecodedEyesInBothColorPhases() async throws {
        let title = "VRPlaySmoke_360_LR"
        // Decode the test bundle's copy directly in XCTest, independently of the player and Metal.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: title, withExtension: "mp4"))
        let references = try await decodedPhases(of: url)
        XCTAssertEqual(references.map { $0.left.dominant }, [.red, .green])
        for pair in references {
            XCTAssertGreaterThan(pair.left.distance(from: pair.right), 60, "The eyes must remain distinguishable.")
        }

        try withPausedSplit(of: title) { center in
            try waitForColors("both paused eyes matching the same system-decoded frame") { shot in
                let left = try self.rgb(in: shot, at: 0.25)
                let right = try self.rgb(in: shot, at: 0.75)
                return references.contains { $0.matches(left: left, right: right) }
            }

            // Also verify both phases while the split player is running. Simulator decoders can
            // decode the right eye of this particular saturated AVC clip differently in each phase.
            center.tap()
            var seen = Set<Int>()
            try waitForColors("both system-decoded color phases during split playback") { shot in
                let left = try self.rgb(in: shot, at: 0.25)
                let right = try self.rgb(in: shot, at: 0.75)
                if let phase = references.firstIndex(where: { $0.matches(left: left, right: right) }) {
                    seen.insert(phase)
                }
                return seen.count == 2
            }
        }
    }

    @MainActor
    private func verifySingleAndSplitPlayback(of title: String) throws {
        try withPausedSplit(of: title) { _ in
            try waitForColors("red or green left eye and blue right eye") { shot in
                let left = try self.rgb(in: shot, at: 0.25).dominant
                let right = try self.rgb(in: shot, at: 0.75).dominant
                return (left == .red || left == .green) && right == .blue
            }
        }
    }

    @MainActor
    private func withPausedSplit(of title: String, verify: (XCUICoordinate) throws -> Void) throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "A Metal device is required to test playback.")
        let app = XCUIApplication()
        app.launch()
        try openClip(title, in: app)

        // Measuring two frames on the live screen also catches a frozen first frame.
        try waitForChangingLeftEye()

        // The toolbar auto-hides during playback. Pause the confirmed moving clip so
        // its split button stays visible between XCTest resolving it and sending the tap.
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.doubleTap()
        let split = app.buttons["playback.split"]
        if !split.isHittable { center.tap() }
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.tap()
        defer {
            // Exit split mode so its global preference does not affect the next run.
            center.doubleTap()
        }
        try verify(center)
    }

    @MainActor
    private func waitForChangingLeftEye() throws {
        var sawRed = false
        var sawGreen = false
        try waitForColors("changing single-eye video") { shot in
            let color = try self.rgb(in: shot, at: 0.5).dominant
            sawRed = sawRed || color == .red
            sawGreen = sawGreen || color == .green
            return sawRed && sawGreen
        }
    }

    @MainActor
    private func waitForColors(_ description: String, matches: (XCUIScreenshot) throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(25)
        repeat {
            let shot = XCUIScreen.main.screenshot()
            if try matches(shot) { return }
            if Date() >= deadline {
                let attachment = XCTAttachment(screenshot: shot)
                attachment.name = "Expected " + description
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTFail("Did not display " + description)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while true
    }

    @MainActor
    func testInvalidVideoShowsAnErrorAndCanClose() throws {
        let app = XCUIApplication()
        app.launch()
        try openClip(brokenClip, in: app)
        XCTAssertTrue(app.staticTexts["playback.error"].waitForExistence(timeout: 25))
        let close = app.buttons["playback.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(clipButton(brokenClip, in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func clipButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    @MainActor
    private func openClip(_ title: String, in app: XCUIApplication) throws {
        let row = clipButton(title, in: app)
        guard row.waitForExistence(timeout: 10) else {
            throw NSError(domain: "VRPlayUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing \(title) in Documents. Run bash scripts/test-playback.sh to stage the test clips."
            ])
        }
        row.tap()
    }

    private enum Color { case red, green, blue, other }

    private struct RGB {
        let red: Int
        let green: Int
        let blue: Int

        init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            self.red = Int(red)
            self.green = Int(green)
            self.blue = Int(blue)
        }

        var dominant: Color {
            if red > 100 && red > 2 * max(green, blue) { return .red }
            if green > 100 && green > 2 * max(red, blue) { return .green }
            if blue > 100 && blue > 2 * max(red, green) { return .blue }
            return .other
        }

        func distance(from other: RGB) -> Int {
            max(abs(red - other.red), max(abs(green - other.green), abs(blue - other.blue)))
        }
    }

    private struct EyePair {
        let left: RGB
        let right: RGB

        func matches(left actualLeft: RGB, right actualRight: RGB) -> Bool {
            left.distance(from: actualLeft) <= 20 && right.distance(from: actualRight) <= 20
        }
    }

    private func decodedPhases(of url: URL) async throws -> [EyePair] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let track = try XCTUnwrap(tracks.first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw referenceError("Cannot attach BGRA output.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? referenceError("Cannot start decoder.") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let times = [CMTime.zero, CMTime(value: 2, timescale: 1)]
        var samples: [EyePair] = []
        while samples.count < times.count, let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard CMTimeCompare(pts, times[samples.count]) == 0 else { continue }
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                throw referenceError("Cannot read system-decoded BGRA frame.")
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let width = CVPixelBufferGetWidth(buffer)
            let row = (CVPixelBufferGetHeight(buffer) / 2) * CVPixelBufferGetBytesPerRow(buffer)
            func eye(at x: Int) -> RGB {
                let i = row + 4 * x
                return RGB(base[i + 2], base[i + 1], base[i])
            }
            samples.append(EyePair(left: eye(at: width / 4), right: eye(at: 3 * width / 4)))
        }
        guard samples.count == times.count else {
            throw reader.error ?? referenceError("Missing a reference frame at 0 or 2 seconds.")
        }
        return samples
    }

    private func referenceError(_ description: String) -> NSError {
        NSError(domain: "VRPlayUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: description])
    }

    @MainActor
    private func rgb(in screenshot: XCUIScreenshot, at fraction: CGFloat) throws -> RGB {
        // UIImage.draw applies the screenshot's orientation metadata (landscape playback).
        let size = CGSize(width: 80, height: 40)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            screenshot.image.draw(in: CGRect(origin: .zero, size: size))
        }
        let image = try XCTUnwrap(upright.cgImage)
        let center = CGRect(x: size.width * fraction - 4, y: size.height * 0.5 - 3, width: 8, height: 6)
        let crop = try XCTUnwrap(image.cropping(to: center))
        var pixel = [UInt8](repeating: 0, count: 4)
        // RGBA regardless of the source screenshot's byte order or color space.
        try pixel.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            let ctx = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
            ctx.interpolationQuality = .high
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return RGB(pixel[0], pixel[1], pixel[2])
    }
}
