//
//  EnhancedCaptureScreen.swift
//  EnhancedCaptureKit
//
//  Created by Dustin Nielson on 2/27/26.
//

#if os(macOS)

import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import OSLog
import LoggingKit

protocol EnhancedCaptureScreenDelegate: AnyObject {
    nonisolated func enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource)
    nonisolated func enhancedCaptureScreenDidOutputAudioSampleBuffer(sampleBuffer: CMSampleBuffer, source: EnhancedCaptureSource)
    nonisolated func enhancedCaptureScreen(_ screen: EnhancedCaptureScreen, didChangeState state: EnhancedCaptureSourceState)
}

// MARK: - CaptureScreen

public class EnhancedCaptureScreen: NSObject, @unchecked Sendable {

    /// Stream options fixed when the screen is discovered.
    struct Options: Sendable {
        var frameRate: Int32 = 30
        var showsCursor: Bool = true
        var capturesAudio: Bool = false
        var pixelFormat: OSType = kCVPixelFormatType_32BGRA
    }

    // MARK: - CaptureSource / displayID

    nonisolated(unsafe) public private(set) var captureSource: EnhancedCaptureSource?

    // Public properties accessed externally
    nonisolated(unsafe) public private(set) var displayID: CGDirectDisplayID?

    // MARK: - Properties

    // Delegate must be nonisolated(unsafe) to access from nonisolated methods
    nonisolated(unsafe) weak var delegate: EnhancedCaptureScreenDelegate?

    nonisolated(unsafe) private var options = Options()

    private let videoQueue = DispatchQueue(
        label: "com.xocialize.MetalToolBox.EnhancedCaptureScreen.video",
        qos: .userInteractive
    )
    private let audioQueue = DispatchQueue(
        label: "com.xocialize.MetalToolBox.EnhancedCaptureScreen.audio",
        qos: .userInteractive
    )

    nonisolated(unsafe) private var stream: SCStream?

    // Synchronization lock for capture state
    private let stateLock = NSLock()
    nonisolated(unsafe) private var _isCaptureActive = false

