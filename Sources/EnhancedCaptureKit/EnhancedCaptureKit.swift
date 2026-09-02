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

    /// Audio from a microphone, a muxed device (HDMI capture card), or a
    /// display with system audio. Requires `configuration.audioEnabled`.
    /// Delivered on the source's audio queue; the buffer is PCM in the
    /// device's native format (read it via `CMSampleBufferGetFormatDescription`).
    func enhancedCaptureDidOutputAudioSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource)

    /// Per-channel peak / average levels for an audio-capable source.
    /// Requires `configuration.audioLevelMeteringEnabled`. Audio queue.
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
    /// changed (0, 90, 180, 270 degrees). Main thread.
    func enhancedCapture(_ manager: EnhancedCaptureKit, videoRotationAngleDidChange angle: CGFloat, for source: EnhancedCaptureSource)
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
@available(macOS 10.15, iOS 16.0, *)
public final class EnhancedCaptureKit: AVCaptureSession, @unchecked Sendable {

    // MARK: - Properties

    public weak var delegate: EnhancedCaptureDelegate?

    /// Options fixed at construction. See ``EnhancedCaptureConfiguration``.
    public private(set) var configuration: EnhancedCaptureConfiguration = .default

    // Internal for access from extension files (EnhancedCaptureObservers.swift)
    var observers: [NSObjectProtocol] = []

    // MARK: - MacOS only ScreenCaptureKit
    #if os(macOS)
    private var captureScreens: [EnhancedCaptureScreen] = []
    #endif

    public var captureSources: [EnhancedCaptureSource] = []
    private var captureDevices: [EnhancedCaptureDevice] = []

    // Track which sources are currently enabled/capturing
    private var enabledSources: Set<String> = []

    // Last state reported per source id (main actor).
    private var sourceStates: [String: EnhancedCaptureSourceState] = [:]

    // Microphone access, resolved through PermissionManager (main actor).
    private var microphoneStatus: PermissionStatus = .notDetermined

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

    public convenience init(delegate: EnhancedCaptureDelegate, configuration: EnhancedCaptureConfiguration) {
        self.init()
        self.delegate = delegate
        self.configuration = configuration

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

        mlog.debug("Initializing with delegate (audio: \(configuration.audioEnabled))")

        setupCaptureKit()

        // ALL discovery + permission resolution is deferred past init. The
        // permission check can resolve synchronously (already authorized or
        // denied) and device discovery emits per device found — either would
        // otherwise call the delegate while the consumer's assignment of this
        // instance is still evaluating.
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Check permissions — session start is deferred until camera is authorized
            self.permissionManager = PermissionManager(delegate: self)
            self.permissionManager?.checkPermissions(includeMicrophone: self.configuration.audioEnabled)
            // Device discovery (populates device list so sources are ready
            // when the session starts)
            self.refreshDevices()
            #if os(macOS)
            await self.screensDidUpdate()
            #endif
        }

