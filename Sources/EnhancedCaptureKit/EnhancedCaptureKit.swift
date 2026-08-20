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


// MARK: - CaptureManagerDelegate Protocol

public protocol EnhancedCaptureDelegate: AnyObject {
    func enhancedCaptureDidInitialize(_ manager: EnhancedCaptureKit)
    func enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource)
    func captureSourceListDidChange(_ manager:EnhancedCaptureKit, sources: [EnhancedCaptureSource])
    func enhancedCaptureDeviceDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource)
    func enhancedCapture(_ manager: EnhancedCaptureKit, permissionStatusDidChange type: PermissionType, status: PermissionStatus)
}

public extension EnhancedCaptureDelegate {
    func enhancedCaptureDeviceDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {}
    func enhancedCapture(_ manager: EnhancedCaptureKit, permissionStatusDidChange type: PermissionType, status: PermissionStatus) {}
}

/// ── Threading contract ────────────────────────────────────────────────
/// Discovery state (`captureScreens` / `captureDevices` / `captureSources` /
/// `enabledSources`) is MAIN-ACTOR confined: every mutation path — init-time
/// discovery, screen/device observers, lost-device completions, and the
/// public enable/disable API — funnels onto the main actor, and the
/// `captureSourceListDidChange` / `enhancedCaptureDidInitialize` delegate
/// callbacks are always delivered there, always AFTER `init(delegate:)` has
/// returned (a callback during init reaches a consumer whose stored
/// reference is still nil). The sample-buffer hot path never touches those
/// arrays: it routes through a lock-guarded snapshot rebuilt on each emit.
/// Session plumbing stays on `sessionQueue`. `@unchecked Sendable` reflects
/// this manual confinement, not an absence of shared state.
@available(macOS 10.15, iOS 16.0, *)
public final class EnhancedCaptureKit: AVCaptureSession, @unchecked Sendable {

    // MARK: - Properties

    public weak var delegate: EnhancedCaptureDelegate?

    // Internal for access from extension files (CaptureObservers.swift)
    var observers: [NSObjectProtocol] = []

    // MARK: - MacOS only ScreenCaptureKit
    #if os(macOS)
    private var captureScreens: [EnhancedCaptureScreen] = []
    #endif

    public var captureSources: [EnhancedCaptureSource] = []
    private var captureDevices: [EnhancedCaptureDevice] = []

    // Track which sources are currently enabled/capturing
    private var enabledSources: Set<String> = []

    // Hot-path routing snapshot: deviceVideoBuffer() runs on capture callback
    // queues at frame rate and must not scan `captureDevices` while the main
    // actor mutates it. Rebuilt under the lock on every emit.
    private let routingLock = NSLock()
    private var routingByDeviceUniqueID: [String: EnhancedCaptureSource] = [:]

    private let sessionQueue = DispatchQueue(label: "com.mvs.captureManager.sessionQueue", qos: .userInteractive)
    private var permissionManager: PermissionManager?

