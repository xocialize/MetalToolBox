//
//  EnhancedCaptureKit.swift
//  EnhancedCaptureKit
//
//  Created by Dustin Nielson on 2/27/26.
//

import Foundation
import AVFoundation
import CoreMedia
import OSLog
import LoggingKit
@_exported import ZoneLayoutGenerator
@_exported import TextureCompositorEngine
@_exported import VideoPlayerKit
#if os(macOS)
import ScreenCaptureKit
import CoreMediaIO
#endif


// MARK: - EnhancedCaptureDelegate Protocol

public protocol EnhancedCaptureDelegate: AnyObject {
    /// Discovery and permission resolution finished; the session is running
    /// when camera access was granted. Always delivered on the main thread,
    /// always after `init` returned.
    func enhancedCaptureDidInitialize(_ manager: EnhancedCaptureKit)

    /// Video from a display (macOS) or from an external device. Delivered on
    /// the source's capture queue at frame rate.
    func enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource)

    /// The set of sources the consumer may enable changed. Main thread.
    func captureSourceListDidChange(_ manager: EnhancedCaptureKit, sources: [EnhancedCaptureSource])

    /// Video from an iOS device connected over USB (macOS). Capture queue.
    func enhancedCaptureDeviceDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource)

    /// A permission the kit needs was resolved. Main thread.
    func enhancedCapture(_ manager: EnhancedCaptureKit, permissionStatusDidChange type: PermissionType, status: PermissionStatus)

    /// Audio from a microphone or a muxed device (HDMI capture card) — requires
    /// `configuration.audioEnabled` and microphone permission — or from a
    /// display with system audio (`configuration.screenAudioEnabled`).
    /// Delivered on the source's audio queue; the buffer is PCM in the
    /// device's native format (read it via `CMSampleBufferGetFormatDescription`).
    func enhancedCaptureDidOutputAudioSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource)

    /// Per-channel peak / average levels for a device source (microphone or
    /// muxed device). Requires `configuration.audioLevelMeteringEnabled`.
    /// Display audio has no meters. Audio queue.
    func enhancedCapture(_ manager: EnhancedCaptureKit, didUpdateAudioLevel level: EnhancedCaptureAudioLevel, for source: EnhancedCaptureSource)

    /// An enabled source started, stopped, was interrupted, or failed. Main thread.
    func enhancedCapture(_ manager: EnhancedCaptureKit, sourceStateDidChange state: EnhancedCaptureSourceState, for source: EnhancedCaptureSource)

    /// iOS / iPadOS: the whole session was interrupted or resumed (background,
    /// Split View without multitasking access, another app took the camera,
    /// thermal pressure). Main thread.
    func enhancedCapture(_ manager: EnhancedCaptureKit, sessionInterruptionDidChange interruption: EnhancedCaptureSessionInterruption)

    /// Something failed that used to be a log line only. `source` is `nil`
    /// for session-wide problems. Main thread.
    func enhancedCapture(_ manager: EnhancedCaptureKit, didEncounterError error: EnhancedCaptureError, for source: EnhancedCaptureSource?)

    /// iOS / iPadOS: the rotation applied to a built-in camera's frames
    /// (0, 90, 180, 270 degrees). Reported once when the camera is discovered
    /// and again on every change. Main thread.
    func enhancedCapture(_ manager: EnhancedCaptureKit, videoRotationAngleDidChange angle: CGFloat, for source: EnhancedCaptureSource)

    /// iOS / iPadOS: depth (LiDAR) or disparity (TrueDepth) for a camera
    /// source with `.depth` in its media. Requires
    /// `configuration.depthDataEnabled`. `depthData.depthDataMap` is a
    /// float16 CVPixelBuffer at the depth sensor's resolution; `timestamp`
    /// matches the video frame it belongs to. Depth queue.
    func enhancedCaptureDidOutputDepthData(depthData: AVDepthData, timestamp: CMTime, source: EnhancedCaptureSource)
}

public extension EnhancedCaptureDelegate {
    func enhancedCaptureDeviceDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {}
    func enhancedCapture(_ manager: EnhancedCaptureKit, permissionStatusDidChange type: PermissionType, status: PermissionStatus) {}
    func enhancedCaptureDidOutputAudioSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {}
    func enhancedCapture(_ manager: EnhancedCaptureKit, didUpdateAudioLevel level: EnhancedCaptureAudioLevel, for source: EnhancedCaptureSource) {}
    func enhancedCapture(_ manager: EnhancedCaptureKit, sourceStateDidChange state: EnhancedCaptureSourceState, for source: EnhancedCaptureSource) {}
    func enhancedCapture(_ manager: EnhancedCaptureKit, sessionInterruptionDidChange interruption: EnhancedCaptureSessionInterruption) {}
    func enhancedCapture(_ manager: EnhancedCaptureKit, didEncounterError error: EnhancedCaptureError, for source: EnhancedCaptureSource?) {}
    func enhancedCapture(_ manager: EnhancedCaptureKit, videoRotationAngleDidChange angle: CGFloat, for source: EnhancedCaptureSource) {}
    func enhancedCaptureDidOutputDepthData(depthData: AVDepthData, timestamp: CMTime, source: EnhancedCaptureSource) {}
}

/// ── Threading contract ────────────────────────────────────────────────
/// Discovery state (`captureScreens` / `captureDevices` / `captureSources` /
/// `enabledSources` / `sourceStates`) is MAIN-ACTOR confined: every mutation
/// path — init-time discovery, screen/device observers, lost-device
/// completions, and the public enable/disable API — funnels onto the main
/// actor, and the `captureSourceListDidChange` / `enhancedCaptureDidInitialize`
/// / state / error delegate callbacks are always delivered there, always AFTER
/// `init(delegate:)` has returned (a callback during init reaches a consumer
/// whose stored reference is still nil). The sample-buffer hot paths (video
/// and audio) never touch those arrays: they route through a lock-guarded
/// snapshot rebuilt on each emit. Session plumbing stays on `sessionQueue`.
/// `@unchecked Sendable` reflects this manual confinement, not an absence of
/// shared state.
///
/// ── Session ownership ─────────────────────────────────────────────────
/// The kit *owns* its `AVCaptureSession` (``session``) rather than being one,
/// so the concrete class can be chosen at construction: an
/// `AVCaptureMultiCamSession` on iPads / iPhones that support it when
/// `configuration.multiCameraEnabled` is set, a plain `AVCaptureSession`
/// otherwise. Consumers that need the session (preview layers, KVO) read it
/// from ``session``.
@available(macOS 10.15, iOS 16.0, *)
public final class EnhancedCaptureKit: NSObject, @unchecked Sendable {

    // MARK: - Properties

    public weak var delegate: EnhancedCaptureDelegate?

