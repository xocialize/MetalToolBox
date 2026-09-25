//
//  SectionEndTests.swift
//  MetalToolBox
//
//  Real playback of a clip whose every frame says which frame it is, so a test
//  can read exactly what a render loop would have put on screen: which frame a
//  section ends on, whether the out-point frame ever shows, and where a hold
//  lands (2.2.0).
//
//  The clip is written here, not shipped: eight bars, black or white, spell the
//  frame's index in binary. That survives H.264 and needs no fixture on disk,
//  unlike SectionPlaybackTests and PausePlaybackTests, which skip without theirs.
//

import XCTest
import AVFoundation
@testable import VideoPlayerKit

/// A 30 fps H.264 clip whose frame `i` carries `i` in eight bars (MSB first).
enum FrameCodedClip {
    static let fps: Int32 = 30
    static let width = 256
    static let height = 144
    private static let bars = 8

    /// Writes a clip of `frames` frames to a temporary file.
    static func make(frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-coded-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoMaxKeyFrameIntervalKey: 15,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for index in 0 ..< frames {
            while !input.isReadyForMoreMediaData { usleep(1_000) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw CocoaError(.fileWriteUnknown) }
            draw(index, into: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func draw(_ index: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let barWidth = width / bars
        for y in 0 ..< height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< width {
                let bit = (index >> (bars - 1 - x / barWidth)) & 1
                let value: UInt8 = bit == 1 ? 255 : 0
                row[x * 4] = value; row[x * 4 + 1] = value; row[x * 4 + 2] = value; row[x * 4 + 3] = 255
            }
        }
    }

    /// The index a decoded frame carries, read at each bar's centre.
    static func index(of buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let barWidth = CVPixelBufferGetWidth(buffer) / bars
        let row = base.advanced(by: (CVPixelBufferGetHeight(buffer) / 2) * rowBytes).assumingMemoryBound(to: UInt8.self)
        var index = 0
        for bar in 0 ..< bars {
            let x = bar * barWidth + barWidth / 2
            index = index << 1 | (row[x * 4 + 1] > 127 ? 1 : 0)
        }
        return index
    }
}

final class SectionEndTests: XCTestCase, VideoPlayerDelegate {

    private var laps = 0
    private var lap: XCTestExpectation?
    /// Runs inside the lap callback, as a sequencer deciding what follows would.
    private var onLap: (() -> Void)?

    func VideoPlayerBuffer(pixelBuffer: CVPixelBuffer?) {}

    func videoPlayerDidCompleteLoop(identifier: String) {
        laps += 1
        onLap?()
        lap?.fulfill()
    }

    /// What a render loop would present: `directBufferCheck()` at 120 Hz, each
    /// change of frame recorded.
    private final class Screen {
        private(set) var shown: [Int] = []
        private var timer: Timer?

        init(_ player: VideoPlayer) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                guard let self, let buffer = player.directBufferCheck() else { return }
                let index = FrameCodedClip.index(of: buffer)
                if self.shown.last != index { self.shown.append(index) }
            }
        }

        var current: Int? { shown.last }
        func stop() { timer?.invalidate() }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var clip: URL!

    override func setUpWithError() throws {
        clip = try FrameCodedClip.make(frames: 60)   // 2 s
        laps = 0
        onLap = nil
    }

    override func tearDown() {
        if let clip { try? FileManager.default.removeItem(at: clip) }
    }

    /// Frames 15 … 44 are the section [0.5, 1.5): 45 is the out-point.
    private let section = PlaybackSection(start: 0.5, duration: 1.0)

    /// The fix for a sequencer's hold: `.hold` ends ON the section's last
    /// frame, stays there, and a resume does not play on.
    func testHoldEndsOnTheLastFrameBeforeTheOutPoint() throws {
        let player = VideoPlayer(delegate: self, identifier: "hold-test")
        player.actionAtSectionEnd = .hold
        let screen = Screen(player)
        lap = expectation(description: "the section ends")
        player.play(url: clip, section: section)
        wait(for: [lap!], timeout: 10)

        spin(0.6)
        XCTAssertEqual(screen.current, 44, "held on \(screen.current ?? -1), shown \(screen.shown)")
        XCTAssertLessThan(screen.shown.max() ?? 99, 45, "the out-point frame showed: \(screen.shown)")
        XCTAssertTrue(player.hasFinishedSection)
        let clock = player.mediaTime
        spin(0.4)
        XCTAssertEqual(player.mediaTime, clock, accuracy: 0.001, "the clock moved after the section ended")

        player.resume()
        spin(0.5)
        XCTAssertEqual(screen.current, 44, "a resume played on past the out-point")
        XCTAssertEqual(player.mediaTime, clock, accuracy: 0.001)
        XCTAssertEqual(laps, 1, "a held section signals once")

        // The next load plays, and clears the finished state.
        player.play(url: clip, section: PlaybackSection(start: 0, duration: 0.5))
        XCTAssertFalse(player.hasFinishedSection)
        spin(0.3)
        XCTAssertLessThan(screen.current ?? 99, 15, "the next section did not start: \(screen.shown)")
        screen.stop()
        player.stopVideo()
    }

    /// `.hold` on a section that runs to the file's end: the end-of-item path.
    func testHoldAtTheFilesEndKeepsItsLastFrame() throws {
        let player = VideoPlayer(delegate: self, identifier: "hold-end-test")
        player.actionAtSectionEnd = .hold
        let screen = Screen(player)
        lap = expectation(description: "the file ends")
        player.play(url: clip, section: PlaybackSection(start: 1.2, duration: nil))
        wait(for: [lap!], timeout: 10)
        spin(0.5)
        XCTAssertEqual(screen.current, 59, "held on \(screen.current ?? -1), shown \(screen.shown)")
        XCTAssertEqual(laps, 1)
        screen.stop()
        player.stopVideo()
    }

    /// `.loop` (the default) still loops, and never shows the out-point frame.
    func testLoopNeverShowsTheOutPointFrame() throws {
        let player = VideoPlayer(delegate: self, identifier: "loop-test")
        let screen = Screen(player)
        player.play(url: clip, section: section)
        spin(3.6)
        XCTAssertGreaterThanOrEqual(laps, 2, "the section did not loop")
        XCTAssertEqual(screen.shown.max(), 44, "shown \(screen.shown)")
        let wraps = zip(screen.shown, screen.shown.dropFirst()).filter { $0 > $1 }
        XCTAssertFalse(wraps.isEmpty, "no lap went back to the start: \(screen.shown)")
        XCTAssertTrue(wraps.allSatisfy { $0.1 <= 16 }, "a lap restarted away from the in-point: \(wraps)")
        screen.stop()
        player.stopVideo()
    }

    /// Why `.hold` exists. A `.loop` lap seeks back to the section's start in
    /// the same turn it signals, so a sequencer that pauses when it has decided
    /// (after the callback returns, as Studio's editor did) freezes on the
    /// section's FIRST frame, not its last.
    func testALoopLapIsBackAtTheStartBeforeADeferredPauseLands() throws {
        let player = VideoPlayer(delegate: self, identifier: "deferred-pause-test")
        let screen = Screen(player)
        lap = expectation(description: "the lap")
        onLap = { DispatchQueue.main.async { player.pause() } }
        player.play(url: clip, section: section)
        wait(for: [lap!], timeout: 10)
        spin(0.6)
        XCTAssertNotNil(screen.current)
        XCTAssertTrue((15 ... 20).contains(screen.current ?? -1),
                      "expected the section's first frames, held on \(screen.current ?? -1): \(screen.shown)")
        screen.stop()
        player.stopVideo()
    }

    /// Mute belongs to the player: it survives loading another clip.
    func testMuteStaysAcrossLoads() throws {
        let player = VideoPlayer(delegate: self, identifier: "mute-test")
        XCTAssertFalse(player.isMuted)
        player.isMuted = true
        player.play(url: clip, section: section)
        XCTAssertTrue(player.player.isMuted)
        player.play(url: clip)
        XCTAssertTrue(player.isMuted)
        player.isMuted = false
        XCTAssertFalse(player.player.isMuted)
        player.stopVideo()
    }

    /// `mediaTime` is the item's clock: it runs, it holds with a hold, and it
    /// reads 0 with nothing loaded.
    func testMediaTimeIsTheItemsClock() throws {
        let player = VideoPlayer(delegate: self, identifier: "clock-test")
        XCTAssertEqual(player.mediaTime, 0)
        player.play(url: clip, section: PlaybackSection(start: 0.2, duration: nil))
        spin(0.7)
        XCTAssertGreaterThan(player.mediaTime, 0.4)
        player.pause()
        let held = player.mediaTime
        spin(0.3)
        XCTAssertEqual(player.mediaTime, held, accuracy: 0.001)
        player.stopVideo()
        XCTAssertEqual(player.mediaTime, 0)
    }
}
