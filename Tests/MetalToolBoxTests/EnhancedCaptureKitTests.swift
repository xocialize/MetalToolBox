//
//  EnhancedCaptureKitTests.swift
//  MetalToolBox
//
//  The hardware-free parts of EnhancedCaptureKit: format selection, the
//  public value types, and the defaults that keep `init(delegate:)`
//  behaviour unchanged. Anything touching AVCaptureSession needs a device
//  and a run loop and is exercised by the host apps instead.
//

import XCTest
import CoreMedia
@testable import EnhancedCaptureKit

final class EnhancedCaptureFormatSelectorTests: XCTestCase {

    private func candidate(_ w: Int32, _ h: Int32, fps: [ClosedRange<Double>], binned: Bool = false) -> EnhancedCaptureFormatCandidate {
        EnhancedCaptureFormatCandidate(width: w, height: h, frameRateRanges: fps, isBinned: binned)
    }

    /// A typical iPad Pro back-camera format list, in device order.
    private var iPadFormats: [EnhancedCaptureFormatCandidate] {
        [
            candidate(192, 144, fps: [1...60]),
            candidate(640, 480, fps: [1...60]),
            candidate(1280, 720, fps: [1...60]),
            candidate(1280, 720, fps: [1...120], binned: true),
            candidate(1920, 1080, fps: [1...30]),
            candidate(1920, 1080, fps: [1...60]),
            candidate(1920, 1080, fps: [1...120], binned: true),
            candidate(3840, 2160, fps: [1...30]),
            candidate(3840, 2160, fps: [1...60]),
            candidate(4032, 3024, fps: [1...30]),   // photo-oriented 12 MP
        ]
    }

    func testEmptyCandidatesYieldNil() {
        XCTAssertNil(EnhancedCaptureFormatSelector.bestIndex(among: [], preference: .hd1080p30))
    }

    func testNoPreferencePicksLargestArea() {
        let index = EnhancedCaptureFormatSelector.bestIndex(among: iPadFormats, preference: EnhancedCaptureVideoPreference())
        XCTAssertEqual(index, 9, "the 12 MP photo format is the largest when nothing is asked for")
    }

    func testSizePreferencePicksLeastExcessCoveringFormat() {
        let index = EnhancedCaptureFormatSelector.bestIndex(among: iPadFormats, preference: .hd1080p30)
        XCTAssertNotNil(index)
        let chosen = iPadFormats[index!]
        XCTAssertEqual(chosen.width, 1920)
        XCTAssertEqual(chosen.height, 1080)
    }

    func testTieBreakPrefersNonBinnedThenHigherFrameRate() {
        // 1080p candidates: 30 fps, 60 fps, 120 fps (binned). Ask 1080p@30.
        let index = EnhancedCaptureFormatSelector.bestIndex(among: iPadFormats, preference: .hd1080p30)
        XCTAssertEqual(index, 5, "non-binned 1080p60 beats 1080p30 (higher max fps) and binned 1080p120")
    }

    func testFrameRateFilterExcludesFormatsThatCannotDeliverIt() {
        let index = EnhancedCaptureFormatSelector.bestIndex(among: iPadFormats, preference: .hd1080p60)
        XCTAssertEqual(index, 5)
        XCTAssertTrue(iPadFormats[index!].supports(frameRate: 60))
    }

    func testFrameRateFallsBackToAllCandidatesWhenNoneSupportIt() {
        let pref = EnhancedCaptureVideoPreference(preferredSize: CGSize(width: 1920, height: 1080), preferredFrameRate: 240)
        let index = EnhancedCaptureFormatSelector.bestIndex(among: iPadFormats, preference: pref)
        XCTAssertNotNil(index, "an impossible fps must not leave the device without a format")
        XCTAssertEqual(iPadFormats[index!].width, 1920)
    }

    func testSizeLargerThanAnyFormatPicksTheLargest() {
        let pref = EnhancedCaptureVideoPreference(preferredSize: CGSize(width: 7680, height: 4320))
        let index = EnhancedCaptureFormatSelector.bestIndex(among: iPadFormats, preference: pref)
        XCTAssertEqual(index, 9)
    }

    func testUHDPreferenceSkipsPhotoFormat() {
        let index = EnhancedCaptureFormatSelector.bestIndex(among: iPadFormats, preference: .uhd4K30)
        XCTAssertNotNil(index)
        XCTAssertEqual(iPadFormats[index!].width, 3840)
        XCTAssertEqual(iPadFormats[index!].height, 2160)
        XCTAssertEqual(iPadFormats[index!].maxFrameRate, 60, "same size: higher max fps wins")
    }

    func testCandidateHelpers() {
        let c = candidate(1920, 1080, fps: [1...30, 60...60])
        XCTAssertTrue(c.supports(frameRate: 24))
        XCTAssertTrue(c.supports(frameRate: 60))
        XCTAssertFalse(c.supports(frameRate: 45))
        XCTAssertEqual(c.maxFrameRate, 60)
        XCTAssertTrue(c.covers(CGSize(width: 1280, height: 720)))
        XCTAssertFalse(c.covers(CGSize(width: 1920, height: 1200)))
        XCTAssertEqual(c.pixelArea, 1920 * 1080)
    }
}