    /// Options fixed at construction. See ``EnhancedCaptureConfiguration``.
    public let configuration: EnhancedCaptureConfiguration

    /// The capture session the kit drives. An `AVCaptureMultiCamSession` when
    /// ``isMultiCameraSession`` is true. Mutate it only through the kit.
    public let session: AVCaptureSession

    /// `true` when ``session`` is an `AVCaptureMultiCamSession` and several
    /// built-in cameras can be enabled at once.
    public let isMultiCameraSession: Bool

    /// Whether the session is currently running.
    public var isRunning: Bool { session.isRunning }

    // Internal for access from extension files (EnhancedCaptureObservers.swift)
    var observers: [NSObjectProtocol] = []

    // MARK: - MacOS only ScreenCaptureKit
    #if os(macOS)
    private var captureScreens: [EnhancedCaptureScreen] = []
    #endif

    public var captureSources: [EnhancedCaptureSource] = []
    private var captureDevices: [EnhancedCaptureDevice] = []
    private var testPatternSource: EnhancedCaptureTestPatternSource?

    // Track which sources are currently enabled/capturing
    private var enabledSources: Set<String> = []

    // Last non-idle state reported per source id (main actor). Microphone
    // permission is not cached: `PermissionManager.currentStatus(for:)` is
    // consulted at enable time so a later grant is seen immediately.
    private var sourceStates: [String: EnhancedCaptureSourceState] = [:]

    // Hot-path routing snapshot: the sample-buffer callbacks run on capture
    // queues at frame rate and must not scan `captureDevices` while the main
    // actor mutates it. Rebuilt under the lock on every emit.
    private let routingLock = NSLock()
    private var routingByDeviceUniqueID: [String: EnhancedCaptureSource] = [:]

    private let sessionQueue = DispatchQueue(label: "com.xocialize.MetalToolBox.EnhancedCaptureKit.session", qos: .userInteractive)
    private var permissionManager: PermissionManager?

    // MARK: - Init

    public convenience init(delegate: EnhancedCaptureDelegate) {
        self.init(delegate: delegate, configuration: .default)
    }

