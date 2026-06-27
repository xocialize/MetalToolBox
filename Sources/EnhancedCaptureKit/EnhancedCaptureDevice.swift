//
//  File.swift
//  EnhancedCaptureKit
//
//  Created by Dustin Nielson on 2/27/26.
//

import Foundation
//
//  CaptureKitDevice.swift
//  CaptureKit
//
//  Created by Dustin Nielson on 1/9/26.
//


#if os(macOS)
import Cocoa
#elseif os(iOS)
import UIKit
#endif
import AVFoundation
import OSLog
import LoggingKit


// MARK: - CaptureDeviceDelegate Protocol

protocol EnhancedCaptureDeviceDelegate: AnyObject {
    func deviceVideoBuffer(model: String, sampleBuffer: CMSampleBuffer, uniqueID: String)
    func devicePreviewLayer(previewLayer: AVCaptureVideoPreviewLayer, model: String)
}

// MARK: - CaptureKitDevice

class EnhancedCaptureDevice: NSObject, @unchecked Sendable {
    
    // MARK: - CaptureSource
    
    nonisolated(unsafe) public private(set) var captureSource: EnhancedCaptureSource?

    // MARK: - Properties

    weak var delegate: EnhancedCaptureDeviceDelegate?

    private var observers: [NSObjectProtocol] = []
    private let captureDeviceQueue: DispatchQueue

    let device: AVCaptureDevice
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    // MARK: - Capture Components

    private(set) var input: AVCaptureInput?
    private(set) var dataVideoOutput: AVCaptureVideoDataOutput?
    private(set) var dataAudioOutput: AVCaptureAudioDataOutput?

    private var videoPort: AVCaptureInput.Port?
    private var audioPort: AVCaptureInput.Port?

    private(set) var videoConnection: AVCaptureConnection?
    private(set) var audioConnection: AVCaptureConnection?
    private(set) var videoPreviewConnection: AVCaptureConnection?

    #if os(macOS)
    private(set) var audioPreview: AVCaptureAudioPreviewOutput?
    #endif
    private(set) var videoPreviewConnectionActive: Bool = false

    // MARK: - Device Properties

    private var width: Int32 = 0
    private var height: Int32 = 0
    private var orientation: EnhancedCaptureOrientation = .portrait
    
    // MARK: - Initialization

    init(device: AVCaptureDevice, delegate: EnhancedCaptureDeviceDelegate) {
        self.device = device
        self.delegate = delegate
        self.captureDeviceQueue = DispatchQueue(
            label: "com.mvs.captureKitDevice.\(device.uniqueID)",
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
        
        // Get manufacturer (macOS-only property)
        #if os(macOS)
        let manufacturer = device.manufacturer
        #else
        let manufacturer = "Apple Inc."  // Default for iOS devices
        #endif

        // Create the capture source
        return EnhancedCaptureSource(
            id: device.uniqueID,
            type: sourceType,
            displayName: device.localizedName,
            manufacturer: manufacturer,
            modelID: device.modelID,
            uniqueID: device.uniqueID
        )
    }

    deinit {
        prepareForRemoval()
    }

    // MARK: - Setup Methods

    private func setupCaptureDevice() {
        setupDevice()
        setupInput()
        setupVideoDataOutput()
        setupVideoConnection()
        setupAudioDataOutput()
        setupAudioConnection()
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
            //fatalError("CaptureDevice :: setupPreviewLayer :: Missing video port or preview layer")
        }

        let connection = AVCaptureConnection(inputPort: videoPort, videoPreviewLayer: previewLayer)
        videoPreviewConnection = connection
        videoPreviewConnectionActive = true

        mlog.debug("Preview layer configured")
        return connection
    }

    private func setupDevice() {
        guard !device.formats.isEmpty else { return }

        do {
            try device.lockForConfiguration()
            if let highestFormat = device.formatWithHighestResolution(device.formats) {
                device.activeFormat = highestFormat
            }
            device.unlockForConfiguration()
        } catch {
            mlog.error("Failed to configure device format: \(error.localizedDescription)")
        }
    }
    
