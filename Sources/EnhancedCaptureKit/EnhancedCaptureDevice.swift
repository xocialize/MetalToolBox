//
//  EnhancedCaptureDevice.swift
//  EnhancedCaptureKit
//
//  Created by Dustin Nielson on 1/9/26.
//
//  One AVCaptureDevice (camera, capture card, iOS device over USB, or
//  microphone) prepared for manual-connection insertion into the shared
//  EnhancedCaptureKit session: input, data outputs, connections, and the
//  per-platform extras (macOS audio preview, iOS rotation coordinator).
//

import Foundation
#if os(macOS)
import Cocoa
#elseif os(iOS)
import UIKit
#endif
import AVFoundation
import CoreMedia
import OSLog
import LoggingKit


// MARK: - CaptureDeviceDelegate Protocol

protocol EnhancedCaptureDeviceDelegate: AnyObject {
    func deviceVideoBuffer(model: String, sampleBuffer: CMSampleBuffer, uniqueID: String)
    func deviceAudioBuffer(sampleBuffer: CMSampleBuffer, uniqueID: String)
    func deviceAudioLevel(_ level: EnhancedCaptureAudioLevel, uniqueID: String)
    func deviceVideoRotationAngleDidChange(_ angle: CGFloat, uniqueID: String)
    func deviceSystemPressureDidChange(level: String, isElevated: Bool, uniqueID: String)
    func devicePreviewLayer(previewLayer: AVCaptureVideoPreviewLayer, model: String)
}

// MARK: - EnhancedCaptureDevice

class EnhancedCaptureDevice: NSObject, @unchecked Sendable {

    // MARK: - CaptureSource

    nonisolated(unsafe) public private(set) var captureSource: EnhancedCaptureSource?

    // MARK: - Properties

    weak var delegate: EnhancedCaptureDeviceDelegate?

    let device: AVCaptureDevice
    let configuration: EnhancedCaptureConfiguration

    private var observers: [NSObjectProtocol] = []
    private let videoQueue: DispatchQueue
    private let audioQueue: DispatchQueue

    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    // MARK: - Capture Components

    private(set) var input: AVCaptureDeviceInput?
    private(set) var dataVideoOutput: AVCaptureVideoDataOutput?
    private(set) var dataAudioOutput: AVCaptureAudioDataOutput?

    private var videoPort: AVCaptureInput.Port?
    private var audioPort: AVCaptureInput.Port?

    private(set) var videoConnection: AVCaptureConnection?
    /// Audio port → `AVCaptureAudioDataOutput` (sample-buffer delivery).
    private(set) var audioConnection: AVCaptureConnection?
    private(set) var videoPreviewConnection: AVCaptureConnection?

    #if os(macOS)
    /// Audio port → speakers (`AVCaptureAudioPreviewOutput`).
    private(set) var audioPreview: AVCaptureAudioPreviewOutput?
    private(set) var audioPreviewConnection: AVCaptureConnection?
    #endif
    private(set) var videoPreviewConnectionActive: Bool = false

    /// The device's input opened with a video port (camera, capture card, iOS
    /// device). Port-based: false when the input could not be opened. Use
    /// `captureSource.hasVideo` for what the device *is*.
    var hasVideo: Bool { videoPort != nil }

    // MARK: - Device Properties

    private var width: Int32 = 0
    private var height: Int32 = 0
    private var orientation: EnhancedCaptureOrientation = .portrait

    // Audio level throttle — touched only on `audioQueue`.
    nonisolated(unsafe) private var lastAudioLevelTime: CMTime = .invalid

    #if os(iOS)
    // `AVCaptureDevice.RotationCoordinator` is iOS 17+ and stored properties
    // cannot carry availability, so the reference is erased; only the KVO
    // closure (which receives the typed coordinator) ever reads it.
    private var rotationCoordinator: AnyObject?
    private var rotationObservation: NSKeyValueObservation?
    /// Angle currently applied to the video connection, so the kit can report
    /// it once the device is registered (the first KVO fires during `init`).
    private(set) var videoRotationAngle: CGFloat?
    private var systemPressureObservation: NSKeyValueObservation?
    #endif

