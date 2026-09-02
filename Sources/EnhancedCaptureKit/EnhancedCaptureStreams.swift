//
//  EnhancedCaptureStreams.swift
//  EnhancedCaptureKit
//
//  Swift-concurrency façade over EnhancedCaptureKit's delegate. Owns a kit,
//  acts as its delegate, and republishes everything as AsyncStreams with
//  buffering policies chosen for a live pipeline: video keeps only the newest
//  frame per source (a stalled consumer never accumulates frames), audio keeps
//  a bounded window, events keep a bounded log. Frames stay CMSampleBuffers.
//

import Foundation
import AVFoundation
import CoreMedia

// MARK: - Stream payloads

/// One video frame from a source. `CMSampleBuffer` is a reference-counted,
/// immutable-once-delivered CoreMedia object; carrying it across isolation is
/// safe in practice, hence `@unchecked Sendable`.
public struct EnhancedCaptureVideoFrame: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public let source: EnhancedCaptureSource

    /// The frame's pixel buffer (IOSurface-backed for capture sources).
    public var pixelBuffer: CVPixelBuffer? { CMSampleBufferGetImageBuffer(sampleBuffer) }

    /// Presentation time on the host clock.
    public var presentationTime: CMTime { CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
}

/// One audio buffer from a source, PCM in the device's native format.
public struct EnhancedCaptureAudioBuffer: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public let source: EnhancedCaptureSource
    public var presentationTime: CMTime { CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
}

/// One depth map from a LiDAR / TrueDepth camera. `AVDepthData` is an
/// immutable CoreMedia-backed object, hence `@unchecked Sendable`.
public struct EnhancedCaptureDepthFrame: @unchecked Sendable {
    public let depthData: AVDepthData
    public let timestamp: CMTime
    public let source: EnhancedCaptureSource

    /// The float16 depth or disparity map.
    public var depthMap: CVPixelBuffer { depthData.depthDataMap }
}

/// A level reading for an audio-capable source.
public struct EnhancedCaptureAudioLevelUpdate: Sendable {
    public let level: EnhancedCaptureAudioLevel
    public let source: EnhancedCaptureSource
}

/// Everything the delegate reports that is not a media buffer.
public enum EnhancedCaptureEvent: Sendable {
    /// Discovery and permissions resolved; the session runs if allowed.
    case initialized
    /// The list of enableable sources changed.
    case sourcesChanged([EnhancedCaptureSource])
    /// An enabled source changed state.
    case sourceState(EnhancedCaptureSourceState, EnhancedCaptureSource)
    /// A permission resolved.
    case permission(PermissionType, PermissionStatus)
    /// iOS: the session was interrupted or resumed.
    case interruption(EnhancedCaptureSessionInterruption)
    /// A failure; `source` is `nil` for session-wide problems.
    case error(EnhancedCaptureError, EnhancedCaptureSource?)
    /// iOS: the rotation applied to a camera's frames changed.
    case rotation(CGFloat, EnhancedCaptureSource)
}

// MARK: - Façade

/// `EnhancedCaptureKit` for `async` consumers (SwiftUI views, actors).
///
/// ```swift
/// let capture = EnhancedCaptureStreams(configuration: .audioVideo)
/// for await sources in capture.sources {
///     if let camera = sources.first(where: { $0.type == .cameraBack }) {
///         capture.enable(camera)
///         Task {
///             for await frame in capture.videoFrames(for: camera) {
///                 compositor.processIncomingPixelBuffer(pixelBuffer: frame.pixelBuffer!, destinationZone: "main")
///             }
///         }
///     }
/// }
/// ```
///
/// Every stream is independent: subscribe as many times as needed, from any
/// task; each subscription ends when its task is cancelled. Video streams keep
/// only the newest frame, so a slow consumer sees the latest picture rather
/// than a growing backlog.
@available(macOS 10.15, iOS 16.0, *)
public final class EnhancedCaptureStreams: @unchecked Sendable {

    /// The kit behind the streams, for controls (`setZoomFactor`, `session`, …).
    public private(set) var kit: EnhancedCaptureKit!

