//
//  EnhancedCaptureScreenTests.swift
//  MetalToolBox
//
//  Display capture following its display (2.2.2) and at its pixel resolution (2.3.0): the
//  size rules and the scan gate, then live streams of the main display. The live test needs
//  Screen Recording already granted to the process running it; it never prompts, and
//  skips without it. Frames are read for their size only and never kept.
//

import XCTest
import CoreGraphics
import CoreMedia
@testable import EnhancedCaptureKit

final class ScreenStreamSizeTests: XCTestCase {

    private let laptop = ScreenStreamSize(width: 1512, height: 982)    // a 16:10-class built-in display
    private let wide = ScreenStreamSize(width: 1920, height: 1080)     // the same display set to 16:9

    func testADisplayOfANewShapeResizesItsStream() {
        XCTAssertEqual(ScreenStreamSize.resized(stream: laptop, display: wide), wide)
        XCTAssertEqual(ScreenStreamSize.resized(stream: wide, display: laptop), laptop)
    }

    func testTheSameSizeLeavesTheStreamAlone() {
        XCTAssertNil(ScreenStreamSize.resized(stream: laptop, display: laptop))
    }

    func testNoStreamMeansNothingToResize() {
        // A stream not started yet reads the display when it starts.
        XCTAssertNil(ScreenStreamSize.resized(stream: nil, display: wide))
    }

    func testADisplayWithNoSizeIsIgnored() {
        // Mid-reconfiguration a display can report nothing; the next scan reads it again.
        XCTAssertNil(ScreenStreamSize.resized(stream: laptop, display: ScreenStreamSize(width: 0, height: 0)))
        XCTAssertNil(ScreenStreamSize.resized(stream: laptop, display: ScreenStreamSize(width: 1920, height: 0)))
    }

    func testSizesDescribeThemselves() {
        XCTAssertEqual(wide.description, "1920×1080")
    }

    func testAStreamIsThePointSizeUnlessPixelsAreAskedFor() {
        let retina = ScreenDisplayGeometry(width: 1512, height: 982, pixelScale: 2)
        XCTAssertEqual(ScreenStreamSize(display: retina, atPixelResolution: false), laptop)
        XCTAssertEqual(ScreenStreamSize(display: retina, atPixelResolution: true), ScreenStreamSize(width: 3024, height: 1964))
        // A 16:9 mode on the same panel: its own pixels, so the shape follows too.
        let wideRetina = ScreenDisplayGeometry(width: 1920, height: 1080, pixelScale: 2)
        XCTAssertEqual(ScreenStreamSize(display: wideRetina, atPixelResolution: true), ScreenStreamSize(width: 3840, height: 2160))
    }

    func testANonRetinaOrUnknownScaleKeepsThePoints() {
        XCTAssertEqual(ScreenStreamSize(display: ScreenDisplayGeometry(width: 1920, height: 1080, pixelScale: 1), atPixelResolution: true), wide)
        XCTAssertEqual(ScreenStreamSize(display: ScreenDisplayGeometry(width: 1920, height: 1080, pixelScale: 0), atPixelResolution: true), wide)
    }

    func testAFractionalScaleRounds() {
        XCTAssertEqual(ScreenStreamSize(display: ScreenDisplayGeometry(width: 1001, height: 563, pixelScale: 1.5), atPixelResolution: true),
                       ScreenStreamSize(width: 1502, height: 845))
    }
}

final class ScreenScanGateTests: XCTestCase {

    func testAnIdleGateScansOnceAndStops() {
        var gate = ScreenScanGate()
        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.isScanning)
        XCTAssertFalse(gate.passEnded())
        XCTAssertFalse(gate.isScanning)
    }

    func testAChangeDuringAScanRunsOneMorePass() {
        var gate = ScreenScanGate()
        XCTAssertTrue(gate.request())
        // macOS posts several notifications during one mode change: they fold into ONE more pass.
        XCTAssertFalse(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.passEnded())     // the pass that reads the settled display
        XCTAssertTrue(gate.isScanning)
        XCTAssertFalse(gate.passEnded())
        XCTAssertFalse(gate.isScanning)
    }

    func testAChangeDuringTheExtraPassRunsAnother() {
        var gate = ScreenScanGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.passEnded())
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.passEnded())
        XCTAssertFalse(gate.passEnded())
        // Idle again: the next change starts a scan of its own.
        XCTAssertTrue(gate.request())
    }
}