    // MARK: - Initialization

    init(device: AVCaptureDevice, delegate: EnhancedCaptureDeviceDelegate, configuration: EnhancedCaptureConfiguration) {
        self.device = device
        self.delegate = delegate
        self.configuration = configuration
        self.videoQueue = DispatchQueue(
            label: "com.xocialize.MetalToolBox.EnhancedCaptureDevice.video.\(device.uniqueID)",
            qos: .userInteractive
        )
        self.audioQueue = DispatchQueue(
            label: "com.xocialize.MetalToolBox.EnhancedCaptureDevice.audio.\(device.uniqueID)",
            qos: .userInteractive
        )
        super.init()
        setupCaptureDevice()

        // Initialize capture source based on device type
        self.captureSource = createCaptureSource(from: device)
    }

    // MARK: - Private Helpers

    private func createCaptureSource(from device: AVCaptureDevice) -> EnhancedCaptureSource {
        // Classify by what the device *is*, not by which ports opened: an input
        // that fails to open (camera permission denied, device held by another
        // app) must still be listed as the camera it is, so that enabling it
        // fails honestly instead of advertising a phantom microphone.
        let videoCapable = device.hasMediaType(.video) || device.hasMediaType(.muxed)
        let audioCapable = device.hasMediaType(.audio) || device.hasMediaType(.muxed)

        // Determine the source type based on device characteristics
        let sourceType: EnhancedCaptureSourceType

        if !videoCapable {
            sourceType = .microphone
        } else {
            #if os(macOS)
            // On macOS, check if it's an iOS device connected via USB
            if device.modelID == "iOS Device" {
                sourceType = .iOSDevice
            } else {
                // External capture device (HDMI capture card, UVC camera, etc.)
                sourceType = .externalDevice
            }
            #elseif os(iOS)
            // On iOS/iPadOS, determine if it's front or back camera
            switch device.position {
            case .front:
                sourceType = .cameraFront
            case .back:
                sourceType = .cameraBack
            default:
                // For external devices connected to iOS/iPadOS
                sourceType = .externalDevice
            }
            #else
            // Fallback for other platforms
            sourceType = .externalDevice
            #endif
        }

        // Get manufacturer (macOS-only property)
        #if os(macOS)
        let manufacturer = device.manufacturer
        #else
        let manufacturer = "Apple Inc."  // Default for iOS devices
        #endif

        var media = EnhancedCaptureMediaKinds()
        if videoCapable { media.insert(.video) }
        if audioCapable && configuration.audioEnabled { media.insert(.audio) }

        // Create the capture source
        return EnhancedCaptureSource(
            id: device.uniqueID,
            type: sourceType,
            displayName: device.localizedName,
            manufacturer: manufacturer,
            modelID: device.modelID,
            uniqueID: device.uniqueID,
            media: media
        )
    }

    deinit {
        prepareForRemoval()
    }

    // MARK: - Setup Methods

    private func setupCaptureDevice() {
        setupInput()
        setupDevice()
        setupVideoDataOutput()
        setupVideoConnection()
        setupAudio()
        #if os(iOS)
        setupRotationCoordinator()
        setupSystemPressureObserver()
        #endif
    }

    func setupPreviewLayer(session: AVCaptureSession) -> AVCaptureConnection? {
        let layer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        #if os(macOS)
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        #endif
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer

        guard let videoPort = videoPort,
              let previewLayer = previewLayer else {
            return nil
        }

        let connection = AVCaptureConnection(inputPort: videoPort, videoPreviewLayer: previewLayer)
        videoPreviewConnection = connection
        videoPreviewConnectionActive = true

        mlog.debug("Preview layer configured")
        return connection
    }