    nonisolated private var isCaptureActive: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isCaptureActive
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _isCaptureActive = newValue
        }
    }

    // MARK: - Initialization

    convenience init(delegate: EnhancedCaptureScreenDelegate, displayId: CGDirectDisplayID? = nil, options: Options = Options()) {
        self.init()
        self.delegate = delegate
        self.options = options

        mlog.debug("[CaptureKitScreen] Initialized - checking permissions")

        guard let displayId else {
            mlog.warning("[CaptureKitScreen] No display ID provided")
            return
        }

        self.displayID = displayId

        // Check permissions synchronously
        let hasPermission = CGPreflightScreenCaptureAccess()
        mlog.info("[CaptureKitScreen] Screen recording permission: \(hasPermission ? "granted" : "denied")")

        guard hasPermission else {
            mlog.warning("[CaptureKitScreen] Screen recording permission not granted - capture will not function")
            mlog.info("[CaptureKitScreen] To grant: System Settings > Privacy & Security > Screen Recording")
            return
        }

        // Create capture source from display information
        self.captureSource = createCaptureSource(for: displayId)

        if captureSource == nil {
            mlog.error("[CaptureKitScreen] Failed to create capture source for display: \(displayId)")
        }
    }

    // MARK: - Private Helpers

    private func createCaptureSource(for displayId: CGDirectDisplayID) -> EnhancedCaptureSource? {
        guard let screen = NSScreen.screens.first(where: { screen in
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return screenNumber == displayId
        }) else {
            return nil
        }

        let localizedName = screen.localizedName
        return EnhancedCaptureSource(
            id: "screenx\(displayId)",
            type: displayId == CGMainDisplayID() ? .screenMain : .screen,
            displayName: !localizedName.isEmpty ? localizedName : "Display \(displayId)",
            manufacturer: "Apple",
            modelID: "Screen",
            uniqueID: "screenx\(displayId)",
            media: options.capturesAudio ? [.video, .audio] : .video
        )
    }

    deinit {
        mlog.debug("[CaptureKitScreen] Starting cleanup")

        // Stop the stream synchronously if possible
        // Note: We cannot await in deinit, so we use a blocking approach
        if let stream = stream, isCaptureActive {
            // Best-effort cleanup. Use the completion-handler variant so we don't
            // have to send the non-Sendable SCStream into a detached task.
            stream.stopCapture { _ in
                // Error during cleanup - nothing we can do in deinit
            }
        }

        // Clear references immediately
        self.stream = nil
        self.delegate = nil
        self.captureSource = nil

        mlog.debug("[CaptureKitScreen] Deinitialized")
    }

    // MARK: - Capture Control

    func startCapture() {
        // Check if capture is already active
        guard !isCaptureActive else {
            mlog.debug("[CaptureKitScreen] Capture already active")
            return
        }

        mlog.info("[CaptureKitScreen] Starting capture for display: \(String(describing: self.displayID))")

        Task {
            do {
                // Get shareable content
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )

                guard let displayID = displayID,
                      let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    mlog.error("[CaptureKitScreen] Display not found: \(String(describing: self.displayID))")
                    delegate?.enhancedCaptureScreen(self, didChangeState: .error(.sourceUnavailable("screenx\(String(describing: self.displayID))")))
                    return
                }

                // Exclude this application
                let excludedApps = content.applications.filter { app in
                    Bundle.main.bundleIdentifier == app.bundleIdentifier
                }

                // Create filter
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApps,
                    exceptingWindows: []
                )

                // Configure stream
                let options = self.options
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.pixelFormat = options.pixelFormat
                config.minimumFrameInterval = CMTime(value: 1, timescale: max(1, options.frameRate))
                config.showsCursor = options.showsCursor
                config.capturesAudio = options.capturesAudio
                config.excludesCurrentProcessAudio = true

                mlog.debug("[CaptureKitScreen] Stream config: \(config.width)x\(config.height) @ \(options.frameRate) fps, audio: \(options.capturesAudio)")

                // Create stream
                let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
                try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
                if options.capturesAudio {
                    try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                }

                // Start capture
                try await captureStream.startCapture()

                stream = captureStream
                isCaptureActive = true

                mlog.info("[CaptureKitScreen] Screen capture started successfully")
                delegate?.enhancedCaptureScreen(self, didChangeState: .capturing)

            } catch {
                mlog.error("[CaptureKitScreen] Failed to start screen capture: \(error.localizedDescription)")
                isCaptureActive = false
                delegate?.enhancedCaptureScreen(self, didChangeState: .error(.captureStartFailed(reason: error.localizedDescription)))
            }
        }
    }

    func stopCapture() {
        stopCapture(completion: nil)
    }

    /// Stops screen capture with an optional completion callback.
    /// Use the completion variant when cleanup ordering matters (e.g., screenLost
    /// needs to remove the screen from the array only after the stream has stopped).
    func stopCapture(completion: (@Sendable () -> Void)?) {
        guard let stream = stream else {
            mlog.debug("[CaptureKitScreen] No active stream to stop")
            completion?()
            return
        }

        mlog.info("[CaptureKitScreen] Stopping capture")

        Task {
            do {
                try await stream.stopCapture()
                self.stream = nil
                isCaptureActive = false
                mlog.info("[CaptureKitScreen] Screen capture stopped")
            } catch {
                mlog.error("[CaptureKitScreen] Failed to stop screen capture: \(error.localizedDescription)")
                self.stream = nil
                isCaptureActive = false
            }
            delegate?.enhancedCaptureScreen(self, didChangeState: .idle)
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }
}

// MARK: - SCStreamDelegate

@available(macOS 14.0, *)
extension EnhancedCaptureScreen: SCStreamDelegate {
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        mlog.error("[CaptureKitScreen] Stream stopped with error: \(error.localizedDescription)")
        isCaptureActive = false
        self.stream = nil
        delegate?.enhancedCaptureScreen(self, didChangeState: .error(.streamInterrupted(reason: error.localizedDescription)))
    }
}

// MARK: - SCStreamOutput

@available(macOS 14.0, *)
extension EnhancedCaptureScreen: SCStreamOutput {
    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let source = captureSource else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit also emits .idle / .blank / .suspended frames that
            // carry no new pixels; only complete frames are worth a GPU upload.
            guard Self.frameIsComplete(sampleBuffer) else { return }
            delegate?.enhancedCaptureScreenDidOutputSampleBuffer(sampleBuffer: sampleBuffer, source: source)
        case .audio:
            delegate?.enhancedCaptureScreenDidOutputAudioSampleBuffer(sampleBuffer: sampleBuffer, source: source)
        default:
            break
        }
    }

    /// `true` when the frame status attachment is missing or `.complete`.
    nonisolated private static func frameIsComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }
        return status == .complete
    }
}

#endif