        mlog.debug("Initialization pending permission resolution")
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
                self.usesApplicationAudioSession = true
                self.automaticallyConfiguresApplicationAudioSession = true
            case .applicationManaged:
                self.usesApplicationAudioSession = true
                self.automaticallyConfiguresApplicationAudioSession = false
            case .detached:
                self.usesApplicationAudioSession = false
            }
            #endif
            #if os(iOS)
            if config.multitaskingCameraAccessEnabled {
                if self.isMultitaskingCameraAccessSupported {
                    self.isMultitaskingCameraAccessEnabled = true
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
        sourceStates[source.id] = state
        delegate?.enhancedCapture(self, sourceStateDidChange: state, for: source)
    }

    @MainActor
    private func report(_ error: EnhancedCaptureError, for source: EnhancedCaptureSource?) {
        mlog.error("\(error.description)\(source.map { " [\($0.displayName)]" } ?? "")")
        delegate?.enhancedCapture(self, didEncounterError: error, for: source)
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
            // Find the screen capture with matching display ID
            guard let captureScreen = captureScreens.first(where: {
                $0.captureSource?.id == source.id
            }) else {
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
            // Find the device in our devices array
            guard let captureDevice = captureDevices.first(where: {
                $0.device.uniqueID == source.uniqueID
            }) else {
                enabledSources.remove(source.id)
                report(.sourceUnavailable(source.id), for: source)
                return
            }

            // Audio rides along only with microphone permission.
            var includeAudio = false
            if source.hasAudio {
                if microphoneStatus == .authorized {
                    includeAudio = true
                } else {
                    report(.permissionDenied(.microphone), for: source)
                    if !source.hasVideo {
                        enabledSources.remove(source.id)
                        return
                    }
                }
            }

            // Add device to session
            addToSession(captureDevice: captureDevice, includeAudio: includeAudio) { [weak self] success in
                guard let self else { return }
                self.runOnMainActor { kit in
                    guard kit.enabledSources.contains(source.id) else { return }
                    if success {
                        kit.setState(.capturing, for: source)
                    } else {
                        kit.enabledSources.remove(source.id)
                        kit.report(.captureStartFailed(reason: "could not add device to session"), for: source)
                        kit.setState(.error(.captureStartFailed(reason: "could not add device to session")), for: source)
                    }
                }
            }
            mlog.info("Requested device to be added to session: \(source.displayName)")
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
            guard let captureScreen = captureScreens.first(where: {
                $0.captureSource?.id == source.id
            }) else {
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
            guard let captureDevice = captureDevices.first(where: {
                $0.device.uniqueID == source.uniqueID
            }) else {
                report(.sourceUnavailable(source.id), for: source)
                completion?()
                return
            }

            removeFromSession(captureDevice: captureDevice) { [weak self] in
                mlog.info("Removed device from session: \(source.displayName)")
                self?.runOnMainActor { $0.setState(.idle, for: source) }
                completion?()
            }
        }
    }

    // MARK: - Session Management

    private func addToSession(captureDevice: EnhancedCaptureDevice, includeAudio: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.beginConfiguration()
            defer { self.commitConfiguration() }

            guard let input = captureDevice.input, self.canAddInput(input) else {
                mlog.error("Failed to add input for device")
                completion(false)
                return
            }

            // Add input WITHOUT automatic connections
            self.addInputWithNoConnections(input)

            // iOS / tvOS reset the device format when the input joins; put the
            // preference back while still inside begin/commitConfiguration.
            #if os(iOS) || os(tvOS)
            captureDevice.reapplyVideoPreference()
            #endif

            var addedAnything = false

            // Video output + connection
            if let videoOutput = captureDevice.dataVideoOutput {
                if self.canAddOutput(videoOutput) {
                    self.addOutputWithNoConnections(videoOutput)
                    if let videoConnection = captureDevice.videoConnection,
                       self.canAddConnection(videoConnection) {
                        self.addConnection(videoConnection)
                        addedAnything = true
                        mlog.debug("Added video connection")
                    } else {
                        mlog.error("Failed to add video connection")
                    }
                } else {
                    mlog.error("Failed to add video output for device")
                }
            }

            // Audio data output + connection
            if includeAudio, let audioOutput = captureDevice.dataAudioOutput {
                if self.canAddOutput(audioOutput) {
                    self.addOutputWithNoConnections(audioOutput)
                    if let audioConnection = captureDevice.audioConnection,
                       self.canAddConnection(audioConnection) {
                        self.addConnection(audioConnection)
                        addedAnything = true
                        mlog.debug("Added audio data connection")
                    } else {
                        mlog.error("Failed to add audio data connection")
                    }
                } else {
                    mlog.error("Failed to add audio data output for device")
                }
            }

            // Audio preview (macOS-only: AVCaptureAudioPreviewOutput)
            #if os(macOS)
            if includeAudio,
               let audioPreview = captureDevice.audioPreview,
               let previewConnection = captureDevice.audioPreviewConnection,
               self.canAddOutput(audioPreview),
               self.canAddConnection(previewConnection) {
                self.addOutputWithNoConnections(audioPreview)
                self.addConnection(previewConnection)
                addedAnything = true
                mlog.debug("Added audio preview connection")
            }
            #endif

            if !addedAnything {
                // Nothing usable — don't leave a dangling input in the session.
                self.removeInput(input)
                completion(false)
                return
            }

            mlog.debug("Successfully added device to session")
            completion(true)
        }
    }

    private func removeFromSession(captureDevice: EnhancedCaptureDevice, completion: @escaping @Sendable () -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.beginConfiguration()
            defer {
                self.commitConfiguration()
                DispatchQueue.main.async {
                    completion()
                }
            }

            // Check if components are still in the session before trying to remove
            // (Device may have been auto-removed by AVFoundation if unplugged)

            // Remove connections only if they're still in the session
            if let videoConnection = captureDevice.videoConnection,
               self.connections.contains(videoConnection) {
                self.removeConnection(videoConnection)
                mlog.debug("Removed video connection")
            }

            if let audioConnection = captureDevice.audioConnection,
               self.connections.contains(audioConnection) {
                self.removeConnection(audioConnection)
                mlog.debug("Removed audio data connection")
            }

            #if os(macOS)
            if let previewConnection = captureDevice.audioPreviewConnection,
               self.connections.contains(previewConnection) {
                self.removeConnection(previewConnection)
                mlog.debug("Removed audio preview connection")
            }
            #endif

            // Remove outputs only if they're still in the session
            if let videoOutput = captureDevice.dataVideoOutput,
               self.outputs.contains(videoOutput) {
                self.removeOutput(videoOutput)
                mlog.debug("Removed video output")
            }

            if let audioOutput = captureDevice.dataAudioOutput,
               self.outputs.contains(audioOutput) {
                self.removeOutput(audioOutput)
                mlog.debug("Removed audio data output")
            }

            #if os(macOS)
            if let audioPreview = captureDevice.audioPreview,
               self.outputs.contains(audioPreview) {
                self.removeOutput(audioPreview)
                mlog.debug("Removed audio preview output")
            }
            #endif

            // Remove input only if it's still in the session
            if let input = captureDevice.input,
               self.inputs.contains(input) {
                self.removeInput(input)
                mlog.debug("Removed input")
            }

            mlog.debug("Successfully removed device from session")
        }
    }

    /// Stops and restarts the session on the session queue. Also used after
    /// `AVError.mediaServicesWereReset`.
    public func restartSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.isRunning { self.stopRunning() }
            self.startRunning()
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
            case .screen, .screenMain: continue
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
        options.capturesAudio = configuration.audioEnabled && configuration.screenAudioEnabled
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
                    kit.enabledSources.remove(captureSource.id)
                    kit.sourceStates.removeValue(forKey: captureSource.id)
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
            $0.hasVideo == captureDevice.hasVideo
        }) {
            mlog.debug("Duplicate device name, skipping: \(captureSource.displayName) from \(captureSource.manufacturer)")
            return
        }

        // Add to devices array
        captureDevices.append(captureDevice)
        mlog.debug("Added device. Total devices: \(self.captureDevices.count) (type: \(String(describing: captureSource.type)), media: \(String(describing: captureSource.media)))")

        // Emit updated sources list
        emitCaptureSources()
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
                    let wasEnabled = kit.enabledSources.remove(source.id) != nil
                    kit.sourceStates.removeValue(forKey: source.id)
                    if wasEnabled {
                        kit.delegate?.enhancedCapture(kit, sourceStateDidChange: .idle, for: source)
                    }
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
}

