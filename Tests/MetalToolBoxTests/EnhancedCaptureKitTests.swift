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
        XCTAssertFalse(config.screenCapturesAtPixelResolution, "display frames came at the point size before 2.3.0")
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

final class EnhancedCaptureTestPatternTests: XCTestCase {

    func testColorBarsTemplateHasSevenBarsOverARamp() {
        let width = 70, height = 30
        let bytes = EnhancedCaptureTestPatternRenderer.bgraTemplate(.colorBars, width: width, height: height)
        XCTAssertEqual(bytes.count, width * height * 4)

        // Bars occupy the top two thirds; sample the middle of each bar on row 5.
        for (bar, expected) in EnhancedCaptureTestPatternRenderer.barColors.enumerated() {
            let x = bar * 10 + 5
            let o = (5 * width + x) * 4
            XCTAssertEqual(bytes[o + 2], expected.r, "bar \(bar) red")
            XCTAssertEqual(bytes[o + 1], expected.g, "bar \(bar) green")
            XCTAssertEqual(bytes[o], expected.b, "bar \(bar) blue")
            XCTAssertEqual(bytes[o + 3], 255)
        }

        // Bottom third is a ramp: black at x = 0, white at the right edge.
        let left = (25 * width) * 4
        let right = (25 * width + width - 1) * 4
        XCTAssertEqual(bytes[left], 0)
        XCTAssertEqual(bytes[right], 255)
    }

    func testSolidTemplateUsesRequestedColor() {
        let bytes = EnhancedCaptureTestPatternRenderer.bgraTemplate(.solid(red: 1, green: 0.5, blue: 0), width: 4, height: 2)
        XCTAssertEqual(bytes[2], 255)  // R
        XCTAssertEqual(bytes[1], 128)  // G
        XCTAssertEqual(bytes[0], 0)    // B
    }

    func testYCbCrConversionOfWhiteAndGreyInBothRanges() {
        let video = EnhancedCaptureTestPatternRenderer.yCbCr(r: 255, g: 255, b: 255, fullRange: false)
        XCTAssertEqual(video.y, 235)
        XCTAssertEqual(video.cb, 128)
        XCTAssertEqual(video.cr, 128)

        let full = EnhancedCaptureTestPatternRenderer.yCbCr(r: 255, g: 255, b: 255, fullRange: true)
        XCTAssertEqual(full.y, 255)
        XCTAssertEqual(full.cb, 128)
        XCTAssertEqual(full.cr, 128)

        let red = EnhancedCaptureTestPatternRenderer.yCbCr(r: 191, g: 0, b: 0, fullRange: false)
        XCTAssertGreaterThan(red.cr, 128, "red has positive Cr")
        XCTAssertLessThan(red.cb, 128, "red has negative Cb")
    }

    func testYCbCrPlanesHaveHalfResolutionChroma() {
        let width = 8, height = 6
        let bgra = EnhancedCaptureTestPatternRenderer.bgraTemplate(.grayRamp, width: width, height: height)
        let planes = EnhancedCaptureTestPatternRenderer.yCbCrPlanes(fromBGRA: bgra, width: width, height: height, fullRange: false)
        XCTAssertEqual(planes.luma.count, width * height)
        XCTAssertEqual(planes.chroma.count, (width / 2) * (height / 2) * 2)
        XCTAssertTrue(planes.chroma.allSatisfy { $0 == 128 }, "a grey ramp has neutral chroma everywhere")
        XCTAssertLessThan(planes.luma[0], planes.luma[width - 1], "ramp brightens to the right")
    }

    func testTestPatternIsOffByDefaultAndSourceDescribesItself() {
        let config = EnhancedCaptureConfiguration.default
        XCTAssertFalse(config.testPatternEnabled)
        XCTAssertEqual(config.testPattern, .colorBars)
        XCTAssertEqual(config.testPatternFrameRate, 30)
        XCTAssertTrue(config.testPatternAnimated)
    }

