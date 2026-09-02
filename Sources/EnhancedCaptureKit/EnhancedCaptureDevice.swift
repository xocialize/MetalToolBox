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

    /// The device exposes a video port (camera, capture card, iOS device).
    var hasVideo: Bool { videoPort != nil }
    /// The device exposes an audio port (microphone, muxed capture card).
    var hasAudio: Bool { audioPort != nil }

    // MARK: - Device Properties

    private var width: Int32 = 0
    private var height: Int32 = 0
    private var orientation: EnhancedCaptureOrientation = .portrait

    // Audio level throttle — touched only on `audioQueue`.
    nonisolated(unsafe) private var lastAudioLevelTime: CMTime = .invalid

    #if os(iOS)
    @available(iOS 17.0, *)
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator? {
        get { _rotationCoordinator as? AVCaptureDevice.RotationCoordinator }
        set { _rotationCoordinator = newValue }
    }
    private var _rotationCoordinator: AnyObject?
    private var rotationObservation: NSKeyValueObservation?
    #endif

    // MARK: - Initialization

    init(device: AVCaptureDevice, delegate: EnhancedCaptureDeviceDelegate, configuration: EnhancedCaptureConfiguration = .default) {
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
        // Determine the source type based on device characteristics
        let sourceType: EnhancedCaptureSourceType

        if !hasVideo {
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
        if hasVideo { media.insert(.video) }
        if hasAudio && configuration.audioEnabled { media.insert(.audio) }

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

    /// Applies the configured video preference.
    ///
    /// Without a preference, macOS keeps the historical behaviour of selecting
    /// the device's largest format (macOS honours a format set before the
    /// input joins the session). iOS / tvOS leave the format alone so the
    /// `.high` preset governs — there, a format set here would be reset the
    /// moment the input is added anyway; see ``reapplyVideoPreference()``.
    private func setupDevice() {
        guard hasVideo else { return }
        #if os(macOS)
        let preference = configuration.videoPreference ?? EnhancedCaptureVideoPreference()
        #else
        guard let preference = configuration.videoPreference else { return }
        #endif
        apply(preference)
    }

    /// iOS / tvOS reset `activeFormat` and the frame-duration lock when an
    /// input is added to a session, so the kit calls this again inside the
    /// session's begin/commitConfiguration right after adding the input.
    func reapplyVideoPreference() {
        guard hasVideo, let preference = configuration.videoPreference else { return }
        apply(preference)
    }

    private func apply(_ preference: EnhancedCaptureVideoPreference) {
        do {
            if try device.applyVideoPreference(preference) == nil {
                mlog.warning("No video formats reported by \(self.device.localizedName); keeping default format")
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

    /// Audio wiring. Sample-buffer delivery goes through an
    /// `AVCaptureAudioDataOutput` on its own queue so audio callbacks never
    /// wait behind video frames; the macOS speaker preview is a second output
    /// on the same port.
    private func setupAudio() {
        guard let audioPort = audioPort, configuration.audioEnabled else {
            if audioPort != nil { mlog.debug("Audio port present but audio capture is disabled") }
            return
        }

        if configuration.deliversAudioSampleBuffers {
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: audioQueue)
            dataAudioOutput = output
            audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: output)
            mlog.debug("Audio data connection configured")
        }

        #if os(macOS)
        if configuration.audioPreviewEnabled {
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
    /// Built-in cameras deliver sensor-oriented buffers. The rotation
    /// coordinator tracks the angle that makes them upright and the video
    /// connection applies it before delivery.
    private func setupRotationCoordinator() {
        guard hasVideo,
              device.position != .unspecified,
              configuration.cameraRotationMode != .none,
              #available(iOS 17.0, *) else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator

        let keyPath: KeyPath<AVCaptureDevice.RotationCoordinator, CGFloat>
        switch configuration.cameraRotationMode {
        case .horizonLevelCapture: keyPath = \.videoRotationAngleForHorizonLevelCapture
        case .horizonLevelPreview, .none: keyPath = \.videoRotationAngleForHorizonLevelPreview
        }

        rotationObservation = coordinator.observe(keyPath, options: [.initial, .new]) { [weak self] coordinator, _ in
            self?.applyRotationAngle(coordinator[keyPath: keyPath])
        }
        mlog.debug("Rotation coordinator active for \(self.device.localizedName)")
    }

    private func applyRotationAngle(_ angle: CGFloat) {
        guard let connection = videoConnection else { return }
        if #available(iOS 17.0, *), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        delegate?.deviceVideoRotationAngleDidChange(angle, uniqueID: device.uniqueID)
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
    func setFocusAndExposurePoint(_ point: CGPoint) throws {
        guard device.isFocusPointOfInterestSupported || device.isExposurePointOfInterestSupported else {
            throw EnhancedCaptureError.deviceConfigurationFailed(reason: "point of interest unsupported on \(device.localizedName)")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = point
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
            device.exposurePointOfInterest = point
            device.exposureMode = .autoExpose
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
        _rotationCoordinator = nil
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
            delegate?.deviceAudioBuffer(sampleBuffer: sampleBuffer, uniqueID: device.uniqueID)
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