    public init(delegate: EnhancedCaptureDelegate, configuration: EnhancedCaptureConfiguration) {
        self.configuration = configuration
        let (session, isMultiCam, multiCamRefused) = Self.makeSession(for: configuration)
        self.session = session
        self.isMultiCameraSession = isMultiCam
        super.init()
        self.delegate = delegate

        #if os(iOS)
        if #unavailable(iOS 17.0) {
            mlog.notice("CaptureKit requires iOS 17.0 or later — current device is unsupported")
            // Even the unsupported path defers: no delegate call before init returns.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.enhancedCaptureDidInitialize(self)
            }
            return
        }
        #endif

        mlog.debug("Initializing with delegate (audio: \(configuration.audioEnabled), multi-camera: \(isMultiCam))")

        setupCaptureKit()

        // ALL discovery + permission resolution is deferred past init. The
        // permission check can resolve synchronously (already authorized or
        // denied) and device discovery emits per device found — either would
        // otherwise call the delegate while the consumer's assignment of this
        // instance is still evaluating.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if multiCamRefused {
                self.report(.multiCameraUnsupported, for: nil)
            }
            // Check permissions — session start is deferred until camera is authorized
            self.permissionManager = PermissionManager(delegate: self)
            self.permissionManager?.checkPermissions(includeMicrophone: self.configuration.audioEnabled)
            // Device discovery (populates device list so sources are ready
            // when the session starts)
            self.refreshDevices()
            if self.configuration.testPatternEnabled {
                self.testPatternSource = EnhancedCaptureTestPatternSource(configuration: self.configuration, delegate: self)
                self.emitCaptureSources()
            }
            #if os(macOS)
            await self.screensDidUpdate()
            #endif
        }

        mlog.debug("Initialization pending permission resolution")
    }

    /// Picks the session class. Multi-camera is iOS-only and needs hardware
    /// support; the third value says the request had to be refused.
    private static func makeSession(for configuration: EnhancedCaptureConfiguration) -> (AVCaptureSession, Bool, Bool) {
        #if os(iOS)
        if configuration.multiCameraEnabled {
            if AVCaptureMultiCamSession.isMultiCamSupported {
                return (AVCaptureMultiCamSession(), true, false)
            }
            mlog.notice("Multi-camera requested but unsupported on this device — single-camera session")
            return (AVCaptureSession(), false, true)
        }
        return (AVCaptureSession(), false, false)
        #else
        return (AVCaptureSession(), false, configuration.multiCameraEnabled)
        #endif
    }

    // MARK: - CaptureKit Setup
    func setupCaptureKit() {
        mlog.debug("Setting up capture components")
        #if os(macOS)
        enableIOSDevices()
        #endif
        enableObservers()
        configureSessionForPlatform()
        // Note: first screens pass + refreshDevices() run from init's deferred
        // main-actor task — never synchronously inside init.
        mlog.debug("Capture components setup complete")
    }

    /// Session-wide options that must be set before `startRunning()`.
    private func configureSessionForPlatform() {
        let config = configuration
        sessionQueue.async { [weak self] in
            guard let self else { return }
            #if os(iOS) || os(tvOS)
            switch config.audioSessionPolicy {
            case .automatic:
                self.session.usesApplicationAudioSession = true
                self.session.automaticallyConfiguresApplicationAudioSession = true
            case .applicationManaged:
                self.session.usesApplicationAudioSession = true
                self.session.automaticallyConfiguresApplicationAudioSession = false
            case .detached:
                self.session.usesApplicationAudioSession = false
            }
            #endif
            #if os(iOS)
            if config.multitaskingCameraAccessEnabled {
                if self.session.isMultitaskingCameraAccessSupported {
                    self.session.isMultitaskingCameraAccessEnabled = true
                    mlog.info("Multitasking camera access enabled")
                } else {
                    mlog.debug("Multitasking camera access unsupported (needs entitlement or voip background mode)")
                }
            }
            #endif
        }
    }

    // MARK: - Main-actor funnel

    /// Runs `body` isolated to the main actor: synchronously when already on
    /// the main thread (preserving the pre-existing call-site ordering for
    /// main-thread callers), else hopping via a Task. The `#available` guard
    /// exists only for the iOS 16 slice (assumeIsolated is iOS 17+); the kit
    /// itself already requires iOS 17 at runtime.
    func runOnMainActor(_ body: @escaping @MainActor @Sendable (EnhancedCaptureKit) -> Void) {
        if Thread.isMainThread, #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            MainActor.assumeIsolated { body(self) }
        } else {
            Task { @MainActor in body(self) }
        }
    }

    // MARK: - State / error reporting (main actor)

    @MainActor
    private func setState(_ state: EnhancedCaptureSourceState, for source: EnhancedCaptureSource) {
        // `.idle` is the absent-key state, so a late `.idle` from an async stop
        // never resurrects an entry for a source that was already forgotten.
        if case .idle = state {
            sourceStates.removeValue(forKey: source.id)
        } else {
            sourceStates[source.id] = state
        }
        delegate?.enhancedCapture(self, sourceStateDidChange: state, for: source)
    }

    @MainActor
    private func report(_ error: EnhancedCaptureError, for source: EnhancedCaptureSource?) {
        mlog.error("\(error.description)\(source.map { " [\($0.displayName)]" } ?? "")")
        delegate?.enhancedCapture(self, didEncounterError: error, for: source)
    }

    /// Drops a source that could not start: forgets it, reports the error and
    /// publishes the `.error` state.
    @MainActor
    private func fail(_ source: EnhancedCaptureSource, with error: EnhancedCaptureError) {
        enabledSources.remove(source.id)
        report(error, for: source)
        setState(.error(error), for: source)
    }

    /// Removes every trace of a source that went away (device unplugged,
    /// display disconnected) and tells the consumer it is idle if it was enabled.
    @MainActor
    private func forget(_ source: EnhancedCaptureSource) {
        let wasEnabled = enabledSources.remove(source.id) != nil
        sourceStates.removeValue(forKey: source.id)
        if wasEnabled {
            delegate?.enhancedCapture(self, sourceStateDidChange: .idle, for: source)
        }
    }

    /// Runs a device control against the tracked device behind `source`,
    /// mapping every failure onto `didEncounterError`.
    @MainActor
    private func withTrackedDevice(for source: EnhancedCaptureSource, _ body: (EnhancedCaptureDevice) throws -> Void) {
        guard let device = trackedDevice(for: source) else {
            return report(.sourceUnavailable(source.id), for: source)
        }
        do { try body(device) }
        catch let error as EnhancedCaptureError { report(error, for: source) }
        catch { report(.deviceConfigurationFailed(reason: error.localizedDescription), for: source) }
    }

    /// The last state reported for a source, or `.idle` if it was never enabled.
    @MainActor
    public func state(for source: EnhancedCaptureSource) -> EnhancedCaptureSourceState {
        sourceStates[source.id] ?? .idle
    }

    // MARK: - Capture enable/disable

    // Public wrappers keep the pre-confinement signatures (callable from any
    // thread); the isolated implementations own the state. Main-thread callers
    // run synchronously, exactly as before.

    public func enableCapture(for source: EnhancedCaptureSource) {
        runOnMainActor { $0.enableCaptureIsolated(for: source) }
    }

    public func disableCapture(for source: EnhancedCaptureSource) {
        runOnMainActor { $0.disableCaptureIsolated(for: source, completion: nil) }
    }

    /// Disables capture for the given source with a completion callback.
    /// Use this when you need to sequence stop→start (e.g., iOS device switching where
    /// macOS limits capture to one iOS device at a time).
    /// The completion fires on the main thread after the device has been fully removed from the session.
    public func disableCapture(for source: EnhancedCaptureSource, completion: @escaping @Sendable () -> Void) {
        runOnMainActor { $0.disableCaptureIsolated(for: source, completion: completion) }
    }

    @MainActor
    private func enableCaptureIsolated(for source: EnhancedCaptureSource) {
        // Check if already enabled to prevent duplicate additions
        guard !enabledSources.contains(source.id) else {
            mlog.debug("Capture already enabled for: \(source.displayName)")
            return
        }

        // Mark as enabled IMMEDIATELY before async operations to prevent race conditions
        enabledSources.insert(source.id)

        mlog.info("Enabling capture for source: \(source.displayName) (type: \(String(describing: source.type)))")

        switch source.type {
        case .screen, .screenMain:
            #if os(macOS)
            guard let captureScreen = trackedScreen(for: source) else {
                enabledSources.remove(source.id)
                report(.sourceUnavailable(source.id), for: source)
                return
            }

            // Start the screen capture (state arrives via EnhancedCaptureScreenDelegate)
            captureScreen.startCapture()
            mlog.info("Started screen capture for: \(source.displayName)")
            #else
            enabledSources.remove(source.id)
            report(.platformUnsupported(feature: "screen capture"), for: source)
            #endif

        case .externalDevice, .iOSDevice, .cameraFront, .cameraBack, .microphone:
            guard let captureDevice = trackedDevice(for: source) else {
                enabledSources.remove(source.id)
                report(.sourceUnavailable(source.id), for: source)
                return
            }

            // Audio capture rides along only with microphone permission. A
            // request that is still pending (first launch: the camera prompt
            // resolves first) is not a denial — the source stays enabled and
            // its audio is attached when the permission resolves.
            var includeAudio = false
            if source.hasAudio {
                switch PermissionManager.currentStatus(for: .microphone) {
                case .authorized:
                    includeAudio = true
                case .notDetermined:
                    mlog.info("Microphone permission pending — audio for \(source.displayName) attaches when granted")
                    if !source.hasVideo { return }
                case .denied, .restricted:
                    report(.permissionDenied(.microphone), for: source)
                    if !source.hasVideo {
                        enabledSources.remove(source.id)
                        return
                    }
                }
            }

            addDeviceToSession(captureDevice, includeAudio: includeAudio, source: source)

        case .testPattern:
            guard let generator = testPatternSource, generator.captureSource.id == source.id else {
                enabledSources.remove(source.id)
                report(.sourceUnavailable(source.id), for: source)
                return
            }
            if let error = generator.start() {
                fail(source, with: error)
            } else {
                setState(.capturing, for: source)
            }
        }
    }

    /// Adds a tracked device to the session and mirrors the result onto the
    /// source's state. Shared by `enableCapture` and the microphone grant that
    /// starts a source deferred at enable time.
    @MainActor
    private func addDeviceToSession(_ captureDevice: EnhancedCaptureDevice, includeAudio: Bool, source: EnhancedCaptureSource) {
        addToSession(captureDevice: captureDevice, includeAudio: includeAudio) { [weak self] error in
            guard let self else { return }
            self.runOnMainActor { kit in
                guard kit.enabledSources.contains(source.id) else { return }
                if let error {
                    kit.fail(source, with: error)
                } else {
                    kit.setState(.capturing, for: source)
                }
            }
        }
        mlog.info("Requested device to be added to session: \(source.displayName)")
    }

    /// Attaches audio to every enabled audio-capable source that was added (or
    /// held back) while the microphone permission was still pending.
    @MainActor
    private func attachAudioToEnabledSources() {
        for source in captureSources where enabledSources.contains(source.id) && source.hasAudio {
            guard let device = trackedDevice(for: source) else { continue }
            sessionQueue.async { [weak self] in
                guard let self else { return }
                let inputInSession = device.input.map { self.session.inputs.contains($0) } ?? false
                if inputInSession {
                    // Video is already flowing; just add the audio leg.
                    self.session.beginConfiguration()
                    let attached = self.attach(device.dataAudioOutput, device.audioConnection, label: "audio data")
                    self.session.commitConfiguration()
                    if attached { mlog.info("Attached audio to \(source.displayName) after microphone grant") }
                } else {
                    // A microphone-only source held back at enable time.
                    self.runOnMainActor { kit in
                        guard kit.enabledSources.contains(source.id) else { return }
                        kit.addDeviceToSession(device, includeAudio: true, source: source)
                    }
                }
            }
        }
    }

    @MainActor
    private func disableCaptureIsolated(for source: EnhancedCaptureSource, completion: (@Sendable () -> Void)?) {
        mlog.info("Disabling capture for source: \(source.displayName) (type: \(String(describing: source.type)))")

        // Remove from enabled sources set
        enabledSources.remove(source.id)

        switch source.type {
        case .screen, .screenMain:
            #if os(macOS)
            guard let captureScreen = trackedScreen(for: source) else {
                report(.sourceUnavailable(source.id), for: source)
                completion?()
                return
            }
            captureScreen.stopCapture()
            mlog.info("Stopped screen capture for: \(source.displayName)")
            completion?()
            #else
            report(.platformUnsupported(feature: "screen capture"), for: source)
            completion?()
            #endif

        case .externalDevice, .iOSDevice, .cameraFront, .cameraBack, .microphone:
            guard let captureDevice = trackedDevice(for: source) else {
                report(.sourceUnavailable(source.id), for: source)
                completion?()
                return
            }

            removeFromSession(captureDevice: captureDevice) { [weak self] in
                mlog.info("Removed device from session: \(source.displayName)")
                self?.runOnMainActor { $0.setState(.idle, for: source) }
                completion?()
            }

        case .testPattern:
            testPatternSource?.stop()
            setState(.idle, for: source)
            completion?()
        }
    }

    // MARK: - Session Management

    /// Adds the device on the session queue. `completion` receives `nil` on
    /// success or the error that left the session unchanged.
    private func addToSession(captureDevice: EnhancedCaptureDevice, includeAudio: Bool, completion: @escaping @Sendable (EnhancedCaptureError?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.session.beginConfiguration()
            let added = self.attachDevice(captureDevice, includeAudio: includeAudio)
            // Commit before reporting, so `.capturing` never reaches the
            // consumer while the (possibly lengthy) pipeline reconfiguration
            // is still in progress.
            self.session.commitConfiguration()

            guard added else {
                completion(.captureStartFailed(reason: "could not add device to session"))
                return
            }

            #if os(iOS)
            // A multi-camera session computes its hardware budget on commit.
            // Over budget it would run briefly and then be interrupted, so take
            // the camera back out and tell the consumer why.
            if let multiCam = self.session as? AVCaptureMultiCamSession {
                let hardware = multiCam.hardwareCost
                let pressure = multiCam.systemPressureCost
                mlog.info("Multi-camera cost after adding \(captureDevice.device.localizedName): hardware \(hardware), system pressure \(pressure)")
                if hardware > 1.0 || pressure > 1.0 {
                    multiCam.beginConfiguration()
                    self.detachDevice(captureDevice)
                    multiCam.commitConfiguration()
                    completion(.multiCameraHardwareCostExceeded(hardwareCost: hardware, systemPressureCost: pressure))
                    return
                }
            }
            #endif

            completion(nil)
        }
    }

    /// Session-queue only, inside begin/commitConfiguration. Adds the input and
    /// every output the device prepared. On total failure the session is left
    /// exactly as it was found.
    private func attachDevice(_ captureDevice: EnhancedCaptureDevice, includeAudio: Bool) -> Bool {
        guard let input = captureDevice.input, session.canAddInput(input) else {
            mlog.error("Failed to add input for device")
            return false
        }

        // Add input WITHOUT automatic connections
        session.addInputWithNoConnections(input)

        // iOS / tvOS reset the device format when the input joins; put the
        // preference back while still inside begin/commitConfiguration. A
        // multi-camera session additionally needs a multi-cam-capable format.
        #if os(iOS) || os(tvOS)
        captureDevice.reapplyVideoPreference(multiCamera: isMultiCameraSession)
        #endif

        var addedAnything = attach(captureDevice.dataVideoOutput, captureDevice.videoConnection, label: "video")
        #if os(iOS)
        if captureDevice.deliversDepth {
            // Depth is a bonus on top of video; its failure never fails the device.
            _ = attach(captureDevice.depthDataOutput, captureDevice.depthConnection, label: "depth")
        }
        #endif
        if includeAudio {
            addedAnything = attach(captureDevice.dataAudioOutput, captureDevice.audioConnection, label: "audio data") || addedAnything
        }
        #if os(macOS)
        // Speaker preview is not capture: attached whenever the device prepared
        // one, independent of the microphone permission (historical behaviour).
        addedAnything = attach(captureDevice.audioPreview, captureDevice.audioPreviewConnection, label: "audio preview") || addedAnything
        #endif

        if !addedAnything {
            // Nothing usable — each failed `attach` already undid its output;
            // don't leave a dangling input either.
            session.removeInput(input)
            return false
        }

        mlog.debug("Successfully added device to session")
        return true
    }

    /// Session-queue only, inside begin/commitConfiguration. Adds `output` and
    /// its manual `connection` as a unit: a connection the session refuses
    /// removes the output again, so a failed enable never strands an output
    /// that would make every later `canAddOutput` — and so every retry — fail.
    /// An output that is already attached counts as success.
    @discardableResult
    private func attach(_ output: AVCaptureOutput?, _ connection: AVCaptureConnection?, label: String) -> Bool {
        guard let output, let connection else { return false }

        let outputWasPresent = session.outputs.contains(output)
        if outputWasPresent {
            if session.connections.contains(connection) { return true }
        } else {
            guard session.canAddOutput(output) else {
                mlog.error("Failed to add \(label) output")
                return false
            }
            session.addOutputWithNoConnections(output)
        }

        guard session.canAddConnection(connection) else {
            mlog.error("Failed to add \(label) connection")
            if !outputWasPresent { session.removeOutput(output) }
            return false
        }
        session.addConnection(connection)
        mlog.debug("Added \(label) connection")
        return true
    }

    private func removeFromSession(captureDevice: EnhancedCaptureDevice, completion: @escaping @Sendable () -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.session.beginConfiguration()
            self.detachDevice(captureDevice)
            self.session.commitConfiguration()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    /// Session-queue only, inside begin/commitConfiguration. Removes only what
    /// is still in the session — AVFoundation may have auto-removed an
    /// unplugged device already.
    private func detachDevice(_ captureDevice: EnhancedCaptureDevice) {
        var connections: [(AVCaptureConnection?, String)] = [
            (captureDevice.videoConnection, "video"),
            (captureDevice.audioConnection, "audio data"),
        ]
        var outputs: [(AVCaptureOutput?, String)] = [
            (captureDevice.dataVideoOutput, "video"),
            (captureDevice.dataAudioOutput, "audio data"),
        ]
        #if os(macOS)
        connections.append((captureDevice.audioPreviewConnection, "audio preview"))
        outputs.append((captureDevice.audioPreview, "audio preview"))
        #endif
        #if os(iOS)
        connections.append((captureDevice.depthConnection, "depth"))
        outputs.append((captureDevice.depthDataOutput, "depth"))
        #endif

        for case (let connection?, let label) in connections where session.connections.contains(connection) {
            session.removeConnection(connection)
            mlog.debug("Removed \(label) connection")
        }
        for case (let output?, let label) in outputs where session.outputs.contains(output) {
            session.removeOutput(output)
            mlog.debug("Removed \(label) output")
        }
        if let input = captureDevice.input, session.inputs.contains(input) {
            session.removeInput(input)
            mlog.debug("Removed input")
        }

        mlog.debug("Successfully removed device from session")
    }

    /// Starts the session on the session queue if it is not already running.
    /// Used when a microphone-only configuration (camera denied or absent)
    /// still needs a running session.
    private func startSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            mlog.info("Session started running")
        }
    }

    /// Stops and restarts the session on the session queue. Also used after
    /// `AVError.mediaServicesWereReset`.
    public func restartSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.startRunning()
            mlog.notice("Session restarted")
        }
    }

    // MARK: - Runtime errors / interruptions (main actor)

    @MainActor
    func handleRuntimeError(_ error: NSError?) {
        let reason = error?.localizedDescription ?? "unknown"
        // AVErrorMediaServicesWereReset (-11819). The Swift enum case is
        // marked unavailable on macOS, so compare the raw code.
        let isMediaServicesReset = error?.domain == AVFoundationErrorDomain
            && error?.code == -11819
        let willRestart = isMediaServicesReset && configuration.restartsAfterMediaServicesReset
        report(.sessionRuntimeError(reason: reason, willRestart: willRestart), for: nil)
        if willRestart { restartSession() }
    }

    @MainActor
    func handleSessionInterruption(_ interruption: EnhancedCaptureSessionInterruption) {
        switch interruption {
        case .began(let reason):
            mlog.warning("Session interrupted: \(String(describing: reason))")
        case .ended:
            mlog.info("Session interruption ended")
        }
        delegate?.enhancedCapture(self, sessionInterruptionDidChange: interruption)

        // Mirror onto every enabled device source so per-source UI follows.
        let newState: EnhancedCaptureSourceState = (interruption == .ended) ? .capturing : .interrupted
        for source in captureSources where enabledSources.contains(source.id) {
            switch source.type {
            case .screen, .screenMain, .testPattern: continue
            default: setState(newState, for: source)
            }
        }
    }

    // MARK: - Screen Discovery