// MARK: - Camera & audio controls

@available(macOS 10.15, iOS 16.0, *)
public extension EnhancedCaptureKit {

    /// Sets the zoom factor of a camera source (clamped to the device's range).
    @MainActor
    func setZoomFactor(_ factor: CGFloat, for source: EnhancedCaptureSource) {
        guard let device = trackedDevice(for: source) else { return report(.sourceUnavailable(source.id), for: source) }
        do { try device.setZoomFactor(factor) }
        catch let error as EnhancedCaptureError { report(error, for: source) }
        catch { report(.deviceConfigurationFailed(reason: error.localizedDescription), for: source) }
    }

    /// Sets the torch (flashlight) mode of a camera source that has one.
    @MainActor
    func setTorchMode(_ mode: AVCaptureDevice.TorchMode, for source: EnhancedCaptureSource) {
        guard let device = trackedDevice(for: source) else { return report(.sourceUnavailable(source.id), for: source) }
        do { try device.setTorchMode(mode) }
        catch let error as EnhancedCaptureError { report(error, for: source) }
        catch { report(.deviceConfigurationFailed(reason: error.localizedDescription), for: source) }
    }

    /// Focuses and exposes at a normalized point (landscape sensor space).
    @MainActor
    func setFocusAndExposurePoint(_ point: CGPoint, for source: EnhancedCaptureSource) {
        guard let device = trackedDevice(for: source) else { return report(.sourceUnavailable(source.id), for: source) }
        do { try device.setFocusAndExposurePoint(point) }
        catch let error as EnhancedCaptureError { report(error, for: source) }
        catch { report(.deviceConfigurationFailed(reason: error.localizedDescription), for: source) }
    }

    /// Center Stage is a system-wide switch on the front camera (iPad,
    /// Continuity Camera). Puts control in app mode and toggles it.
    static func setCenterStageEnabled(_ enabled: Bool) {
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = enabled
    }

    /// Whether Center Stage is currently on.
    static var isCenterStageEnabled: Bool { AVCaptureDevice.isCenterStageEnabled }

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
            if case .error(let error) = state {
                kit.enabledSources.remove(source.id)
                kit.report(error, for: source)
            }
            kit.setState(state, for: source)
        }
    }
}
#endif

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
                sessionQueue.async { [weak self] in
                    guard let self = self else { return }
                    // iOS / tvOS: `.high` lets AVFoundation pick each device's
                    // format; `.inputPriority` honours the activeFormat chosen
                    // from `configuration.videoPreference`. macOS has no such
                    // preset — an explicitly set activeFormat is honoured under `.high`.
                    #if os(iOS) || os(tvOS)
                    self.sessionPreset = usesInputPriority ? .inputPriority : .high
                    #else
                    self.sessionPreset = .high
                    #endif
                    self.startRunning()
                    mlog.info("Session started running (camera authorized, inputPriority: \(usesInputPriority))")

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
            runOnMainActor { kit in
                kit.microphoneStatus = status
                mlog.info("Microphone permission: \(String(describing: status))")
            }

        case .screenRecording:
            // Screen recording status is informational — EnhancedCaptureScreen
            // self-guards via CGPreflightScreenCaptureAccess() so no gating needed.
            mlog.info("Screen recording permission: \(String(describing: status))")
        }
    }
}