    private func setupInput() {
        do {
            input = try AVCaptureDeviceInput(device: device)

            guard let ports = input?.ports else { return }

            for port in ports {
                if port.mediaType == .audio {
                    audioPort = port
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
            self.previewLayer?.frame = CGRect(x: 0, y: 0, width: width, height: height)

            guard let previewLayer = self.previewLayer else { return }
            self.delegate?.devicePreviewLayer(previewLayer: previewLayer, model: self.device.modelID)
        }

        observers.append(observer)
    }
    
    private func setupVideoDataOutput() {
        let pixelFormat: EnhancedCapturePixelFormat = .rgb

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat.coreVideoType),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        output.setSampleBufferDelegate(self, queue: captureDeviceQueue)

        dataVideoOutput = output
        mlog.debug("Video data output configured")
    }

    private func setupVideoConnection() {
        guard let videoPort = videoPort,
              let dataVideoOutput = dataVideoOutput else {
            mlog.error("Cannot create video connection — missing components")
            return
        }

        videoConnection = AVCaptureConnection(inputPorts: [videoPort], output: dataVideoOutput)
        mlog.debug("Video connection configured")
    }

    private func setupAudioDataOutput() {
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureDeviceQueue)
        dataAudioOutput = output
    }

    private func setupAudioConnection() {
        guard let audioPort = audioPort else { return }

        #if os(macOS)
        let preview = AVCaptureAudioPreviewOutput()
        preview.volume = 1.0
        audioPreview = preview

        audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: preview)
        mlog.debug("Audio connection configured")
        #else
        // AVCaptureAudioPreviewOutput is macOS-only.
        // iOS audio capture requires AVCaptureAudioDataOutput (Phase 2).
        mlog.debug("Audio preview not available on this platform")
        #endif
    }
    
    // MARK: - Cleanup

    /// Removes notification observers immediately. Call this early in the disconnect
    /// path (before async session removal) to prevent stale callbacks during cleanup.
    func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
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
        input = nil
        audioPort = nil
        videoPort = nil
        previewLayer = nil
        videoPreviewConnection = nil
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension EnhancedCaptureDevice: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if connection === videoConnection {
            delegate?.deviceVideoBuffer(
                model: device.modelID,
                sampleBuffer: sampleBuffer,
                uniqueID: device.uniqueID
            )
        }
    }
}

// MARK: - AVCaptureDevice Extensions

extension AVCaptureDevice {

    /// Returns formats that support the specified frame rate
    func availableFormatsFor(preferredFps: Float64) -> [AVCaptureDevice.Format] {
        return formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= preferredFps && preferredFps <= range.maxFrameRate
            }
        }
    }

    /// Finds the format with the highest resolution from available formats
    func formatWithHighestResolution(_ availableFormats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        return availableFormats.max { format1, format2 in
            let dim1 = CMVideoFormatDescriptionGetDimensions(format1.formatDescription)
            let dim2 = CMVideoFormatDescriptionGetDimensions(format2.formatDescription)
            return dim1.width < dim2.width
        }
    }

    /// Finds a format that meets or exceeds the preferred size
    private func format(for preferredSize: CGSize, in availableFormats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        return availableFormats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= Int32(preferredSize.width) &&
                   dimensions.height >= Int32(preferredSize.height)
        }
    }

    /// Updates the device format based on preferred video specifications
    func updateFormat(with preferredSpec: EnhancedCaptureVideoSpec) {
        let availableFormats: [AVCaptureDevice.Format]
        if let preferredFps = preferredSpec.fps {
            availableFormats = availableFormatsFor(preferredFps: Float64(preferredFps))
        } else {
            availableFormats = formats
        }

        let selectedFormat: AVCaptureDevice.Format?
        if let preferredSize = preferredSpec.size {
            selectedFormat = format(for: preferredSize, in: availableFormats)
        } else {
            selectedFormat = formatWithHighestResolution(availableFormats)
        }

        guard let format = selectedFormat else {
            mlog.error("No suitable format found")
            return
        }

        mlog.debug("Selected format: \(String(describing: format))")

        do {
            try lockForConfiguration()
            activeFormat = format

            if let preferredFps = preferredSpec.fps {
                let frameDuration = CMTime(value: 1, timescale: preferredFps)
                activeVideoMinFrameDuration = frameDuration
                activeVideoMaxFrameDuration = frameDuration
            }

            unlockForConfiguration()
        } catch {
            mlog.error("Failed to update format: \(error.localizedDescription)")
        }
    }
}

