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

    func testFrameDurationKeepsFractionalRates() {
        // 59.94 must not round to 1/60: that is shorter than a 59.94 fps
        // format's minimum frame duration and the AVFoundation setter throws.
        let ntsc = EnhancedCaptureFormatSelector.frameDuration(forFrameRate: 59.94)
        XCTAssertNotNil(ntsc)
        XCTAssertEqual(ntsc!.value, 1000)
        XCTAssertEqual(ntsc!.timescale, 59_940)
        XCTAssertGreaterThanOrEqual(ntsc!, CMTime(value: 1001, timescale: 60_000), "must be a legal duration for a 60000/1001 range")
        XCTAssertLessThan(ntsc!, CMTime(value: 1, timescale: 59), "and not slower than 59 fps")

        XCTAssertEqual(EnhancedCaptureFormatSelector.frameDuration(forFrameRate: 30), CMTime(value: 1000, timescale: 30_000))
        XCTAssertEqual(EnhancedCaptureFormatSelector.frameDuration(forFrameRate: 30)!.seconds, 1.0 / 30, accuracy: 1e-9)
        XCTAssertNil(EnhancedCaptureFormatSelector.frameDuration(forFrameRate: 0))
        XCTAssertNil(EnhancedCaptureFormatSelector.frameDuration(forFrameRate: -24))
        XCTAssertNil(EnhancedCaptureFormatSelector.frameDuration(forFrameRate: .infinity))
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
        XCTAssertFalse(config.screenAudioEnabled)
        XCTAssertEqual(config.cameraRotationMode, .none, "buffers were sensor-oriented before configuration existed")
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

final class EnhancedCaptureMultiCameraTests: XCTestCase {

    private func candidate(_ w: Int32, _ h: Int32, fps: Double, multiCam: Bool) -> EnhancedCaptureFormatCandidate {
        EnhancedCaptureFormatCandidate(width: w, height: h, frameRateRanges: [1...fps], isMultiCamSupported: multiCam)
    }

    /// A back camera as seen on an iPad Pro: the large / fast formats are not
    /// multi-cam capable, the 720p and 1080p30 ones are.
    private var formats: [EnhancedCaptureFormatCandidate] {
        [
            candidate(1280, 720, fps: 60, multiCam: true),
            candidate(1920, 1080, fps: 30, multiCam: true),
            candidate(1920, 1080, fps: 60, multiCam: false),
            candidate(3840, 2160, fps: 30, multiCam: false),
            candidate(4032, 3024, fps: 30, multiCam: false),
        ]
    }

    func testSingleCameraIgnoresMultiCamFlag() {
        let index = EnhancedCaptureFormatSelector.bestIndex(among: formats, preference: .uhd4K30)
        XCTAssertEqual(index, 3, "a plain session may use the 4K format")
    }

    func testMultiCameraRestrictsToSupportedFormats() {
        let index = EnhancedCaptureFormatSelector.bestIndex(among: formats, preference: .uhd4K30, requireMultiCamSupport: true)
        XCTAssertEqual(index, 1, "4K is unavailable; the largest multi-cam format wins")
    }

    func testMultiCameraNeverPicksAnUnsupportedFormat() {
        // 1080p60 exists but is not multi-cam capable. Frame rate is filtered
        // before size (rule 1), so the 60 fps request lands on 720p60 — never
        // on the unsupported 1080p60 at index 2.
        let index = EnhancedCaptureFormatSelector.bestIndex(among: formats, preference: .hd1080p60, requireMultiCamSupport: true)
        XCTAssertEqual(index, 0)
        XCTAssertTrue(formats[index!].isMultiCamSupported)
    }

    func testMultiCameraWithNoSupportedFormatYieldsNil() {
        let unsupported = formats.filter { !$0.isMultiCamSupported }
        XCTAssertNil(EnhancedCaptureFormatSelector.bestIndex(among: unsupported, preference: .hd1080p30, requireMultiCamSupport: true))
        XCTAssertNotNil(EnhancedCaptureFormatSelector.bestIndex(among: unsupported, preference: .hd1080p30))
    }

    func testMultiCameraIsOffByDefault() {
        XCTAssertFalse(EnhancedCaptureConfiguration.default.multiCameraEnabled)
        #if os(macOS)
        XCTAssertFalse(EnhancedCaptureKit.isMultiCameraSupported, "macOS has no AVCaptureMultiCamSession")
        #endif
    }

    func testMultiCameraErrorsDescribeThemselves() {
        XCTAssertTrue(EnhancedCaptureError.multiCameraUnsupported.description.contains("single-camera"))
        let cost = EnhancedCaptureError.multiCameraHardwareCostExceeded(hardwareCost: 1.4, systemPressureCost: 0.6)
        XCTAssertTrue(cost.description.contains("1.4"))
        XCTAssertTrue(cost.description.contains("0.6"))
        XCTAssertTrue(EnhancedCaptureError.systemPressureElevated(level: "critical").description.contains("critical"))
    }
}
