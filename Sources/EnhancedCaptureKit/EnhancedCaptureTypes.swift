//
//  EnhancedCaptureTypes.swift
//  EnhancedCaptureKit
//
//  Created by Dustin Nielson on 2/27/26.
//

import Foundation
import AVFoundation
import CoreMedia

// MARK: - CaptureSourceType

/// Types of capture sources
///
/// This enum is public and available to parent applications for use in
/// delegate implementations, switch statements, and source filtering.
public enum EnhancedCaptureSourceType: Sendable, Hashable {
    /// External capture device (HDMI capture card, UVC camera, etc.)
    case externalDevice

    /// Connected iOS/iPadOS device via USB (macOS only)
    /// Note: Only one iOS device can be active at a time
    case iOSDevice

    /// Display screen capture (macOS only)
    case screen

    /// Primary display — CGMainDisplayID() (macOS only)
    case screenMain

    /// Front-facing camera (iOS / iPadOS only)
    case cameraFront

    /// Back-facing camera (iOS / iPadOS only)
    case cameraBack

    /// Audio-only input device (built-in or external microphone).
    ///
    /// Only discovered when ``EnhancedCaptureConfiguration/audioEnabled`` is set.
    /// On iOS / iPadOS there is a single microphone source whose physical
    /// route (built-in, USB-C, Bluetooth) follows the app's `AVAudioSession`
    /// preferred input — see ``EnhancedCaptureKit/setPreferredAudioInput(_:)``.
    case microphone
}

// MARK: - Media kinds

/// The kinds of media a capture source can deliver.
public struct EnhancedCaptureMediaKinds: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let video = EnhancedCaptureMediaKinds(rawValue: 1 << 0)
    public static let audio = EnhancedCaptureMediaKinds(rawValue: 1 << 1)
}

// MARK: - CaptureSource

/// Identifies a capture source
///
/// Provided by EnhancedCaptureKit via delegate; use to request start/stop capture.
/// The `type` property uses `EnhancedCaptureSourceType` for easy switching.
public struct EnhancedCaptureSource: Sendable, Hashable, Identifiable {

    /// Unique identifier for this source
    /// Format varies by type:
    /// - External device / microphone: device uniqueID (e.g., "0x1234567890abcdef")
    /// - iOS device: device uniqueID (e.g., "abc123-device-id")
    /// - Screen: "screenx{displayID}" (e.g., "screenx1", "screenx4280844032")
    public let id: String

    /// The type of capture source
    public let type: EnhancedCaptureSourceType

    /// Human-readable name for display
    public let displayName: String

    /// Device manufacturer (empty for screens)
    public let manufacturer: String

    /// Device model identifier
    public let modelID: String

    /// Unique device identifier
    /// For screens, this contains the CGDirectDisplayID as a string
    public let uniqueID: String

    /// Which media this source delivers when enabled. A camera is `.video`; a
    /// microphone is `.audio`; an HDMI capture card with embedded audio (or a
    /// screen with system-audio capture on) is `[.video, .audio]`.
    public let media: EnhancedCaptureMediaKinds

    init(
        id: String,
        type: EnhancedCaptureSourceType,
        displayName: String,
        manufacturer: String,
        modelID: String,
        uniqueID: String,
        media: EnhancedCaptureMediaKinds = .video
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.modelID = modelID
        self.uniqueID = uniqueID
        self.media = media
    }

    /// `true` when enabling this source can deliver audio sample buffers.
    public var hasAudio: Bool { media.contains(.audio) }

    /// `true` when enabling this source delivers video sample buffers.
    public var hasVideo: Bool { media.contains(.video) }
}

// MARK: - CaptureSourceState

/// Current state of a capture source, reported through
/// `EnhancedCaptureDelegate.enhancedCapture(_:sourceStateDidChange:for:)`.
public enum EnhancedCaptureSourceState: Sendable {
    /// Source is available but not capturing
    case idle

    /// Source is actively capturing and delivering frames
    case capturing

