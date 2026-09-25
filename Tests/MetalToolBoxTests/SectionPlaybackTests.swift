//
//  SectionPlaybackTests.swift
//  MetalToolBox
//
//  Real-asset playback: does a section actually complete at its end on the
//  item's clock? The math tests can't answer that; only a player can.
//
//  Skips when the fixture is absent — it uses a local Marquee test-show clip
//  (VP26 "Video Slide 15s", 14.7 s) rather than shipping a video in the repo.
//

import XCTest
import AVFoundation
@testable import VideoPlayerKit

final class SectionPlaybackTests: XCTestCase, VideoPlayerDelegate {

    private static let fixture = RealAssetFixture.clip

    private var lap: XCTestExpectation?
    private var lapCount = 0

    func VideoPlayerBuffer(pixelBuffer: CVPixelBuffer?) {}

    func videoPlayerDidCompleteLoop(identifier: String) {
        lapCount += 1
        lap?.fulfill()
    }

    /// A 5→9 s section must report its lap ~4 s after playback starts — not at
    /// the file's end (14.7 s), and not never.
    func testSectionLapArrivesAtTheSectionEnd() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixture.path),
                          "fixture clip not present on this machine")
        let player = VideoPlayer(delegate: self, identifier: "section-test")
        lap = expectation(description: "first lap")
        let started = Date()
        player.play(url: Self.fixture, section: PlaybackSection(start: 5, duration: 4))
        wait(for: [lap!], timeout: 10)
        let elapsed = Date().timeIntervalSince(started)
        print("SECTION lap after \(String(format: "%.2f", elapsed)) s")
        XCTAssertGreaterThan(elapsed, 3.0, "lap arrived before the section could have played")
        XCTAssertLessThan(elapsed, 8.0, "lap arrived far later than the 4 s section")
        player.stopVideo()
    }
}
