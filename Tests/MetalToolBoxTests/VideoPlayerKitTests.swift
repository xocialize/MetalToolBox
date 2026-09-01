//
//  VideoPlayerKitTests.swift
//  MetalToolBox
//
//  The pure media-time math behind sectioned playback. Playback itself needs
//  a real asset and a run loop; the arithmetic that decides where a clip
//  starts, ends and loops is what a unit test can pin.
//

import XCTest
@testable import VideoPlayerKit

final class VideoPlayerKitTests: XCTestCase {

    func testWholeFileHasNoEnd() {
        let section = PlaybackSection.wholeFile
        XCTAssertEqual(section.start, 0)
        XCTAssertNil(section.duration)
        XCTAssertNil(section.end)
    }

    func testEndIsStartPlusDuration() {
        XCTAssertEqual(PlaybackSection(start: 12, duration: 8).end, 20)
        XCTAssertNil(PlaybackSection(start: 12, duration: nil).end)
    }

    func testNegativeInputsClampToZero() {
        let section = PlaybackSection(start: -3, duration: -1)
        XCTAssertEqual(section.start, 0)
        XCTAssertEqual(section.duration, 0)
    }

    func testClampKeepsAnInteriorSection() {
        let section = PlaybackSection(start: 10, duration: 5).clamped(toAssetDuration: 60)
        XCTAssertEqual(section, PlaybackSection(start: 10, duration: 5))
    }

    func testClampCollapsesAStartPastTheEnd() {
        let section = PlaybackSection(start: 90, duration: 5).clamped(toAssetDuration: 60)
        XCTAssertEqual(section.start, 60 - PlaybackSection.minimumClip, accuracy: 0.0001)
        XCTAssertNil(section.end, "an end past the file becomes the file's end")
    }

    func testClampTurnsAnOverrunningEndIntoTheFilesEnd() {
        let section = PlaybackSection(start: 50, duration: 30).clamped(toAssetDuration: 60)
        XCTAssertEqual(section.start, 50)
        XCTAssertNil(section.end)
    }

    func testClampLeavesUnknownDurationAlone() {
        let section = PlaybackSection(start: 50, duration: 30)
        XCTAssertEqual(section.clamped(toAssetDuration: 0), section)
        XCTAssertEqual(section.clamped(toAssetDuration: -1), section)
    }
}