    public convenience init(delegate: EnhancedCaptureDelegate) {
        self.init()
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

        mlog.debug("Initializing with delegate")

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
            self.permissionManager?.checkPermissions()
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
        // Note: first screens pass + refreshDevices() run from init's deferred
        // main-actor task — never synchronously inside init.
        mlog.debug("Capture components setup complete")
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
    
    // MARK: - Capture enable/disable

    // Public wrappers keep the pre-confinement signatures (callable from any
    // thread); the isolated implementations own the state. Main-thread callers
    // run synchronously, exactly as before.

    public func enableCapture(for source: EnhancedCaptureSource) {
        runOnMainActor { $0.enableCaptureIsolated(for: source) }
    }

    public func disableCapture(for source: EnhancedCaptureSource) {
        runOnMainActor { $0.disableCaptureIsolated(for: source) }
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
                mlog.error("Could not find screen capture for source: \(source.id)")
                enabledSources.remove(source.id)
                return
            }

            // Start the screen capture
            captureScreen.startCapture()
            mlog.info("Started screen capture for: \(source.displayName)")
            #else
            mlog.debug("Screen capture not available on this platform")
            enabledSources.remove(source.id)
            #endif

        case .externalDevice, .iOSDevice, .cameraFront, .cameraBack:
            // Find the device in our devices array
            guard let captureDevice = captureDevices.first(where: {
                $0.device.uniqueID == source.uniqueID
            }) else {
                mlog.error("Could not find device for source: \(source.id)")
                enabledSources.remove(source.id)
                return
            }
            // Add device to session
            addToSession(captureDevice: captureDevice)
            mlog.info("Requested device to be added to session: \(source.displayName)")
        }
    }

    @MainActor
    private func disableCaptureIsolated(for source: EnhancedCaptureSource) {
        mlog.info("Disabling capture for source: \(source.displayName) (type: \(String(describing: source.type)))")

        // Remove from enabled sources set
        enabledSources.remove(source.id)

        switch source.type {
        case .screen, .screenMain:
            #if os(macOS)
            guard let captureScreen = captureScreens.first(where: {
                $0.captureSource?.id == source.id
            }) else {
                mlog.error("Could not find screen capture for source: \(source.id)")
                return
            }

            captureScreen.stopCapture()
            mlog.info("Stopped screen capture for: \(source.displayName)")
            #else
            mlog.debug("Screen capture not available on this platform")
            #endif

        case .externalDevice, .iOSDevice, .cameraFront, .cameraBack:
            guard let captureDevice = captureDevices.first(where: {
                $0.device.uniqueID == source.uniqueID
            }) else {
                mlog.error("Could not find device for source: \(source.id)")
                return
            }

            removeFromSession(captureDevice: captureDevice) {
                mlog.info("Removed device from session: \(source.displayName)")
            }
        }
    }

    @MainActor
    private func disableCaptureIsolated(for source: EnhancedCaptureSource, completion: @escaping @Sendable () -> Void) {
        mlog.info("Disabling capture for source: \(source.displayName) (type: \(String(describing: source.type)))")
        enabledSources.remove(source.id)

        switch source.type {
        case .screen, .screenMain:
            #if os(macOS)
            guard let captureScreen = captureScreens.first(where: {
                $0.captureSource?.id == source.id
            }) else {
                mlog.error("Could not find screen capture for source: \(source.id)")
                completion()
                return
            }
            captureScreen.stopCapture()
            mlog.info("Stopped screen capture for: \(source.displayName)")
            completion()
            #else
            mlog.debug("Screen capture not available on this platform")
            completion()
            #endif

        case .externalDevice, .iOSDevice, .cameraFront, .cameraBack:
            guard let captureDevice = captureDevices.first(where: {
                $0.device.uniqueID == source.uniqueID
            }) else {
                mlog.error("Could not find device for source: \(source.id)")
                completion()
                return
            }
            removeFromSession(captureDevice: captureDevice) {
                mlog.info("Removed device from session: \(source.displayName)")
                completion()
            }
        }
    }

    // MARK: - Session Management

    private func addToSession(captureDevice: EnhancedCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.beginConfiguration()
            defer { self.commitConfiguration() }
            
            // Add video input and output
            guard let input = captureDevice.input,
                  let videoOutput = captureDevice.dataVideoOutput,
                  self.canAddInput(input),
                  self.canAddOutput(videoOutput) else {
                mlog.error("Failed to add video input/output for device")
                return
            }

            // Add input and output WITHOUT automatic connections
            self.addInputWithNoConnections(input)
            self.addOutputWithNoConnections(videoOutput)

            // Add video connection manually
            if let videoConnection = captureDevice.videoConnection,
               self.canAddConnection(videoConnection) {
                self.addConnection(videoConnection)
                mlog.debug("Added video connection")
            } else {
                mlog.error("Failed to add video connection")
            }

            // Add audio output and connection if available (macOS-only: AVCaptureAudioPreviewOutput)
            #if os(macOS)
            if let audioOutput = captureDevice.audioPreview,
               let audioConnection = captureDevice.audioConnection,
               self.canAddOutput(audioOutput),
               self.canAddConnection(audioConnection) {
                self.addOutputWithNoConnections(audioOutput)
                self.addConnection(audioConnection)
                mlog.debug("Added audio connection")
            }
            #endif

            mlog.debug("Successfully added device to session")
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
                mlog.debug("Removed audio connection")
            }

            // Remove outputs only if they're still in the session
            if let videoOutput = captureDevice.dataVideoOutput,
               self.outputs.contains(videoOutput) {
                self.removeOutput(videoOutput)
                mlog.debug("Removed video output")
            }

            #if os(macOS)
            if let audioOutput = captureDevice.audioPreview,
               self.outputs.contains(audioOutput) {
                self.removeOutput(audioOutput)
                mlog.debug("Removed audio output")
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
        let newCapture = EnhancedCaptureScreen(delegate: self, displayId: displayId)
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

        // Rebuild the hot-path routing snapshot (read by deviceVideoBuffer on
        // capture callback queues — it must never scan the live arrays).
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
        let deviceTypes: [AVCaptureDevice.DeviceType]
        #if os(iOS)
        if #available(iOS 17.0, *) {
            deviceTypes = [.external, .builtInWideAngleCamera]
        } else {
            deviceTypes = [.builtInWideAngleCamera]
        }
        #else
        deviceTypes = [.external, .builtInWideAngleCamera]
        #endif

        let videoDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices

        let muxedDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .muxed,
            position: .unspecified
        ).devices

        // Combine and remove duplicates based on uniqueID
        var uniqueDevices: [AVCaptureDevice] = []
        var seenIDs = Set<String>()
        
        for device in videoDevices + muxedDevices {
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
    
    // MARK: - Public Start/Stop methods
        
    // MARK: - Device Event Handlers

    // Internal for access from extension files (CaptureObservers.swift)
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

        // Skip audio-only devices - they're handled as part of the main device
        if !device.hasMediaType(.video) && !device.hasMediaType(.muxed) {
            mlog.debug("Skipping audio-only device: \(device.localizedName)")
            return
        }

        // Create new capture device
        let captureDevice = EnhancedCaptureDevice(device: device, delegate: self)

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

        // Check if a device with the same display name already exists (handles same physical device with different IDs)
        if captureDevices.contains(where: {
            $0.captureSource?.displayName == captureSource.displayName &&
            $0.captureSource?.manufacturer == captureSource.manufacturer
        }) {
            mlog.debug("Duplicate device name, skipping: \(captureSource.displayName) from \(captureSource.manufacturer)")
            return
        }

        // Add to devices array
        captureDevices.append(captureDevice)
        mlog.debug("Added device. Total devices: \(self.captureDevices.count) (type: \(String(describing: captureSource.type)), manufacturer: \(captureSource.manufacturer))")

        // Emit updated sources list
        emitCaptureSources()
    }

    

    private func shouldAddCaptureDevice(_ device: AVCaptureDevice) -> Bool {
        #if os(macOS)
        // Skip Apple built-in cameras
        guard device.manufacturer != "Apple Inc." else { return false }

        // Allow specific UVC camera manufacturers
        let allowedManufacturers = ["Magewell", "MACROSILICON", "Blackmagic Design"]
        if device.modelID.hasPrefix("UVC Camera") {
            return allowedManufacturers.contains(device.manufacturer)
        }

        return true
        #else
        // On iOS, all devices are allowed
        return true
        #endif
    }

    // Internal for access from extension files (CaptureObservers.swift)
    @MainActor
    func deviceLost(device: AVCaptureDevice) {
        mlog.info("Device lost: \(device.localizedName) (model: \(device.modelID))")

        // Find the capture device with matching uniqueID
        guard let captureDevice = captureDevices.first(where: { $0.device.uniqueID == device.uniqueID }) else {
            mlog.error("Could not find device to remove")
            return
        }

        // Capture the source ID BEFORE removal — prepareForRemoval() may nil references
        let sourceId = captureDevice.captureSource?.id
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
                if let sourceId {
                    kit.enabledSources.remove(sourceId)
                    mlog.debug("Cleared enabledSources for disconnected device")
                }

                mlog.debug("Successfully removed device. Total devices: \(kit.captureDevices.count)")

                // Emit updated sources list
                kit.emitCaptureSources()
            }
        }
    }
    
}

#if os(macOS)
extension EnhancedCaptureKit: EnhancedCaptureScreenDelegate {
    func enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource) {
        guard let delegate else {
            mlog.error("CaptureKitScreenDelegate: no delegate found")
            return
        }
        delegate.enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: sampleBuffer, source: source)
    }
}
#endif

extension EnhancedCaptureKit: EnhancedCaptureDeviceDelegate {
    func deviceVideoBuffer(model: String, sampleBuffer: CMSampleBuffer, uniqueID: String) {
        guard let delegate else {
            mlog.error("CaptureKitDeviceDelegate: no delegate found")
            return
        }

        // Frame-rate hot path on a capture callback queue: route via the
        // lock-guarded snapshot, never the main-actor-mutated arrays.
        routingLock.lock()
        let routedSource = routingByDeviceUniqueID[uniqueID]
        routingLock.unlock()

        if let source = routedSource {

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
                sessionQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.sessionPreset = .high
                    self.startRunning()
                    mlog.info("Session started running (camera authorized)")

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

        case .screenRecording:
            // Screen recording status is informational — CaptureKitScreen
            // self-guards via CGPreflightScreenCaptureAccess() so no gating needed.
            mlog.info("Screen recording permission: \(String(describing: status))")
        }
    }
}