    /// Applies the configured video preference (macOS only).
    ///
    /// Without a preference, macOS keeps the historical behaviour of selecting
    /// the device's largest format (macOS honours a format set before the
    /// input joins the session). iOS / tvOS are left alone here: a format set
    /// now would be reset the moment the input is added, so the preference is
    /// applied once, inside the session's configuration block, by
    /// ``reapplyVideoPreference()``; without a preference the `.high` preset governs.
    private func setupDevice() {
        guard hasVideo else { return }
        #if os(macOS)
        apply(configuration.videoPreference ?? EnhancedCaptureVideoPreference())
        #endif
    }

    /// iOS / tvOS reset `activeFormat` and the frame-duration lock when an
    /// input is added to a session, so the kit calls this again inside the
    /// session's begin/commitConfiguration right after adding the input.
    ///
    /// A multi-camera session accepts only formats with `isMultiCamSupported`
    /// and has no `.high` preset to fall back on, so it always gets a
    /// preference — the configured one, or 1080p30.
    func reapplyVideoPreference(multiCamera: Bool) {
        guard hasVideo else { return }
        if multiCamera {
            apply(configuration.videoPreference ?? .hd1080p30, requireMultiCamSupport: true)
        } else if let preference = configuration.videoPreference {
            apply(preference)
        }
    }

    private func apply(_ preference: EnhancedCaptureVideoPreference, requireMultiCamSupport: Bool = false) {
        do {
            if try device.applyVideoPreference(preference, requireMultiCamSupport: requireMultiCamSupport) == nil {
                mlog.warning("No usable video format on \(self.device.localizedName) (multi-camera: \(requireMultiCamSupport)); keeping default format")
            }
        } catch {
            mlog.error("Failed to configure device format: \(error.localizedDescription)")
        }
    }

    private func setupInput() {
        do {
            let deviceInput = try AVCaptureDeviceInput(device: device)
            input = deviceInput

            for port in deviceInput.ports {
                if port.mediaType == .audio {
                    audioPort = port
                    mlog.debug("Audio port configured")
                } else if port.mediaType == .video {
                    videoPort = port
                    mlog.debug("Video port configured")
                    setupVideoPortObserver(for: port)
                }
            }
        } catch {
            mlog.error("Failed to create device input: \(error.localizedDescription)")
        }
    }

    private func setupVideoPortObserver(for port: AVCaptureInput.Port) {
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureInput.Port.formatDescriptionDidChangeNotification,
            object: port,
            queue: nil
        ) { [weak self] _ in
            guard let self = self,
                  let description = self.videoPort?.formatDescription else {
                mlog.error("Unable to process video port format description")
                return
            }

            let videoDimensions = CMVideoFormatDescriptionGetDimensions(description)
            self.width = videoDimensions.width
            self.height = videoDimensions.height

            let width = CGFloat(videoDimensions.width)
            let height = CGFloat(videoDimensions.height)

            self.orientation = videoDimensions.width > videoDimensions.height ? .landscape : .portrait

            // The layer is a UI object: resize it on main, not on whichever
            // thread AVFoundation posted the notification from.
            guard let previewLayer = self.previewLayer else { return }
            let box = UncheckedSendable(previewLayer)
            let modelID = self.device.modelID
            DispatchQueue.main.async { [weak self] in
                box.value.frame = CGRect(x: 0, y: 0, width: width, height: height)
                self?.delegate?.devicePreviewLayer(previewLayer: box.value, model: modelID)
            }
        }

