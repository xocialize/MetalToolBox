//
//  PausePlaybackTests.swift
//  MetalToolBox
//
//  Real-asset pause: does holding playback actually hold the CLOCK, keep the
//  item alive, and continue from where it stopped? `playerIsPause` used to be a
//  flag with an empty observer, so a unit test asserting the flag would have
//  passed against a player that never stopped playing — only the item's own
//  clock can answer this.
//
//  Skips when the fixture is absent: a local Marquee test-show clip rather than
//  a video committed to the repo (same fixture as SectionPlaybackTests).
//

import XCTest
import AVFoundation
@testable import VideoPlayerKit

final class PausePlaybackTests: XCTestCase, VideoPlayerDelegate {

    private static let fixture = RealAssetFixture.clip

    private var lap: XCTestExpectation?

    func VideoPlayerBuffer(pixelBuffer: CVPixelBuffer?) {}

    func videoPlayerDidCompleteLoop(identifier: String) { lap?.fulfill() }

    /// Real time has to pass for the item's clock to move, and the player's
    /// callbacks land on the main queue — so spin the run loop rather than
    /// sleeping it.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func makePlayer() throws -> VideoPlayer {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixture.path),
                          "fixture clip not present on this machine")
        return VideoPlayer(delegate: self, identifier: "pause-test")
    }

    /// The whole contract in one pass: the clock stops, the item survives, and
    /// a resume continues rather than restarting.
    func testPauseHoldsTheClockAndResumeContinues() throws {
        let player = try makePlayer()
        player.play(url: Self.fixture, section: PlaybackSection(start: 0, duration: 8))
        spin(1.2)

        let running = player.player.currentTime().seconds
        XCTAssertGreaterThan(running, 0.2, "playback never started — the rest of this test proves nothing")

        player.pause()
        XCTAssertTrue(player.playerIsPause)
        let atPause = player.player.currentTime().seconds
        spin(0.8)
        let afterHold = player.player.currentTime().seconds
        XCTAssertEqual(afterHold, atPause, accuracy: 0.05,
                       "the clock advanced while held — this is the bug the empty didSet shipped")
        XCTAssertNotNil(player.player.currentItem, "a hold must not tear the item down")

        player.resume()
        XCTAssertFalse(player.playerIsPause)
        spin(0.6)
        XCTAssertGreaterThan(player.player.currentTime().seconds, afterHold + 0.2,
                             "resume did not continue the clock")
        // Resume CONTINUES: it does not seek back to the section start.
        XCTAssertGreaterThan(player.player.currentTime().seconds, atPause,
                             "resume restarted rather than continued")
        player.stopVideo()
    }

    /// The section's boundary observer has to survive a hold — otherwise a
    /// paused-then-resumed clip would play past its section forever.
    func testPauseDoesNotDropTheSectionLap() throws {
        let player = try makePlayer()
        lap = expectation(description: "lap still arrives after a hold")
        player.play(url: Self.fixture, section: PlaybackSection(start: 5, duration: 3))
        spin(1.0)
        player.pause()
        spin(1.0)                       // held: this second must not count toward the section
        player.resume()
        wait(for: [lap!], timeout: 12)  // ~2 s of playback still owed
        player.stopVideo()
    }

    /// A torn-down player is not a held one: the hold clears on the way out, so
    /// the next `play` is not swallowed.
    func testStopClearsTheHold() throws {
        let player = try makePlayer()
        player.play(url: Self.fixture)
        spin(0.5)
        player.pause()
        XCTAssertTrue(player.playerIsPause)
        player.stopVideo()
        XCTAssertFalse(player.playerIsPause, "a stopped player must not stay flagged as held")
        XCTAssertNil(player.player.currentItem)
    }

    /// Loading a new clip while the previous one is held must play, not inherit
    /// the hold — the failure mode would be a black output nobody can explain.
    func testAFreshLoadClearsAStaleHold() throws {
        let player = try makePlayer()
        player.play(url: Self.fixture, section: PlaybackSection(start: 0, duration: 8))
        spin(0.8)
        player.pause()
        XCTAssertTrue(player.playerIsPause)

        player.play(url: Self.fixture, section: PlaybackSection(start: 2, duration: 6))
        spin(1.0)
        XCTAssertFalse(player.playerIsPause, "a fresh load left the stale hold in place")
        XCTAssertGreaterThan(player.player.currentTime().seconds, 2.1,
                             "the new clip never started playing")
        player.stopVideo()
    }
}
