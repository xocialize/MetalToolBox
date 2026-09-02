//
//  EnhancedCaptureStreamsTests.swift
//  MetalToolBox
//
//  The async façade's fan-out, driven directly (constructing a kit would
//  request camera access, which a test process cannot do).
//

import XCTest
import CoreMedia
import CoreVideo
@testable import EnhancedCaptureKit

final class EnhancedCaptureStreamsTests: XCTestCase {

    private let camera = EnhancedCaptureSource(id: "cam", type: .cameraBack, displayName: "Back", manufacturer: "Apple Inc.", modelID: "x", uniqueID: "cam")
    private let mic = EnhancedCaptureSource(id: "mic", type: .microphone, displayName: "Mic", manufacturer: "Apple Inc.", modelID: "x", uniqueID: "mic", media: .audio)

    private func makeSampleBuffer(width: Int = 16, height: Int = 16, seconds: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        return try XCTUnwrap(sampleBuffer)
    }

    func testSourcesStreamReplaysCurrentListThenChanges() async {
        let streams = EnhancedCaptureStreams(detached: ())
        streams.publish(sources: [camera])

        var iterator = streams.sources.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, [camera], "a new subscriber sees the current list immediately")

        streams.publish(sources: [camera, mic])
        let second = await iterator.next()
        XCTAssertEqual(second, [camera, mic])
        XCTAssertEqual(streams.currentSources, [camera, mic])
    }

    func testVideoFramesAreRoutedPerSourceAndKeepOnlyTheNewest() async throws {
        let streams = EnhancedCaptureStreams(detached: ())
        let cameraFrames = streams.videoFrames(for: camera)
        var iterator = cameraFrames.makeAsyncIterator()

        // Publishing before the consumer is awaiting: only the newest survives.
        for t in 1...5 {
            streams.publish(videoSampleBuffer: try makeSampleBuffer(seconds: Double(t)), for: camera)
        }
        // A frame for a different source never reaches this subscription.
        streams.publish(videoSampleBuffer: try makeSampleBuffer(seconds: 99), for: mic)

        let frame = await iterator.next()
        XCTAssertEqual(frame?.presentationTime.seconds, 5, "buffering is newest-only")
        XCTAssertEqual(frame?.source, camera)
        XCTAssertNotNil(frame?.pixelBuffer)
        XCTAssertEqual(streams.subscriberCounts.video, 1)
    }

    func testAudioBuffersRouteBySourceWithBoundedWindow() async throws {
        let streams = EnhancedCaptureStreams(detached: ())
        var iterator = streams.audioBuffers(for: mic).makeAsyncIterator()
        for t in 1...3 {
            streams.publish(audioSampleBuffer: try makeSampleBuffer(seconds: Double(t)), for: mic)
        }
        let a = await iterator.next(), b = await iterator.next(), c = await iterator.next()
        XCTAssertEqual([a, b, c].compactMap { $0?.presentationTime.seconds }, [1, 2, 3], "audio keeps order within the window")
        XCTAssertGreaterThanOrEqual(EnhancedCaptureStreams.audioBufferDepth, 64)
    }

    func testEventsAndLevelsFanOut() async {
        let streams = EnhancedCaptureStreams(detached: ())
        var events = streams.events.makeAsyncIterator()
        var levels = streams.audioLevels.makeAsyncIterator()

        streams.publish(event: .initialized)
        streams.publish(event: .error(.permissionDenied(.microphone), mic))
        streams.publish(level: EnhancedCaptureAudioLevel(channels: [.init(averagePower: -20, peakHold: -6)], presentationTime: .zero), for: mic)

        guard case .initialized = await events.next() else { return XCTFail("expected initialized") }
        guard case .error(.permissionDenied(.microphone), let source)? = await events.next() else { return XCTFail("expected error") }
        XCTAssertEqual(source, mic)

        let update = await levels.next()
        XCTAssertEqual(update?.source, mic)
        XCTAssertEqual(update?.level.peak, -6)
    }

    func testCancelledSubscriptionIsRemoved() async {
        let streams = EnhancedCaptureStreams(detached: ())
        let task = Task {
            for await _ in streams.videoFrames(for: camera) {}
        }
        // Let the subscription register, then cancel it.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(streams.subscriberCounts.video, 1)
        task.cancel()
        _ = await task.value
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(streams.subscriberCounts.video, 0, "termination handler unregisters the continuation")
    }

    func testPublishingWithNoSubscribersIsCheap() throws {
        let streams = EnhancedCaptureStreams(detached: ())
        // Must not crash or retain anything.
        streams.publish(videoSampleBuffer: try makeSampleBuffer(seconds: 1), for: camera)
        streams.publish(audioSampleBuffer: try makeSampleBuffer(seconds: 1), for: mic)
        streams.publish(event: .initialized)
        let counts = streams.subscriberCounts
        XCTAssertEqual(counts.video + counts.audio + counts.events + counts.levels + counts.sources, 0)
    }
}