        observers.append(observer)
    }

    private func setupVideoDataOutput() {
        guard hasVideo else { return }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(configuration.pixelFormat.coreVideoType)
        ]
        #if os(macOS)
        // iOS rejects keys other than the pixel format here; its data-output
        // buffers are IOSurface-backed and Metal-compatible regardless.
        settings[kCVPixelBufferMetalCompatibilityKey as String] = true
        #endif
        output.videoSettings = settings
        output.setSampleBufferDelegate(self, queue: videoQueue)

        dataVideoOutput = output
        mlog.debug("Video data output configured")
    }

    private func setupVideoConnection() {
        guard let videoPort = videoPort,
              let dataVideoOutput = dataVideoOutput else {
            if hasVideo { mlog.error("Cannot create video connection — missing components") }
            return
        }

        videoConnection = AVCaptureConnection(inputPorts: [videoPort], output: dataVideoOutput)
        mlog.debug("Video connection configured")
    }

    /// Audio wiring. Sample-buffer delivery and level metering share an
    /// `AVCaptureAudioDataOutput` on its own queue so audio callbacks never
    /// wait behind video frames; the macOS speaker preview is a second output
    /// on the same port.
    private func setupAudio() {
        guard let audioPort = audioPort else { return }

        // Capture (buffers and/or meters) needs the microphone entitlement, so
        // it rides on `audioEnabled`. Metering alone still needs the output.
        if configuration.audioEnabled,
           configuration.deliversAudioSampleBuffers || configuration.audioLevelMeteringEnabled {
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: audioQueue)
            dataAudioOutput = output
            audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: output)
            mlog.debug("Audio data connection configured")
        } else {
            mlog.debug("Audio port present but audio capture is disabled")
        }

        #if os(macOS)
        // Speaker preview of a muxed device's embedded audio (HDMI card). It is
        // not capture: independent of `audioEnabled` and of the microphone
        // permission, exactly as before the configuration existed — and never
        // for a microphone, which would feed the mic back to the speakers.
        if configuration.audioPreviewEnabled, hasVideo {
            let preview = AVCaptureAudioPreviewOutput()
            preview.volume = configuration.audioPreviewVolume
            audioPreview = preview
            audioPreviewConnection = AVCaptureConnection(inputPorts: [audioPort], output: preview)
            mlog.debug("Audio preview connection configured")
        }
        #endif
    }

    // MARK: - Rotation (iOS / iPadOS)

    #if os(iOS)
    /// Built-in cameras deliver sensor-oriented buffers. `.none` pins the
    /// connection to 0° (newer iPads default the front camera's data output to
    /// 180°); `.horizonLevelCapture` lets a rotation coordinator track the
    /// gravity-level angle and applies it before delivery.
    ///
    /// The first KVO callback fires synchronously in here, before the kit has
    /// registered this device, so the kit replays `videoRotationAngle` after
    /// registration.
    private func setupRotationCoordinator() {
        guard hasVideo, device.position != .unspecified, #available(iOS 17.0, *) else { return }

        switch configuration.cameraRotationMode {
        case .none:
            applyRotationAngle(0)

        case .horizonLevelCapture:
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                self?.applyRotationAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
            }
            mlog.debug("Rotation coordinator active for \(self.device.localizedName)")
        }
    }

    private func applyRotationAngle(_ angle: CGFloat) {
        guard let connection = videoConnection else { return }
        if #available(iOS 17.0, *), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        videoRotationAngle = angle
        delegate?.deviceVideoRotationAngleDidChange(angle, uniqueID: device.uniqueID)
    }

    // MARK: - System pressure (iOS / iPadOS)

    /// Cameras report thermal / power pressure per device. Serious and above
    /// means AVFoundation is about to throttle or stop the camera — which, in a
    /// multi-camera session, is the common failure mode.
    private func setupSystemPressureObserver() {
        guard hasVideo, device.position != .unspecified else { return }
        systemPressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
            guard let self else { return }
            let state = device.systemPressureState
            let level: String
            switch state.level {
            case .nominal:  level = "nominal"
            case .fair:     level = "fair"
            case .serious:  level = "serious"
            case .critical: level = "critical"
            case .shutdown: level = "shutdown"
            default:        level = "unknown"
            }
            let elevated = state.level == .serious || state.level == .critical || state.level == .shutdown
            self.delegate?.deviceSystemPressureDidChange(level: level, isElevated: elevated, uniqueID: self.device.uniqueID)
        }
    }
    #endif

    // MARK: - Device controls

    /// Sets the optical/digital zoom factor, clamped to the device's range.
    /// iOS / tvOS only — macOS cameras expose no zoom API.
    func setZoomFactor(_ factor: CGFloat) throws {
        guard hasVideo else { throw EnhancedCaptureError.deviceConfigurationFailed(reason: "not a video device") }
        #if os(iOS) || os(tvOS)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        device.videoZoomFactor = clamped
        #else
        throw EnhancedCaptureError.platformUnsupported(feature: "video zoom")
        #endif
    }

    /// Sets the torch mode; throws when the device has no torch.
    func setTorchMode(_ mode: AVCaptureDevice.TorchMode) throws {
        guard device.hasTorch, device.isTorchModeSupported(mode) else {
            throw EnhancedCaptureError.deviceConfigurationFailed(reason: "torch mode unsupported on \(device.localizedName)")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.torchMode = mode
    }

    /// Focuses (and exposes, when supported) at a point in normalized
    /// sensor coordinates: (0,0) top-left, (1,1) bottom-right, landscape.
    ///
    /// Prefers the continuous modes: the one-shot `.autoFocus` / `.autoExpose`
    /// modes transition to `.locked` after the scan, which would freeze focus
    /// and exposure at this point for the life of the device.
    func setFocusAndExposurePoint(_ point: CGPoint) throws {
        guard device.isFocusPointOfInterestSupported || device.isExposurePointOfInterestSupported else {
            throw EnhancedCaptureError.deviceConfigurationFailed(reason: "point of interest unsupported on \(device.localizedName)")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
        }
    }

    // MARK: - Cleanup

    /// Removes notification observers immediately. Call this early in the disconnect
    /// path (before async session removal) to prevent stale callbacks during cleanup.
    func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        #if os(iOS)
        rotationObservation?.invalidate()
        rotationObservation = nil
        systemPressureObservation?.invalidate()
        systemPressureObservation = nil
        #endif
    }

    /// Full cleanup: removes observers (if not already removed) and nils all capture components.
    /// Called from deviceLost() completion and from deinit as a safety net.
    func prepareForRemoval() {
        // Remove observers (safe to call even if already removed)
        removeObservers()

        // Clear all connections and components
        audioConnection = nil
        videoConnection = nil
        dataVideoOutput = nil
        dataAudioOutput = nil
        #if os(macOS)
        audioPreviewConnection = nil
        audioPreview = nil
        #endif
        #if os(iOS)
        rotationCoordinator = nil
        #endif
        input = nil
        audioPort = nil
        videoPort = nil
        previewLayer = nil
        videoPreviewConnection = nil
    }
}