#if os(macOS)
    private var isUpdatingScreens = false

    @MainActor
    func screensDidUpdate() async {
        // Prevent concurrent calls to this method
        guard !isUpdatingScreens else {
            mlog.debug("Screens update already in progress, skipping")
            return
        }

        isUpdatingScreens = true
        defer { isUpdatingScreens = false }

        // Get list of active display IDs from existing capture screens
        let activeDisplays = captureScreens.compactMap { $0.displayID }

        mlog.debug("Screens updated. Active displays: \(activeDisplays)")

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            mlog.error("Failed to get shareable content: \(error.localizedDescription)")
            return
        }

        // Get current display IDs from shareable content
        let currentDisplayIds = Set(content.displays.map { $0.displayID })
        let activeDisplaySet = Set(activeDisplays)

        // Check each display in content.displays
        for display in content.displays {
            // If display is not in activeDisplays, it's new - call screenFound
            if !activeDisplaySet.contains(display.displayID) {
                screenFound(displayId: display.displayID)
            }
            // If display exists in activeDisplays, skip (no action needed)
        }

        // Check if any activeDisplays are no longer in content.displays
        for displayId in activeDisplays {
            if !currentDisplayIds.contains(displayId) {
                screenLost(displayId: displayId)
            }
        }

    }

    @MainActor
    private func screenFound(displayId: CGDirectDisplayID) {
        // Double-check that this display isn't already in the array
        guard !captureScreens.contains(where: { $0.displayID == displayId }) else {
            mlog.debug("Display \(displayId) already exists in captureScreens, skipping")
            return
        }

        mlog.info("Found new display: \(displayId)")
        var options = EnhancedCaptureScreen.Options()
        options.frameRate = configuration.screenFrameRate
        options.showsCursor = configuration.screenShowsCursor
        // Display audio is governed by Screen Recording permission, not the
        // microphone, so it does not depend on `audioEnabled`.
        options.capturesAudio = configuration.screenAudioEnabled && configuration.deliversAudioSampleBuffers
        options.pixelFormat = configuration.pixelFormat.coreVideoType
        let newCapture = EnhancedCaptureScreen(delegate: self, displayId: displayId, options: options)
        guard let _ = newCapture.captureSource else {
            mlog.error("Failed to create capture source for display \(displayId)")
            return
        }
        captureScreens.append(newCapture)
        mlog.debug("Added screen to captureScreens array. Total screens: \(self.captureScreens.count)")
        emitCaptureSources()
    }
    @MainActor
    private func screenLost(displayId: CGDirectDisplayID) {
        mlog.info("Lost display: \(displayId)")

        // Find the index of the capture screen with matching displayID
        guard let index = captureScreens.firstIndex(where: { $0.displayID == displayId }) else {
            mlog.error("Could not find capture screen with display ID: \(displayId)")
            return
        }

        // Get the capture screen before removing it
        let captureScreen = captureScreens[index]

        // Stop capture with completion — ensures the stream is fully stopped before
        // the screen is removed from the array and deallocated. The completion
        // arrives on the stream's own queue; state mutation hops back to main.
        captureScreen.stopCapture { [weak self] in
            guard let self = self else { return }
            self.runOnMainActor { kit in
                // Remove the capture source from the sources array if it exists
                if let captureSource = captureScreen.captureSource {
                    kit.captureSources.removeAll { $0.id == captureSource.id }
                    kit.forget(captureSource)
                    mlog.debug("Removed capture source: \(captureSource.displayName)")
                }

                // Remove from the array (this releases the strong reference)
                kit.captureScreens.removeAll { $0.displayID == displayId }

                mlog.debug("Successfully removed screen capture for display: \(displayId)")

                kit.emitCaptureSources()
            }
        }
    }