    /// Runs the generator for a few frames and checks what a consumer receives.
    func testGeneratorDeliversTimedMetalCompatibleFrames() {
        final class Sink: EnhancedCaptureTestPatternSourceDelegate, @unchecked Sendable {
            let lock = NSLock()
            var buffers: [CMSampleBuffer] = []
            let expectation: XCTestExpectation
            init(expectation: XCTestExpectation) { self.expectation = expectation }
            func testPatternSource(_ source: EnhancedCaptureTestPatternSource, didOutput sampleBuffer: CMSampleBuffer) {
                lock.lock(); buffers.append(sampleBuffer); let count = buffers.count; lock.unlock()
                if count == 5 { expectation.fulfill() }
            }
        }

        var config = EnhancedCaptureConfiguration()
        config.testPatternEnabled = true
        config.testPatternSize = CGSize(width: 320, height: 180)
        config.testPatternFrameRate = 60
        let expectation = expectation(description: "five frames")
        let sink = Sink(expectation: expectation)
        let generator = EnhancedCaptureTestPatternSource(configuration: config, delegate: sink)

        XCTAssertEqual(generator.captureSource.type, .testPattern)
        XCTAssertTrue(generator.captureSource.hasVideo)
        XCTAssertFalse(generator.captureSource.hasAudio)
        XCTAssertNil(generator.start())
        wait(for: [expectation], timeout: 2)
        generator.stop()

        sink.lock.lock(); let buffers = sink.buffers; sink.lock.unlock()
        XCTAssertGreaterThanOrEqual(buffers.count, 5)

        let first = buffers[0]
        let image = CMSampleBufferGetImageBuffer(first)!
        XCTAssertEqual(CVPixelBufferGetWidth(image), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(image), 180)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(image), "pool buffers must be IOSurface-backed for zero-copy Metal upload")
        XCTAssertEqual(CMSampleBufferGetDuration(first).seconds, 1.0 / 60, accuracy: 1e-6)

        // Timestamps are host-clock and strictly increasing.
        let times = buffers.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
        for (a, b) in zip(times, times.dropFirst()) { XCTAssertLessThan(a, b) }
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        XCTAssertLessThan(hostNow - times.last!, 1.0, "stamped from the host clock, like camera frames")

        // The frame counter changes between frames (animated).
        let geometry = try! XCTUnwrap(EnhancedCaptureTestPatternRenderer.counterGeometry(width: 320))
        let msbX = EnhancedCaptureTestPatternRenderer.counterX(bit: 0, geometry: geometry) + 2
        let lsbX = EnhancedCaptureTestPatternRenderer.counterX(bit: 15, geometry: geometry) + 2
        XCTAssertLessThan(lsbX + geometry.square, 320, "counter must fit a 320 px frame")

        CVPixelBufferLockBaseAddress(image, .readOnly)
        let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        // Frame 0: every counter square is black (its alpha stays opaque).
        XCTAssertEqual(base[10 * stride + msbX * 4], 0)
        XCTAssertEqual(base[10 * stride + msbX * 4 + 3], 255)
        XCTAssertEqual(base[10 * stride + lsbX * 4], 0)
        CVPixelBufferUnlockBaseAddress(image, .readOnly)

