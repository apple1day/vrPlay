import Metal
import UIKit
import XCTest

final class PlaybackSmokeTests: XCTestCase {
    private let workingClip = "VRPlaySmoke_360_LR"
    private let brokenClip = "VRPlaySmoke_Invalid"

    func testChangingVideoPixelsAreVisibleInThePlayer() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil,
                      "This simulator has no Metal device for the GPU playback test.")
        let app = XCUIApplication()
        app.launch()
        try openClip(workingClip, in: app)

        // The left eye alternates between red and green every two seconds.
        // Measuring two frames on the live screen also catches a frozen first frame.
        let deadline = Date().addingTimeInterval(25)
        var sawRed = false
        var sawGreen = false
        var lastShot = XCUIScreen.main.screenshot()
        repeat {
            lastShot = XCUIScreen.main.screenshot()
            let color = try centerColor(of: lastShot)
            sawRed = sawRed || (color.red > 100 && color.red > 2 * color.green && color.red > 2 * color.blue)
            sawGreen = sawGreen || (color.green > 100 && color.green > 2 * color.red && color.green > 2 * color.blue)
            if sawRed && sawGreen { return }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline

        let attachment = XCTAttachment(screenshot: lastShot)
        attachment.name = "Player when expected colors did not appear"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Expected changing video pixels. Red seen: \(sawRed), green seen: \(sawGreen).")
    }

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

    private func clipButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func openClip(_ title: String, in app: XCUIApplication) throws {
        let row = clipButton(title, in: app)
        guard row.waitForExistence(timeout: 10) else {
            throw NSError(domain: "VRPlayUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing \(title) in Documents. Run bash scripts/test-playback.sh to stage the test clips."
            ])
        }
        row.tap()
    }

    private func centerColor(of screenshot: XCUIScreenshot) throws -> (red: Int, green: Int, blue: Int) {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let center = CGRect(x: CGFloat(image.width) * 0.35, y: CGFloat(image.height) * 0.35,
                            width: CGFloat(image.width) * 0.30, height: CGFloat(image.height) * 0.30)
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
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}