#endif

    @MainActor
    func emitCaptureSources() {
        var emittableList = [EnhancedCaptureSource]()
        var seenIDs = Set<String>()

        // Debug: Log current state of arrays
        #if os(macOS)
        mlog.debug("Emitting sources — screens: \(self.captureScreens.count), devices: \(self.captureDevices.count)")
        for (index, screen) in captureScreens.enumerated() {
            if let source = screen.captureSource {
                mlog.debug("  Screen[\(index)]: \(source.displayName)")
            }
        }
        #else
        mlog.debug("Emitting sources — devices: \(self.captureDevices.count)")
        #endif
        for (index, device) in captureDevices.enumerated() {
            if let source = device.captureSource {
                mlog.debug("  Device[\(index)]: \(source.displayName)")
            }
        }

        // Add screen sources
        #if os(macOS)
        for screen in captureScreens {
            if let captureSource = screen.captureSource,
               !seenIDs.contains(captureSource.id) {
                emittableList.append(captureSource)
                seenIDs.insert(captureSource.id)
            } else if let captureSource = screen.captureSource {
                mlog.debug("Skipping duplicate screen source: \(captureSource.displayName)")
            }
        }
        #endif

        // Add device sources
        for device in captureDevices {
            if let captureSource = device.captureSource,
               !seenIDs.contains(captureSource.id) {
                emittableList.append(captureSource)
                seenIDs.insert(captureSource.id)
            } else if let captureSource = device.captureSource {
                mlog.debug("Skipping duplicate device source: \(captureSource.displayName)")
            }
        }

        // Synthetic source, when configured
        if let generatorSource = testPatternSource?.captureSource, !seenIDs.contains(generatorSource.id) {
            emittableList.append(generatorSource)
            seenIDs.insert(generatorSource.id)
        }

        // Update the captureSources array
        captureSources = emittableList

        // Rebuild the hot-path routing snapshot (read by the sample-buffer
        // callbacks on capture queues — they must never scan the live arrays).
        var routing: [String: EnhancedCaptureSource] = [:]
        for device in captureDevices {
            if let source = device.captureSource {
                routing[device.device.uniqueID] = source
            }
        }
        routingLock.lock()
        routingByDeviceUniqueID = routing
        routingLock.unlock()

        mlog.debug("Emitting \(emittableList.count) unique capture source(s)")
        for (index, source) in emittableList.enumerated() {
            mlog.debug("  [\(index + 1)] \(source.displayName) (type: \(String(describing: source.type)))")
        }

        guard let delegate else {
            mlog.error("No delegate to emit capture sources to")
            return
        }
        delegate.captureSourceListDidChange(self, sources: emittableList)
    }

    // MARK: - Device Discovery

    private func availableDevices() -> [AVCaptureDevice] {
        let videoDeviceTypes: [AVCaptureDevice.DeviceType]
        #if os(iOS)
        if #available(iOS 17.0, *) {
            videoDeviceTypes = [.external, .builtInWideAngleCamera]
        } else {
            videoDeviceTypes = [.builtInWideAngleCamera]
        }
        #else
        videoDeviceTypes = [.external, .builtInWideAngleCamera]
        #endif

        let videoDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices

        let muxedDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: videoDeviceTypes,
            mediaType: .muxed,
            position: .unspecified
        ).devices

        var audioDevices: [AVCaptureDevice] = []
        if configuration.audioEnabled {
            let audioDeviceTypes: [AVCaptureDevice.DeviceType]
            if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
                audioDeviceTypes = [.microphone, .external]
            } else {
                #if os(tvOS)
                audioDeviceTypes = []
                #else
                audioDeviceTypes = [.builtInMicrophone]
                #endif
            }
            if !audioDeviceTypes.isEmpty {
                audioDevices = AVCaptureDevice.DiscoverySession(
                    deviceTypes: audioDeviceTypes,
                    mediaType: .audio,
                    position: .unspecified
                ).devices
            }
        }

        // Combine and remove duplicates based on uniqueID
        var uniqueDevices: [AVCaptureDevice] = []
        var seenIDs = Set<String>()

        for device in videoDevices + muxedDevices + audioDevices {
            if !seenIDs.contains(device.uniqueID) {
                uniqueDevices.append(device)
                seenIDs.insert(device.uniqueID)
            }
        }

        return uniqueDevices
    }

    @MainActor
    private func refreshDevices() {
        let devices = availableDevices()
        mlog.debug("Found \(devices.count) available capture device(s)")
        devices.forEach { device in
            #if os(macOS)
            mlog.debug("  - \(device.localizedName) (Model: \(device.modelID), Manufacturer: \(device.manufacturer))")
            #else
            mlog.debug("  - \(device.localizedName) (Model: \(device.modelID))")
            #endif
            deviceFound(device: device)
        }
        if devices.isEmpty {
            mlog.debug("No capture devices found — screen capture will be used")
        }
    }

    // MARK: - iOS Device Management (macOS only - enables iOS device capture via USB)

    #if os(macOS)
    private func enableIOSDevices() {
        setIOSDeviceAccess(enabled: true)
    }

    private func disableIOSDevices() {
        setIOSDeviceAccess(enabled: false)
    }

    private func setIOSDeviceAccess(enabled: Bool) {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var allow: UInt32 = enabled ? 1 : 0
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &prop,
            0,
            nil,
            UInt32(MemoryLayout.size(ofValue: allow)),
            &allow
        )
    }
    #endif

    // MARK: - Device Event Handlers

    // Internal for access from extension files (EnhancedCaptureObservers.swift)
    @MainActor
    func deviceFound(device: AVCaptureDevice) {
        // Check if device already exists in the array
        if captureDevices.contains(where: { $0.device.uniqueID == device.uniqueID }) {
            mlog.debug("Device already exists, skipping: \(device.localizedName)")
            return
        }

        #if os(macOS)
        mlog.info("Found new device: \(device.localizedName) (model: \(device.modelID), manufacturer: \(device.manufacturer), transport: \(device.transportType))")
        #else
        mlog.info("Found new device: \(device.localizedName) (model: \(device.modelID))")
        #endif
        mlog.debug("  video: \(device.hasMediaType(.video)), audio: \(device.hasMediaType(.audio)), muxed: \(device.hasMediaType(.muxed))")

        let isVideoCapable = device.hasMediaType(.video) || device.hasMediaType(.muxed)

        // Audio-only devices become microphone sources only when audio is on.
        if !isVideoCapable && !(configuration.audioEnabled && device.hasMediaType(.audio)) {
            mlog.debug("Skipping audio-only device (audio disabled): \(device.localizedName)")
            return
        }

        // Create new capture device
        let captureDevice = EnhancedCaptureDevice(device: device, delegate: self, configuration: configuration)

        // Verify capture source was created
        guard let captureSource = captureDevice.captureSource else {
            mlog.error("Failed to create capture source for device: \(device.localizedName)")
            return
        }

        // Double-check again before adding (in case of race condition)
        guard !captureDevices.contains(where: { $0.device.uniqueID == device.uniqueID }) else {
            mlog.debug("Race condition: device was added while creating, skipping: \(device.localizedName)")
            return
        }

        // Same physical device advertised twice with different IDs: keep one.
        // Compared within the same media kind — a capture card's separate
        // audio endpoint often shares the video endpoint's name.
        if captureDevices.contains(where: {
            $0.captureSource?.displayName == captureSource.displayName &&
            $0.captureSource?.manufacturer == captureSource.manufacturer &&
            $0.captureSource?.hasVideo == captureSource.hasVideo
        }) {
            mlog.debug("Duplicate device name, skipping: \(captureSource.displayName) from \(captureSource.manufacturer)")
            return
        }

        // Add to devices array
        captureDevices.append(captureDevice)
        mlog.debug("Added device. Total devices: \(self.captureDevices.count) (type: \(String(describing: captureSource.type)), media: \(String(describing: captureSource.media)))")

        // Emit updated sources list
        emitCaptureSources()

        #if os(iOS)
        // The rotation KVO fired inside the device's init, before it was
        // routable; replay the starting angle now that the consumer can map it.
        if let angle = captureDevice.videoRotationAngle {
            delegate?.enhancedCapture(self, videoRotationAngleDidChange: angle, for: captureSource)
        }
        #endif
    }

    // Internal for access from extension files (EnhancedCaptureObservers.swift)
    @MainActor
    func deviceLost(device: AVCaptureDevice) {
        mlog.info("Device lost: \(device.localizedName) (model: \(device.modelID))")

        // Find the capture device with matching uniqueID
        guard let captureDevice = captureDevices.first(where: { $0.device.uniqueID == device.uniqueID }) else {
            mlog.debug("Lost device was not tracked: \(device.localizedName)")
            return
        }

        // Capture the source BEFORE removal — prepareForRemoval() may nil references
        let source = captureDevice.captureSource
        let deviceUniqueID = device.uniqueID

        // Remove observers IMMEDIATELY — prevents stale callbacks from firing
        // during the async session removal below
        captureDevice.removeObservers()

        // Remove device from session if it's currently active. The completion
        // arrives via DispatchQueue.main.async from sessionQueue; state
        // mutation re-enters main-actor isolation through the funnel.
        removeFromSession(captureDevice: captureDevice) { [weak self] in
            guard let self = self else { return }
            self.runOnMainActor { kit in
                // Prepare device for removal (clears connections, components — observers already removed)
                captureDevice.prepareForRemoval()

                // Remove from the array by uniqueID (safer than index which may shift)
                kit.captureDevices.removeAll { $0.device.uniqueID == deviceUniqueID }

                // Clean up enabledSources so the device can be re-enabled on reconnect.
                // Without this, enableCapture() would see the stale ID and no-op,
                // preventing frames from flowing after a disconnect/reconnect cycle.
                if let source {
                    kit.forget(source)
                    mlog.debug("Cleared enabledSources for disconnected device")
                }

                mlog.debug("Successfully removed device. Total devices: \(kit.captureDevices.count)")

                // Emit updated sources list
                kit.emitCaptureSources()
            }
        }
    }

    // MARK: - Hot-path routing

    private func routedSource(for uniqueID: String) -> EnhancedCaptureSource? {
        routingLock.lock()
        defer { routingLock.unlock() }
        return routingByDeviceUniqueID[uniqueID]
    }

    @MainActor
    private func trackedDevice(for source: EnhancedCaptureSource) -> EnhancedCaptureDevice? {
        captureDevices.first { $0.device.uniqueID == source.uniqueID }
    }

    #if os(macOS)
    @MainActor
    private func trackedScreen(for source: EnhancedCaptureSource) -> EnhancedCaptureScreen? {
        captureScreens.first { $0.captureSource?.id == source.id }
    }
    #endif
}