    /// A conventional delegate that also receives every callback, for mixed
    /// delegate / async consumers.
    public weak var forwardingDelegate: EnhancedCaptureDelegate?

    /// How many frames a video subscription buffers. `1` = newest only.
    public static let videoBufferDepth = 1
    /// How many buffers an audio subscription keeps before dropping the oldest.
    public static let audioBufferDepth = 128
    /// How many events an event subscription keeps before dropping the oldest.
    public static let eventBufferDepth = 64

    private let lock = NSLock()
    private var latestSources: [EnhancedCaptureSource] = []
    private var sourceSubscribers: [UUID: AsyncStream<[EnhancedCaptureSource]>.Continuation] = [:]
    private var eventSubscribers: [UUID: AsyncStream<EnhancedCaptureEvent>.Continuation] = [:]
    private var levelSubscribers: [UUID: AsyncStream<EnhancedCaptureAudioLevelUpdate>.Continuation] = [:]
    private var videoSubscribers: [String: [UUID: AsyncStream<EnhancedCaptureVideoFrame>.Continuation]] = [:]
    private var audioSubscribers: [String: [UUID: AsyncStream<EnhancedCaptureAudioBuffer>.Continuation]] = [:]
    private var depthSubscribers: [String: [UUID: AsyncStream<EnhancedCaptureDepthFrame>.Continuation]] = [:]

    /// Creates the kit and starts discovery, exactly like
    /// `EnhancedCaptureKit(delegate:configuration:)`.
    public init(configuration: EnhancedCaptureConfiguration = .default, forwardingTo delegate: EnhancedCaptureDelegate? = nil) {
        self.forwardingDelegate = delegate
        self.kit = EnhancedCaptureKit(delegate: self, configuration: configuration)
    }

    /// For tests: a façade with no kit behind it. Delegate calls are driven manually.
    init(detached: Void) {}

    deinit {
        lock.lock()
        let all: [() -> Void] = sourceSubscribers.values.map { c in { c.finish() } }
            + eventSubscribers.values.map { c in { c.finish() } }
            + levelSubscribers.values.map { c in { c.finish() } }
            + videoSubscribers.values.flatMap { $0.values }.map { c in { c.finish() } }
            + audioSubscribers.values.flatMap { $0.values }.map { c in { c.finish() } }
            + depthSubscribers.values.flatMap { $0.values }.map { c in { c.finish() } }
        lock.unlock()
        all.forEach { $0() }
    }

    // MARK: Controls

    public func enable(_ source: EnhancedCaptureSource) { kit.enableCapture(for: source) }

