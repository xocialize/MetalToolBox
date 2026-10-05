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
        /// Frames at the display's pixel resolution rather than its point size (2.3.0).
        var capturesAtPixelResolution: Bool = false
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

    /// The size the running stream delivers, nil while none runs. ScreenCaptureKit keeps a
    /// stream at its configured size whatever its display does, so a display change has to
    /// re-configure it (`displayDidChange`).
    nonisolated(unsafe) private var streamSize: ScreenStreamSize?

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

        mlog.debug("[EnhancedCaptureScreen] Initialized - checking permissions")

        guard let displayId else {
            mlog.warning("[EnhancedCaptureScreen] No display ID provided")
            return
        }

        self.displayID = displayId

        // Check permissions synchronously
        let hasPermission = CGPreflightScreenCaptureAccess()
        mlog.info("[EnhancedCaptureScreen] Screen recording permission: \(hasPermission ? "granted" : "denied")")

        guard hasPermission else {
            mlog.warning("[EnhancedCaptureScreen] Screen recording permission not granted - capture will not function")
            mlog.info("[EnhancedCaptureScreen] To grant: System Settings > Privacy & Security > Screen Recording")
            return
        }

        // Create capture source from display information
        self.captureSource = createCaptureSource(for: displayId)

        if captureSource == nil {
            mlog.error("[EnhancedCaptureScreen] Failed to create capture source for display: \(displayId)")
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
        mlog.debug("[EnhancedCaptureScreen] Starting cleanup")

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

        mlog.debug("[EnhancedCaptureScreen] Deinitialized")
    }

    // MARK: - Capture Control

    func startCapture() {
        // Check if capture is already active
        guard !isCaptureActive else {
            mlog.debug("[EnhancedCaptureScreen] Capture already active")
            return
        }

        mlog.info("[EnhancedCaptureScreen] Starting capture for display: \(String(describing: self.displayID))")

        Task {
            do {
                // Get shareable content
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )

                guard let displayID = displayID,
                      let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    mlog.error("[EnhancedCaptureScreen] Display not found: \(String(describing: self.displayID))")
                    let sourceID = captureSource?.id ?? "screenx\(self.displayID.map { String($0) } ?? "unknown")"
                    delegate?.enhancedCaptureScreen(self, didChangeState: .error(.sourceUnavailable(sourceID)))
                    return
                }

                let filter = Self.filter(for: display, in: content)
                let options = self.options
                let size = ScreenStreamSize(display: Self.geometry(of: display), atPixelResolution: options.capturesAtPixelResolution)
                let config = Self.configuration(size: size, options: options)

                mlog.debug("[EnhancedCaptureScreen] Stream config: \(size) @ \(options.frameRate) fps, audio: \(options.capturesAudio)")

                // Create stream
                let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
                try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
                if options.capturesAudio {
                    try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                }

                // Start capture
                try await captureStream.startCapture()

                stream = captureStream
                streamSize = size
                isCaptureActive = true

                mlog.info("[EnhancedCaptureScreen] Screen capture started successfully")
                delegate?.enhancedCaptureScreen(self, didChangeState: .capturing)

            } catch {
                mlog.error("[EnhancedCaptureScreen] Failed to start screen capture: \(error.localizedDescription)")
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
            mlog.debug("[EnhancedCaptureScreen] No active stream to stop")
            completion?()
            return
        }

        mlog.info("[EnhancedCaptureScreen] Stopping capture")

        Task {
            do {
                try await stream.stopCapture()
                self.stream = nil
                streamSize = nil
                isCaptureActive = false
                mlog.info("[EnhancedCaptureScreen] Screen capture stopped")
            } catch {
                mlog.error("[EnhancedCaptureScreen] Failed to stop screen capture: \(error.localizedDescription)")
                self.stream = nil
                streamSize = nil
                isCaptureActive = false
            }
            delegate?.enhancedCaptureScreen(self, didChangeState: .idle)
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }
}

// MARK: - Display changes

extension EnhancedCaptureScreen {