        let second = CMSampleBufferGetImageBuffer(buffers[1])!
        CVPixelBufferLockBaseAddress(second, .readOnly)
        let base2 = CVPixelBufferGetBaseAddress(second)!.assumingMemoryBound(to: UInt8.self)
        let stride2 = CVPixelBufferGetBytesPerRow(second)
        // Frame 1: only the least-significant square is white.
        XCTAssertEqual(base2[10 * stride2 + lsbX * 4], 255)
        XCTAssertEqual(base2[10 * stride2 + msbX * 4], 0)
        CVPixelBufferUnlockBaseAddress(second, .readOnly)
    }

    func testCounterGeometryScalesWithWidth() {
        XCTAssertNil(EnhancedCaptureTestPatternRenderer.counterGeometry(width: 64))
        let narrow = EnhancedCaptureTestPatternRenderer.counterGeometry(width: 320)!
        XCTAssertEqual(narrow.cell, 19)
        XCTAssertEqual(narrow.square, 15)
        let wide = EnhancedCaptureTestPatternRenderer.counterGeometry(width: 1920)!
        XCTAssertEqual(wide.cell, 20)
        XCTAssertEqual(wide.square, 16)
        XCTAssertLessThanOrEqual(EnhancedCaptureTestPatternRenderer.counterX(bit: 15, geometry: wide) + wide.square, 1920)
    }

    func testGeneratorProducesYCbCrWhenConfigured() {
        final class Sink: EnhancedCaptureTestPatternSourceDelegate, @unchecked Sendable {
            let expectation: XCTestExpectation
            let lock = NSLock()
            var first: CMSampleBuffer?
            init(expectation: XCTestExpectation) { self.expectation = expectation }
            func testPatternSource(_ source: EnhancedCaptureTestPatternSource, didOutput sampleBuffer: CMSampleBuffer) {
                lock.lock(); defer { lock.unlock() }
                if first == nil { first = sampleBuffer; expectation.fulfill() }
            }
        }
        var config = EnhancedCaptureConfiguration()
        config.pixelFormat = .yCbCr420VideoRange
        config.testPattern = .solid(red: 1, green: 1, blue: 1)
        config.testPatternSize = CGSize(width: 64, height: 32)
        config.testPatternAnimated = false
        let expectation = expectation(description: "first frame")
        let sink = Sink(expectation: expectation)
        let generator = EnhancedCaptureTestPatternSource(configuration: config, delegate: sink)
        XCTAssertNil(generator.start())
        wait(for: [expectation], timeout: 2)
        generator.stop()

        sink.lock.lock(); let buffer = sink.first; sink.lock.unlock()
        let image = CMSampleBufferGetImageBuffer(buffer!)!
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(CVPixelBufferGetPlaneCount(image), 2)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(luma[0], 235, "white in video range")
        XCTAssertEqual(chroma[0], 128)
        XCTAssertEqual(chroma[1], 128)
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
    }
}

final class EnhancedCaptureDepthTests: XCTestCase {

    private func candidate(_ w: Int32, _ h: Int32, fps: Double, depth: Bool) -> EnhancedCaptureFormatCandidate {
        EnhancedCaptureFormatCandidate(width: w, height: h, frameRateRanges: [1...fps], supportsDepth: depth)
    }

    /// LiDAR iPad Pro back camera: only some formats carry depth.
    private var formats: [EnhancedCaptureFormatCandidate] {
        [
            candidate(1280, 720, fps: 30, depth: true),
            candidate(1920, 1080, fps: 30, depth: true),
            candidate(1920, 1080, fps: 60, depth: false),
            candidate(3840, 2160, fps: 30, depth: false),
        ]
    }

    func testDepthPreferenceKeepsDepthCapableFormatsWhenAvailable() {
        let index = EnhancedCaptureFormatSelector.bestIndex(among: formats, preference: .uhd4K30, preferDepthSupport: true)
        XCTAssertEqual(index, 1, "4K has no depth; the largest depth-capable format wins")
        XCTAssertTrue(formats[index!].supportsDepth)
    }

    func testDepthPreferenceIsOptional() {
        let noDepth = formats.filter { !$0.supportsDepth }
        let index = EnhancedCaptureFormatSelector.bestIndex(among: noDepth, preference: .uhd4K30, preferDepthSupport: true)
        XCTAssertNotNil(index, "a camera without depth still gets a format")
    }

    func testWithoutDepthPreferenceTheBestFormatIsUnchanged() {
        XCTAssertEqual(EnhancedCaptureFormatSelector.bestIndex(among: formats, preference: .uhd4K30), 3)
    }

    func testDepthIsOffByDefaultAndMediaFlagExists() {
        let config = EnhancedCaptureConfiguration.default
        XCTAssertFalse(config.depthDataEnabled)
        XCTAssertTrue(config.depthDataFiltered)

        let lidar = EnhancedCaptureSource(id: "l", type: .cameraBack, displayName: "Back", manufacturer: "Apple Inc.", modelID: "x", uniqueID: "l", media: [.video, .depth])
        XCTAssertTrue(lidar.hasVideo)
        XCTAssertTrue(lidar.hasDepth)
        XCTAssertFalse(lidar.hasAudio)
        XCTAssertNotEqual(EnhancedCaptureMediaKinds.depth, .audio)
    }
}