    /// Disables and returns once the source has left the session.
    public func disable(_ source: EnhancedCaptureSource) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            kit.disableCapture(for: source) { continuation.resume() }
        }
    }

    /// The most recent source list, without subscribing.
    public var currentSources: [EnhancedCaptureSource] {
        lock.lock(); defer { lock.unlock() }
        return latestSources
    }

    // MARK: Streams

    /// The enableable sources, current list first, then every change.
    public var sources: AsyncStream<[EnhancedCaptureSource]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            sourceSubscribers[id] = continuation
            let current = latestSources
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in self?.remove(source: id) }
        }
    }

    /// Everything except media buffers, in order, bounded to `eventBufferDepth`.
    public var events: AsyncStream<EnhancedCaptureEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(Self.eventBufferDepth)) { continuation in
            let id = UUID()
            lock.lock(); eventSubscribers[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(event: id) }
        }
    }

    /// Audio levels for every metered source (`audioLevelMeteringEnabled`).
    public var audioLevels: AsyncStream<EnhancedCaptureAudioLevelUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock(); levelSubscribers[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(level: id) }
        }
    }

    /// Video frames from `source`, newest frame only. Enable the source separately.
    public func videoFrames(for source: EnhancedCaptureSource) -> AsyncStream<EnhancedCaptureVideoFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(Self.videoBufferDepth)) { continuation in
            let id = UUID()
            lock.lock(); videoSubscribers[source.id, default: [:]][id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(video: id, sourceID: source.id) }
        }
    }

    /// Audio buffers from `source`, bounded to `audioBufferDepth`.
    public func audioBuffers(for source: EnhancedCaptureSource) -> AsyncStream<EnhancedCaptureAudioBuffer> {
        AsyncStream(bufferingPolicy: .bufferingNewest(Self.audioBufferDepth)) { continuation in
            let id = UUID()
            lock.lock(); audioSubscribers[source.id, default: [:]][id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(audio: id, sourceID: source.id) }
        }
    }

    /// Depth maps from `source` (iOS, `depthDataEnabled`), newest only.
    public func depthFrames(for source: EnhancedCaptureSource) -> AsyncStream<EnhancedCaptureDepthFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(Self.videoBufferDepth)) { continuation in
            let id = UUID()
            lock.lock(); depthSubscribers[source.id, default: [:]][id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(depth: id, sourceID: source.id) }
        }
    }

    // MARK: Fan-out (any thread)

    func publish(sources: [EnhancedCaptureSource]) {
        lock.lock()
        latestSources = sources
        let targets = Array(sourceSubscribers.values)
        lock.unlock()
        targets.forEach { $0.yield(sources) }
    }

    func publish(event: EnhancedCaptureEvent) {
        lock.lock(); let targets = Array(eventSubscribers.values); lock.unlock()
        targets.forEach { $0.yield(event) }
    }

    func publish(level: EnhancedCaptureAudioLevel, for source: EnhancedCaptureSource) {
        lock.lock(); let targets = Array(levelSubscribers.values); lock.unlock()
        guard !targets.isEmpty else { return }
        let update = EnhancedCaptureAudioLevelUpdate(level: level, source: source)
        targets.forEach { $0.yield(update) }
    }

    func publish(videoSampleBuffer sampleBuffer: CMSampleBuffer, for source: EnhancedCaptureSource) {
        lock.lock()
        let targets = videoSubscribers[source.id].map { Array($0.values) } ?? []
        lock.unlock()
        guard !targets.isEmpty else { return }
        let frame = EnhancedCaptureVideoFrame(sampleBuffer: sampleBuffer, source: source)
        targets.forEach { $0.yield(frame) }
    }

    func publish(audioSampleBuffer sampleBuffer: CMSampleBuffer, for source: EnhancedCaptureSource) {
        lock.lock()
        let targets = audioSubscribers[source.id].map { Array($0.values) } ?? []
        lock.unlock()
        guard !targets.isEmpty else { return }
        let buffer = EnhancedCaptureAudioBuffer(sampleBuffer: sampleBuffer, source: source)
        targets.forEach { $0.yield(buffer) }
    }

    func publish(depthData: AVDepthData, timestamp: CMTime, for source: EnhancedCaptureSource) {
        lock.lock()
        let targets = depthSubscribers[source.id].map { Array($0.values) } ?? []
        lock.unlock()
        guard !targets.isEmpty else { return }
        let frame = EnhancedCaptureDepthFrame(depthData: depthData, timestamp: timestamp, source: source)
        targets.forEach { $0.yield(frame) }
    }

    /// Subscriber counts, for tests and diagnostics.
    var subscriberCounts: (sources: Int, events: Int, levels: Int, video: Int, audio: Int) {
        lock.lock(); defer { lock.unlock() }
        return (
            sourceSubscribers.count,
            eventSubscribers.count,
            levelSubscribers.count,
            videoSubscribers.values.reduce(0) { $0 + $1.count },
            audioSubscribers.values.reduce(0) { $0 + $1.count }
        )
    }

    // MARK: Unsubscribe

    private func remove(source id: UUID) { lock.lock(); sourceSubscribers.removeValue(forKey: id); lock.unlock() }
    private func remove(event id: UUID) { lock.lock(); eventSubscribers.removeValue(forKey: id); lock.unlock() }
    private func remove(level id: UUID) { lock.lock(); levelSubscribers.removeValue(forKey: id); lock.unlock() }
    private func remove(video id: UUID, sourceID: String) {
        lock.lock()
        videoSubscribers[sourceID]?.removeValue(forKey: id)
        if videoSubscribers[sourceID]?.isEmpty == true { videoSubscribers.removeValue(forKey: sourceID) }
        lock.unlock()
    }
    private func remove(audio id: UUID, sourceID: String) {
        lock.lock()
        audioSubscribers[sourceID]?.removeValue(forKey: id)
        if audioSubscribers[sourceID]?.isEmpty == true { audioSubscribers.removeValue(forKey: sourceID) }
        lock.unlock()
    }
    private func remove(depth id: UUID, sourceID: String) {
        lock.lock()
        depthSubscribers[sourceID]?.removeValue(forKey: id)
        if depthSubscribers[sourceID]?.isEmpty == true { depthSubscribers.removeValue(forKey: sourceID) }
        lock.unlock()
    }
}