    /// Source was capturing but is temporarily interrupted (iOS: another app
    /// took the camera, the app went to the background, system pressure, …).
    /// AVFoundation resumes automatically when the interruption ends.
    case interrupted

    /// Source encountered an error
    case error(EnhancedCaptureError)
}

// MARK: - EnhancedCaptureError

/// Errors that can occur during capture operations
public enum EnhancedCaptureError: Error, Sendable, CustomStringConvertible {
    /// Required permission not granted
    case permissionDenied(PermissionType)

    /// Requested source not found or unavailable
    case sourceUnavailable(String)

    /// Failed to start capture
    case captureStartFailed(reason: String)

    /// Capture stream interrupted unexpectedly
    case streamInterrupted(reason: String)

    /// Feature not available on current platform
    case platformUnsupported(feature: String)

    /// A device rejected a configuration change (format, zoom, torch, …)
    case deviceConfigurationFailed(reason: String)

    /// The underlying `AVCaptureSession` reported a runtime error. When
    /// `willRestart` is true the kit is restarting the session itself
    /// (media services reset); otherwise the consumer decides.
    case sessionRuntimeError(reason: String, willRestart: Bool)

    public var description: String {
        switch self {
        case .permissionDenied(let type):
            return "Permission denied: \(type)"
        case .sourceUnavailable(let id):
            return "Source unavailable: \(id)"
        case .captureStartFailed(let reason):
            return "Capture start failed: \(reason)"
        case .streamInterrupted(let reason):
            return "Stream interrupted: \(reason)"
        case .platformUnsupported(let feature):
            return "Not supported on this platform: \(feature)"
        case .deviceConfigurationFailed(let reason):
            return "Device configuration failed: \(reason)"
        case .sessionRuntimeError(let reason, let willRestart):
            return "Session runtime error: \(reason)\(willRestart ? " (restarting)" : "")"
        }
    }
}

/// Permission types that EnhancedCaptureKit may require
public enum PermissionType: Sendable, Hashable {
    case camera
    case microphone
    case screenRecording
}

/// Current status of a permission request
public enum PermissionStatus: Sendable, Equatable {
    /// Permission has been granted
    case authorized
    /// Permission has been denied by the user
    case denied
    /// Permission has not been requested yet
    case notDetermined
    /// Permission is restricted by system policy (parental controls, MDM, etc.)
    case restricted
}

// MARK: - Session interruption (iOS / iPadOS)

/// Why an `AVCaptureSession` was interrupted. Mirrors
/// `AVCaptureSession.InterruptionReason` without leaking AVFoundation into
/// consumer switch statements.
public enum EnhancedCaptureInterruptionReason: Sendable, Hashable {
    /// The app moved to the background and does not hold multitasking camera access.
    case videoDeviceNotAvailableInBackground
    /// Another client (phone call, Siri, another app) owns the audio device.
    case audioDeviceInUseByAnotherClient
    /// Another app owns the camera.
    case videoDeviceInUseByAnotherClient
    /// iPad Split View / Slide Over / Stage Manager without multitasking camera access.
    case videoDeviceNotAvailableWithMultipleForegroundApps
    /// Thermal or other system pressure shut the camera down.
    case videoDeviceNotAvailableDueToSystemPressure
    /// A reason this version of the kit does not know; raw `AVCaptureSession.InterruptionReason` value.
    case unknown(Int)
}

/// Session-level interruption transitions, reported through
/// `EnhancedCaptureDelegate.enhancedCapture(_:sessionInterruptionDidChange:)`.
public enum EnhancedCaptureSessionInterruption: Sendable, Hashable {
    /// Capture paused. `reason` is `nil` when the system did not say why.
    case began(reason: EnhancedCaptureInterruptionReason?)
    /// Capture resumed.
    case ended
}

// MARK: - Audio level

/// Per-channel audio level snapshot in decibels (0 dB = full scale), as
/// measured by AVFoundation for the connection that delivered the buffer.
public struct EnhancedCaptureAudioLevel: Sendable, Equatable {
    public struct Channel: Sendable, Equatable {
        /// Average power over the last buffer, in dBFS.
        public let averagePower: Float
        /// Peak-hold level, in dBFS.
        public let peakHold: Float
    }