// MARK: - Sample buffer delegates

extension EnhancedCaptureDevice: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if connection === videoConnection {
            delegate?.deviceVideoBuffer(
                model: device.modelID,
                sampleBuffer: sampleBuffer,
                uniqueID: device.uniqueID
            )
        } else if connection === audioConnection {
            if configuration.deliversAudioSampleBuffers {
                delegate?.deviceAudioBuffer(sampleBuffer: sampleBuffer, uniqueID: device.uniqueID)
            }
            if configuration.audioLevelMeteringEnabled {
                emitAudioLevelIfDue(connection: connection, sampleBuffer: sampleBuffer)
            }
        }
    }

    /// Reads AVFoundation's per-channel meters (no DSP of our own) and
    /// forwards them no more often than `audioLevelInterval`. Runs on `audioQueue`.
    private func emitAudioLevelIfDue(connection: AVCaptureConnection, sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastAudioLevelTime.isValid, pts.isValid {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, lastAudioLevelTime))
            if elapsed >= 0 && elapsed < configuration.audioLevelInterval { return }
        }
        lastAudioLevelTime = pts

        let channels = connection.audioChannels.map {
            EnhancedCaptureAudioLevel.Channel(averagePower: $0.averagePowerLevel, peakHold: $0.peakHoldLevel)
        }
        guard !channels.isEmpty else { return }
        delegate?.deviceAudioLevel(
            EnhancedCaptureAudioLevel(channels: channels, presentationTime: pts),
            uniqueID: device.uniqueID
        )
    }
}
