//
//  EnhancedCaptureScreenTests.swift
//  MetalToolBox
//
//  Display capture following its display (2.2.2): the size rule and the scan gate, then a
//  live stream of the main display re-configured to another size. The live test needs
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
/// A real stream of the main display: started at the display's size, re-configured to a
/// smaller one of another shape and back, as a resolution change does. The frames must
/// arrive in each new size — what a compositor laying out by the frame's size needs.
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
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording granted to the test runner (never prompted for)")

        let displayID = CGMainDisplayID()
        let recorder = Recorder()
        let screen = EnhancedCaptureScreen(delegate: recorder, displayId: displayID)
        defer { screen.stopCapture() }

        let bounds = CGDisplayBounds(displayID).size
        let native = ScreenStreamSize(width: Int(bounds.width), height: Int(bounds.height))
        screen.startCapture()
        let first = await waitForFrame(of: native, from: recorder)
        XCTAssertTrue(first, "no frame at the display's size \(native); last \(String(describing: recorder.last))")

        // As if the display went to a 16:9 mode: a size of another shape than the native one.
        let wide = ScreenStreamSize(width: 1280, height: 720)
        recorder.reset()
        let resized = await screen.displayDidChange(to: wide)
        XCTAssertTrue(resized)
        let arrivedWide = await waitForFrame(of: wide, from: recorder)
        XCTAssertTrue(arrivedWide, "frames did not follow to \(wide); last \(String(describing: recorder.last))")

        // The same size again changes nothing; back to the native size follows again.
        let unchanged = await screen.displayDidChange(to: wide)
        XCTAssertFalse(unchanged)
        recorder.reset()
        let restored = await screen.displayDidChange(to: native)
        XCTAssertTrue(restored)
        let arrivedNative = await waitForFrame(of: native, from: recorder)
        XCTAssertTrue(arrivedNative, "frames did not follow back to \(native); last \(String(describing: recorder.last))")
    }
}
#endif