// MARK: - Camera & audio controls

@available(macOS 10.15, iOS 16.0, *)
public extension EnhancedCaptureKit {

    /// Sets the zoom factor of a camera source (clamped to the device's range).
    @MainActor
    func setZoomFactor(_ factor: CGFloat, for source: EnhancedCaptureSource) {
        withTrackedDevice(for: source) { try $0.setZoomFactor(factor) }
    }

    /// Sets the torch (flashlight) mode of a camera source that has one.
    @MainActor
    func setTorchMode(_ mode: AVCaptureDevice.TorchMode, for source: EnhancedCaptureSource) {
        withTrackedDevice(for: source) { try $0.setTorchMode(mode) }
    }

    /// Focuses and exposes at a normalized point (landscape sensor space),
    /// keeping continuous focus / exposure where the device supports it.
    @MainActor
    func setFocusAndExposurePoint(_ point: CGPoint, for source: EnhancedCaptureSource) {
        withTrackedDevice(for: source) { try $0.setFocusAndExposurePoint(point) }
    }

    /// Center Stage is a system-wide switch on the front camera (iPad,
    /// Continuity Camera). Puts control in app mode and toggles it.
    static func setCenterStageEnabled(_ enabled: Bool) {
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = enabled
    }

    /// Whether Center Stage is currently on.
    static var isCenterStageEnabled: Bool { AVCaptureDevice.isCenterStageEnabled }