#if os(macOS)
/// Real streams of the main display: started at the display's size, re-configured to a
/// smaller one of another shape and back, as a resolution change does — at the point size,
/// then at the pixel resolution. The frames must arrive in each new size: what a compositor
/// laying out by the frame's size needs.
final class EnhancedCaptureScreenLiveTests: XCTestCase {

    private final class Recorder: EnhancedCaptureScreenDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [ScreenStreamSize] = []

        func enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let size = ScreenStreamSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            lock.lock(); sizes.append(size); lock.unlock()
        }
        func enhancedCaptureScreenDidOutputAudioSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {}
        func enhancedCaptureScreen(_ screen: EnhancedCaptureScreen, didChangeState state: EnhancedCaptureSourceState) {}

        var last: ScreenStreamSize? { lock.lock(); defer { lock.unlock() }; return sizes.last }
        func reset() { lock.lock(); sizes.removeAll(); lock.unlock() }
    }

    /// Waits up to `seconds` for a frame of `size`.
    private func waitForFrame(of size: ScreenStreamSize, from recorder: Recorder, seconds: Double = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if recorder.last == size { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func testTheStreamFollowsADisplaySizeChange() async throws {
        try await followsADisplaySizeChange(atPixelResolution: false)
    }

    func testAtPixelResolutionTheStreamIsTheDisplaysPixelsAndFollowsToo() async throws {
        try await followsADisplaySizeChange(atPixelResolution: true)
    }

    /// The main display's pixels per point, read from its display mode — CoreGraphics, not
    /// the ScreenCaptureKit value the kit uses, so the test checks the kit against another source.
    private func modeScale(_ displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    private func followsADisplaySizeChange(atPixelResolution: Bool) async throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording granted to the test runner (never prompted for)")

        let displayID = CGMainDisplayID()
        let recorder = Recorder()
        var options = EnhancedCaptureScreen.Options()
        options.capturesAtPixelResolution = atPixelResolution
        let screen = EnhancedCaptureScreen(delegate: recorder, displayId: displayID, options: options)
        defer { screen.stopCapture() }

        let bounds = CGDisplayBounds(displayID).size
        let scale = modeScale(displayID)
        let display = ScreenDisplayGeometry(width: Int(bounds.width), height: Int(bounds.height), pixelScale: scale)
        let native = atPixelResolution
            ? ScreenStreamSize(width: Int((bounds.width * scale).rounded()), height: Int((bounds.height * scale).rounded()))
            : ScreenStreamSize(width: Int(bounds.width), height: Int(bounds.height))
        screen.startCapture()
        let first = await waitForFrame(of: native, from: recorder)
        XCTAssertTrue(first, "no frame at the display's size \(native); last \(String(describing: recorder.last))")

        // As if the display went to a 16:9 mode: a size of another shape than the native one,
        // on a Retina panel (2 pixels per point) — at pixel resolution its frames are 2560 × 1440,
        // whatever this Mac's own displays are.
        let wideDisplay = ScreenDisplayGeometry(width: 1280, height: 720, pixelScale: 2)
        // Written out, not computed by the rule under test.
        let wide = atPixelResolution ? ScreenStreamSize(width: 2560, height: 1440) : ScreenStreamSize(width: 1280, height: 720)
        recorder.reset()
        let resized = await screen.displayDidChange(to: wideDisplay)
        XCTAssertTrue(resized)
        let arrivedWide = await waitForFrame(of: wide, from: recorder)
        XCTAssertTrue(arrivedWide, "frames did not follow to \(wide); last \(String(describing: recorder.last))")

        // The same display again changes nothing; back to the native one follows again.
        let unchanged = await screen.displayDidChange(to: wideDisplay)
        XCTAssertFalse(unchanged)
        recorder.reset()
        let restored = await screen.displayDidChange(to: display)
        XCTAssertTrue(restored)
        let arrivedNative = await waitForFrame(of: native, from: recorder)
        XCTAssertTrue(arrivedNative, "frames did not follow back to \(native); last \(String(describing: recorder.last))")
    }
}
#endif