    /// The display is now `display` (the kit's screen scan reads it after every display
    /// change). A running stream of another size than the one it calls for — its points, or
    /// its pixels when the options ask for them — is re-configured to it — the
    /// filter re-made from the display as it is now, then the output size — so its next
    /// frames arrive in the display's new shape and a consumer that lays out by the frame's
    /// size sees the change (``ScreenStreamSize/resized(stream:display:)``). Before 2.2.2 the
    /// stream kept the size it started with: a 16:10 laptop switched to 16:9 was mirrored
    /// 16:10, the desktop letterboxed inside each frame.
    ///
    /// Returns whether the stream was re-configured. When ScreenCaptureKit refuses the new
    /// configuration the stream is restarted instead, which reads the display afresh.
    @discardableResult
    func displayDidChange(to display: ScreenDisplayGeometry) async -> Bool {
        let wanted = ScreenStreamSize(display: display, atPixelResolution: options.capturesAtPixelResolution)
        guard let stream, let newSize = ScreenStreamSize.resized(stream: streamSize, display: wanted) else { return false }
        let oldSize = streamSize.map(String.init(describing:)) ?? "none"
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let displayID, let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                mlog.warning("[EnhancedCaptureScreen] Display \(String(describing: self.displayID)) changed but is not listed — stream left as it is")
                return false
            }
            // The size is the scan's reading, taken in the same pass; a change after it is
            // read by the next pass (the kit's ScreenScanGate runs one when a change lands
            // mid-scan).
            try await stream.updateContentFilter(Self.filter(for: scDisplay, in: content))
            try await stream.updateConfiguration(Self.configuration(size: newSize, options: options))
            streamSize = newSize
            mlog.info("[EnhancedCaptureScreen] Display \(displayID) changed size \(oldSize) → \(newSize) — stream re-configured")
            return true
        } catch {
            mlog.error("[EnhancedCaptureScreen] Re-configuring the stream for \(newSize) failed: \(error.localizedDescription) — restarting it")
            await restart()
            return false
        }
    }

    /// Stops the stream, then starts it again from the display as it is now.
    private func restart() async {
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            stopCapture { resume.resume() }
        }
        startCapture()
    }

    /// The display's size in points and its pixels per point, as the stream start and the
    /// kit's scan both read it.
    static func geometry(of display: SCDisplay) -> ScreenDisplayGeometry {
        ScreenDisplayGeometry(width: display.width, height: display.height,
                              pixelScale: Double(SCContentFilter(display: display, excludingWindows: []).pointPixelScale))
    }

    /// The display, less this application's own windows (a Surface must not mirror itself).
    static func filter(for display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
    }

    /// The stream's configuration at `size`, the rest from the options fixed at discovery.
    static func configuration(size: ScreenStreamSize, options: Options) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.pixelFormat = options.pixelFormat
        config.minimumFrameInterval = CMTime(value: 1, timescale: max(1, options.frameRate))
        config.showsCursor = options.showsCursor
        config.capturesAudio = options.capturesAudio
        config.excludesCurrentProcessAudio = true
        return config
    }
}

// MARK: - SCStreamDelegate

@available(macOS 14.0, *)
extension EnhancedCaptureScreen: SCStreamDelegate {
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        mlog.error("[EnhancedCaptureScreen] Stream stopped with error: \(error.localizedDescription)")
        isCaptureActive = false
        self.stream = nil
        streamSize = nil
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

    nonisolated(unsafe) private static let frameStatusKey = SCStreamFrameInfo.status.rawValue as CFString

    /// `true` when the frame status attachment is missing or `.complete`.
    ///
    /// Reads the one key it needs through CoreFoundation: bridging the whole
    /// attachment dictionary (`as? [[SCStreamFrameInfo: Any]]`) allocates and
    /// re-hashes every key on every frame, on the delivery queue, ahead of the
    /// consumer's texture upload.
    nonisolated private static func frameIsComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0,
              let first = CFArrayGetValueAtIndex(attachments, 0) else {
            return true
        }
        let dictionary = Unmanaged<CFDictionary>.fromOpaque(first).takeUnretainedValue()
        guard let rawValue = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(frameStatusKey).toOpaque()) else {
            return true
        }
        let number = Unmanaged<CFNumber>.fromOpaque(rawValue).takeUnretainedValue()
        var rawStatus = 0
        guard CFNumberGetValue(number, .nsIntegerType, &rawStatus),
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }
        return status == .complete
    }
}

#endif