    /// One entry per channel, in channel order.
    public let channels: [Channel]

    /// Presentation time of the buffer the level was measured on.
    public let presentationTime: CMTime

    /// Loudest peak-hold value across all channels (`-inf` when there are no channels).
    public var peak: Float { channels.map(\.peakHold).max() ?? -.infinity }

    /// Loudest average-power value across all channels (`-inf` when there are no channels).
    public var average: Float { channels.map(\.averagePower).max() ?? -.infinity }
}

// MARK: - Legacy device family helpers

public enum EnhancedCaptureDeviceFamily: String, CaseIterable {
    // iPhones
    case iPhoneLegacy       // Pre-X: 3:2 or 16:9 aspect (4s, 5, 6, 7, 8, SE)
    case iPhoneModern       // X-series and later: ~19.5:9 aspect (X through 16 Pro Max)

    // iPads
    case iPad               // Standard 4:3 (9.7"–10.2" models, Pro 12.9"/13")
    case iPadAir            // 10.9"–11" Air and standard iPad (gen 10/11): ~1.44 aspect
    case iPadPro11          // iPad Pro 11": ~1.43 aspect
    case iPadMini           // iPad mini 8.3": ~2:3 aspect

    /// String identifier for logging.
    public var raw: String {
        switch self {
        case .iPhoneLegacy:  return "iPhoneLegacy"
        case .iPhoneModern:  return "iPhoneModern"
        case .iPad:          return "iPad"
        case .iPadAir:       return "iPadAir"
        case .iPadPro11:     return "iPadPro11"
        case .iPadMini:      return "iPadMini"
        }
    }

    /// Bezel asset base name for image lookup.
    /// Maps device family to one of the available bezel images:
    ///   iPhone families  → "bezel_iPhone"
    ///   iPad families    → "bezel_iPadPro"
    public var bezelAssetBase: String {
        switch self {
        case .iPhoneLegacy, .iPhoneModern:
            return "bezel_iPhone"
        case .iPad, .iPadAir, .iPadPro11, .iPadMini:
            return "bezel_iPadPro"
        }
    }
}

public enum EnhancedCaptureOrientation {
    case portrait, landscape
}

// MARK: - Pixel format

/// Pixel format requested from `AVCaptureVideoDataOutput`.
///
/// `TextureConverter` currently uploads `.bgra` (and RGBA) zero-copy via
/// `CVMetalTextureCache`; the biplanar YCbCr formats need a two-plane
/// texture path plus a YCbCr→RGB shader before they are useful downstream.
/// They are exposed so a consumer with its own converter can opt in.
public enum EnhancedCapturePixelFormat: Sendable, Hashable {
    /// 32-bit BGRA — the default, consumed directly by `TextureConverter`.
    case bgra
    /// 8-bit biplanar YCbCr 4:2:0, video range (`420v`) — least bandwidth.
    case yCbCr420VideoRange
    /// 8-bit biplanar YCbCr 4:2:0, full range (`420f`).
    case yCbCr420FullRange

    public var coreVideoType: OSType {
        switch self {
        case .bgra:                 return kCVPixelFormatType_32BGRA
        case .yCbCr420VideoRange:   return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .yCbCr420FullRange:    return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }
}

// MARK: - Internal frame wrapper (IOSurface path)

struct EnhancedCaptureCapturedFrame: @unchecked Sendable {
    static var invalid: EnhancedCaptureCapturedFrame {
        EnhancedCaptureCapturedFrame(surface: nil, contentRect: .zero, contentScale: 0, scaleFactor: 0)
    }

    let surface: IOSurface?
    let contentRect: CGRect
    let contentScale: CGFloat
    let scaleFactor: CGFloat

    var size: CGSize { contentRect.size }
}

/// Wraps a non-`Sendable` reference so it can cross a `@Sendable` closure
/// boundary when the caller guarantees the transfer is safe (e.g. a
/// notification's `AVCaptureDevice` handed straight to the main actor).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