final class EnhancedCaptureTypesTests: XCTestCase {

    func testDefaultConfigurationMatchesLegacyBehaviour() {
        let config = EnhancedCaptureConfiguration.default
        XCTAssertFalse(config.audioEnabled)
        XCTAssertTrue(config.deliversAudioSampleBuffers)
        XCTAssertFalse(config.audioLevelMeteringEnabled)
        XCTAssertNil(config.videoPreference)
        XCTAssertEqual(config.pixelFormat, .bgra)
        XCTAssertEqual(config.screenFrameRate, 30)
        XCTAssertTrue(config.screenShowsCursor)
        #if os(macOS)
        XCTAssertTrue(config.audioPreviewEnabled, "macOS speaker preview was always on before configuration existed")
        #else
        XCTAssertFalse(config.audioPreviewEnabled)
        #endif
    }

    func testAudioVideoPresetTurnsAudioOnWithoutSpeakerPreview() {
        let config = EnhancedCaptureConfiguration.audioVideo
        XCTAssertTrue(config.audioEnabled)
        XCTAssertFalse(config.audioPreviewEnabled)
        XCTAssertTrue(config.audioLevelMeteringEnabled)
    }

    func testSourceMediaFlags() {
        let camera = EnhancedCaptureSource(id: "c", type: .cameraBack, displayName: "Back", manufacturer: "Apple Inc.", modelID: "x", uniqueID: "c")
        XCTAssertTrue(camera.hasVideo)
        XCTAssertFalse(camera.hasAudio)

        let mic = EnhancedCaptureSource(id: "m", type: .microphone, displayName: "Mic", manufacturer: "Apple Inc.", modelID: "x", uniqueID: "m", media: .audio)
        XCTAssertFalse(mic.hasVideo)
        XCTAssertTrue(mic.hasAudio)

        let card = EnhancedCaptureSource(id: "h", type: .externalDevice, displayName: "HDMI", manufacturer: "Magewell", modelID: "x", uniqueID: "h", media: [.video, .audio])
        XCTAssertTrue(card.hasVideo)
        XCTAssertTrue(card.hasAudio)
    }

    func testAudioLevelAggregates() {
        let empty = EnhancedCaptureAudioLevel(channels: [], presentationTime: .zero)
        XCTAssertEqual(empty.peak, -.infinity)
        XCTAssertEqual(empty.average, -.infinity)

        let stereo = EnhancedCaptureAudioLevel(
            channels: [
                .init(averagePower: -20, peakHold: -6),
                .init(averagePower: -14, peakHold: -3),
            ],
            presentationTime: CMTime(value: 1, timescale: 48_000)
        )
        XCTAssertEqual(stereo.peak, -3)
        XCTAssertEqual(stereo.average, -14)
    }

    func testEveryErrorHasADescription() {
        let errors: [EnhancedCaptureError] = [
            .permissionDenied(.microphone),
            .sourceUnavailable("x"),
            .captureStartFailed(reason: "r"),
            .streamInterrupted(reason: "r"),
            .platformUnsupported(feature: "f"),
            .deviceConfigurationFailed(reason: "r"),
            .sessionRuntimeError(reason: "r", willRestart: true),
        ]
        for error in errors {
            XCTAssertFalse(error.description.isEmpty, "\(error)")
        }
        XCTAssertTrue(EnhancedCaptureError.sessionRuntimeError(reason: "r", willRestart: true).description.contains("restarting"))
        XCTAssertFalse(EnhancedCaptureError.sessionRuntimeError(reason: "r", willRestart: false).description.contains("restarting"))
    }

    func testPixelFormatCoreVideoTypes() {
        XCTAssertEqual(EnhancedCapturePixelFormat.bgra.coreVideoType, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(EnhancedCapturePixelFormat.yCbCr420VideoRange.coreVideoType, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(EnhancedCapturePixelFormat.yCbCr420FullRange.coreVideoType, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    #if os(iOS)
    func testInterruptionReasonMapping() {
        XCTAssertEqual(EnhancedCaptureInterruptionReason(rawAVReason: 1), .videoDeviceNotAvailableInBackground)
        XCTAssertEqual(EnhancedCaptureInterruptionReason(rawAVReason: 2), .audioDeviceInUseByAnotherClient)
        XCTAssertEqual(EnhancedCaptureInterruptionReason(rawAVReason: 3), .videoDeviceInUseByAnotherClient)
        XCTAssertEqual(EnhancedCaptureInterruptionReason(rawAVReason: 4), .videoDeviceNotAvailableWithMultipleForegroundApps)
        XCTAssertEqual(EnhancedCaptureInterruptionReason(rawAVReason: 5), .videoDeviceNotAvailableDueToSystemPressure)
        XCTAssertEqual(EnhancedCaptureInterruptionReason(rawAVReason: 99), .unknown(99))
    }
    #endif
}