    /// Whether this device can run several built-in cameras at once
    /// (`AVCaptureMultiCamSession.isMultiCamSupported`). Always `false` on macOS.
    static var isMultiCameraSupported: Bool {
        #if os(iOS)
        return AVCaptureMultiCamSession.isMultiCamSupported
        #else
        return false
        #endif
    }

    #if os(iOS) || os(tvOS)
    /// Audio inputs the shared `AVAudioSession` can route from (built-in mic,
    /// USB-C interface, Bluetooth headset). The kit's single microphone
    /// source follows whichever is preferred.
    func availableAudioInputs() -> [AVAudioSessionPortDescription] {
        AVAudioSession.sharedInstance().availableInputs ?? []
    }

    /// Routes microphone capture through `port` (`nil` restores the system default).
    func setPreferredAudioInput(_ port: AVAudioSessionPortDescription?) throws {
        try AVAudioSession.sharedInstance().setPreferredInput(port)
    }
    #endif
}

// MARK: - EnhancedCaptureScreenDelegate

#if os(macOS)
extension EnhancedCaptureKit: EnhancedCaptureScreenDelegate {
    func enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {
        guard let delegate else {
            mlog.error("CaptureKitScreenDelegate: no delegate found")
            return
        }
        delegate.enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: sampleBuffer, source: source)
    }

    func enhancedCaptureScreenDidOutputAudioSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {
        delegate?.enhancedCaptureDidOutputAudioSampleBuffer(sampleBuffer: sampleBuffer, source: source)
    }

    func enhancedCaptureScreen(_ screen: EnhancedCaptureScreen, didChangeState state: EnhancedCaptureSourceState) {
        guard let source = screen.captureSource else { return }
        runOnMainActor { kit in
            switch state {
            case .capturing where !kit.enabledSources.contains(source.id):
                // Disabled while the asynchronous start was still in flight:
                // that disable found no stream to stop. Now there is one.
                mlog.info("Screen \(source.displayName) started after being disabled — stopping it")
                screen.stopCapture()
            case .error(let error):
                kit.fail(source, with: error)
            default:
                kit.setState(state, for: source)
            }
        }
    }
}
#endif

