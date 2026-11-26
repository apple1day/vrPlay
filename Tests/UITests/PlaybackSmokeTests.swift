import Metal
import UIKit
import XCTest

final class PlaybackSmokeTests: XCTestCase {
    private let workingClip = "VRPlaySmoke_360_LR"
    private let brokenClip = "VRPlaySmoke_Invalid"

    @MainActor
    func testChangingVideoPixelsAreVisibleInThePlayer() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil,
                      "This simulator has no Metal device for the GPU playback test.")
        let app = XCUIApplication()
        app.launch()
        try openClip(workingClip, in: app)

        // The left eye alternates between red and green every two seconds.
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
        try waitForColors("red or green left eye and blue right eye") { shot in
            let left = try self.color(in: shot, at: 0.25)
            let right = try self.color(in: shot, at: 0.75)
            return (left == .red || left == .green) && right == .blue
        }
    }

    @MainActor
    func test8KMain10VideoDisplaysChangingFrames() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil,
                      "This simulator has no Metal device for the GPU playback test.")
        let app = XCUIApplication()
        app.launch()
        try openClip("VRPlay_8K_Main10_360_LR", in: app)
        try waitForChangingLeftEye()
    }

    @MainActor
    private func waitForChangingLeftEye() throws {
        var sawRed = false
        var sawGreen = false
        try waitForColors("changing single-eye video") { shot in
            let color = try self.color(in: shot, at: 0.5)
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

    @MainActor
    private func color(in screenshot: XCUIScreenshot, at fraction: CGFloat) throws -> Color {
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
        let red = Int(pixel[0]), green = Int(pixel[1]), blue = Int(pixel[2])
        if red > 100 && red > 2 * max(green, blue) { return .red }
        if green > 100 && green > 2 * max(red, blue) { return .green }
        if blue > 100 && blue > 2 * max(red, green) { return .blue }
        return .other
    }
}