// MARK: - EnhancedCaptureDelegate

@available(macOS 10.15, iOS 16.0, *)
extension EnhancedCaptureStreams: EnhancedCaptureDelegate {

    public func enhancedCaptureDidInitialize(_ manager: EnhancedCaptureKit) {
        publish(event: .initialized)
        forwardingDelegate?.enhancedCaptureDidInitialize(manager)
    }

    public func enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {
        publish(videoSampleBuffer: sampleBuffer, for: source)
        forwardingDelegate?.enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: sampleBuffer, source: source)
    }

    public func enhancedCaptureDeviceDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {
        publish(videoSampleBuffer: sampleBuffer, for: source)
        forwardingDelegate?.enhancedCaptureDeviceDidOutputSampleBuffer(sampleBuffer: sampleBuffer, source: source)
    }

    public func captureSourceListDidChange(_ manager: EnhancedCaptureKit, sources: [EnhancedCaptureSource]) {
        publish(sources: sources)
        publish(event: .sourcesChanged(sources))
        forwardingDelegate?.captureSourceListDidChange(manager, sources: sources)
    }

    public func enhancedCapture(_ manager: EnhancedCaptureKit, permissionStatusDidChange type: PermissionType, status: PermissionStatus) {
        publish(event: .permission(type, status))
        forwardingDelegate?.enhancedCapture(manager, permissionStatusDidChange: type, status: status)
    }

    public func enhancedCaptureDidOutputAudioSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {
        publish(audioSampleBuffer: sampleBuffer, for: source)
        forwardingDelegate?.enhancedCaptureDidOutputAudioSampleBuffer(sampleBuffer: sampleBuffer, source: source)
    }

    public func enhancedCapture(_ manager: EnhancedCaptureKit, didUpdateAudioLevel level: EnhancedCaptureAudioLevel, for source: EnhancedCaptureSource) {
        publish(level: level, for: source)
        forwardingDelegate?.enhancedCapture(manager, didUpdateAudioLevel: level, for: source)
    }

    public func enhancedCapture(_ manager: EnhancedCaptureKit, sourceStateDidChange state: EnhancedCaptureSourceState, for source: EnhancedCaptureSource) {
        publish(event: .sourceState(state, source))
        forwardingDelegate?.enhancedCapture(manager, sourceStateDidChange: state, for: source)
    }

    public func enhancedCapture(_ manager: EnhancedCaptureKit, sessionInterruptionDidChange interruption: EnhancedCaptureSessionInterruption) {
        publish(event: .interruption(interruption))
        forwardingDelegate?.enhancedCapture(manager, sessionInterruptionDidChange: interruption)
    }

    public func enhancedCapture(_ manager: EnhancedCaptureKit, didEncounterError error: EnhancedCaptureError, for source: EnhancedCaptureSource?) {
        publish(event: .error(error, source))
        forwardingDelegate?.enhancedCapture(manager, didEncounterError: error, for: source)
    }

    public func enhancedCapture(_ manager: EnhancedCaptureKit, videoRotationAngleDidChange angle: CGFloat, for source: EnhancedCaptureSource) {
        publish(event: .rotation(angle, source))
        forwardingDelegate?.enhancedCapture(manager, videoRotationAngleDidChange: angle, for: source)
    }

    public func enhancedCaptureDidOutputDepthData(depthData: AVDepthData, timestamp: CMTime, source: EnhancedCaptureSource) {
        publish(depthData: depthData, timestamp: timestamp, for: source)
        forwardingDelegate?.enhancedCaptureDidOutputDepthData(depthData: depthData, timestamp: timestamp, source: source)
    }
}