// MARK: - EnhancedCaptureTestPatternSourceDelegate

extension EnhancedCaptureKit: EnhancedCaptureTestPatternSourceDelegate {
    func testPatternSource(_ source: EnhancedCaptureTestPatternSource, didOutput sampleBuffer: CMSampleBuffer) {
        // Same path as an external device: a video source the consumer enabled.
        delegate?.enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: sampleBuffer, source: source.captureSource)
    }
}

// MARK: - EnhancedCaptureDeviceDelegate

extension EnhancedCaptureKit: EnhancedCaptureDeviceDelegate {
    func deviceVideoBuffer(model: String, sampleBuffer: CMSampleBuffer, uniqueID: String) {
        guard let delegate else {
            mlog.error("CaptureKitDeviceDelegate: no delegate found")
            return
        }

        // Frame-rate hot path on a capture callback queue: route via the
        // lock-guarded snapshot, never the main-actor-mutated arrays.
        if let source = routedSource(for: uniqueID) {

            if source.type == .iOSDevice {
                // iOS device frames → dedicated delegate (BezelManager pipeline)
                delegate.enhancedCaptureDeviceDidOutputSampleBuffer(sampleBuffer: sampleBuffer, source: source)
                return
            }

            // External/other device frames → existing screen buffer path (zone2)
            delegate.enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: sampleBuffer, source: source)
            return
        }

        mlog.warning("Device frame from unknown uniqueID: \(uniqueID) — dropped")
    }

    func deviceAudioBuffer(sampleBuffer: CMSampleBuffer, uniqueID: String) {
        guard let delegate, let source = routedSource(for: uniqueID) else { return }
        delegate.enhancedCaptureDidOutputAudioSampleBuffer(sampleBuffer: sampleBuffer, source: source)
    }

    func deviceAudioLevel(_ level: EnhancedCaptureAudioLevel, uniqueID: String) {
        guard let delegate, let source = routedSource(for: uniqueID) else { return }
        delegate.enhancedCapture(self, didUpdateAudioLevel: level, for: source)
    }

    func deviceVideoRotationAngleDidChange(_ angle: CGFloat, uniqueID: String) {
        guard let source = routedSource(for: uniqueID) else { return }
        runOnMainActor { kit in
            kit.delegate?.enhancedCapture(kit, videoRotationAngleDidChange: angle, for: source)
        }
    }

    func deviceSystemPressureDidChange(level: String, isElevated: Bool, uniqueID: String) {
        let source = routedSource(for: uniqueID)
        let message = "System pressure \(level) on \(source?.displayName ?? uniqueID)"
        if isElevated { mlog.error(message) } else { mlog.info(message) }
        guard isElevated else { return }
        runOnMainActor { kit in
            kit.report(.systemPressureElevated(level: level), for: source)
        }
    }

    func deviceDepthData(_ depthData: AVDepthData, timestamp: CMTime, uniqueID: String) {
        guard let delegate, let source = routedSource(for: uniqueID) else { return }
        delegate.enhancedCaptureDidOutputDepthData(depthData: depthData, timestamp: timestamp, source: source)
    }

    func devicePreviewLayer(previewLayer: AVCaptureVideoPreviewLayer, model: String) {
        mlog.debug("Preview layer received for model: \(model)")
    }
}

// MARK: - PermissionManagerDelegate

extension EnhancedCaptureKit: PermissionManagerDelegate {
    func permissionManager(_ manager: PermissionManager, didResolvePermission type: PermissionType, status: PermissionStatus) {
        // Forward to consumer delegate
        delegate?.enhancedCapture(self, permissionStatusDidChange: type, status: status)

        switch type {
        case .camera:
            if status == .authorized {
                // Camera authorized — start the capture session
                let usesInputPriority = configuration.videoPreference != nil
                let isMultiCam = isMultiCameraSession
                sessionQueue.async { [weak self] in
                    guard let self = self else { return }
                    // iOS / tvOS: `.high` lets AVFoundation pick each device's
                    // format; `.inputPriority` honours the activeFormat chosen
                    // from `configuration.videoPreference`. A multi-camera
                    // session is always `.inputPriority` and rejects any other
                    // preset. macOS has no such preset — an explicitly set
                    // activeFormat is honoured under `.high`.
                    if !isMultiCam {
                        #if os(iOS) || os(tvOS)
                        self.session.sessionPreset = usesInputPriority ? .inputPriority : .high
                        #else
                        self.session.sessionPreset = .high
                        #endif
                    }
                    self.session.startRunning()
                    mlog.info("Session started running (camera authorized, inputPriority: \(usesInputPriority || isMultiCam), multi-camera: \(isMultiCam))")

                    DispatchQueue.main.async {
                        self.delegate?.enhancedCaptureDidInitialize(self)
                        mlog.notice("Initialization complete")
                    }
                }
            } else {
                mlog.error("Camera permission \(String(describing: status)) — session will not start")
                // Still notify initialization complete (with no active session).
                // Always asynchronous: a synchronous resolution must never let
                // this reach the delegate before init(delegate:) has returned.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.enhancedCaptureDidInitialize(self)
                }
            }

        case .microphone:
            mlog.info("Microphone permission: \(String(describing: status))")
            guard status == .authorized else { break }
            runOnMainActor { kit in
                kit.attachAudioToEnabledSources()
                // A microphone-only app (camera denied or never asked) still
                // needs a running session for audio to flow.
                if PermissionManager.currentStatus(for: .camera) != .authorized {
                    kit.startSessionIfNeeded()
                }
            }

        case .screenRecording:
            // Screen recording status is informational — EnhancedCaptureScreen
            // self-guards via CGPreflightScreenCaptureAccess() so no gating needed.
            mlog.info("Screen recording permission: \(String(describing: status))")
        }
    }
}
