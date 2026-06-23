//
//  EnhancedCaptureTypes.swift
//  EnhancedCaptureKit
//
//  Created by Dustin Nielson on 2/27/26.
//

import Foundation


import Foundation
import AVFoundation

// MARK: - CaptureSourceType

/// Types of capture sources
///
/// This enum is public and available to parent applications for use in
/// delegate implementations, switch statements, and source filtering.
public enum EnhancedCaptureSourceType: Sendable, Hashable {
    /// External capture device (HDMI capture card, etc.)
    case externalDevice

    /// Connected iOS/iPadOS device via USB (macOS only)
    /// Note: Only one iOS device can be active at a time
    case iOSDevice

    /// Display screen capture (macOS only)
    case screen

    /// Primary display — CGMainDisplayID() (macOS only)
    case screenMain

    /// Front-facing camera (iPadOS only)
    case cameraFront

    /// Back-facing camera (iPadOS only)
    case cameraBack
}

// MARK: - CaptureSource

/// Identifies a capture source
///
/// Provided by EnhancedCaptureKit via delegate; use to request start/stop capture.
/// The `type` property uses `CaptureSourceType` enum for easy switching.
public struct EnhancedCaptureSource: Sendable, Hashable, Identifiable {

    /// Unique identifier for this source
    /// Format varies by type:
    /// - External device: device uniqueID (e.g., "0x1234567890abcdef")
    /// - iOS device: device uniqueID (e.g., "abc123-device-id")
    /// - Screen: "screen-{displayID}" (e.g., "screen-1", "screen-4280844032")
    /// - Camera: "camera-front" or "camera-back"
    public let id: String

    /// The type of capture source
    public let type: EnhancedCaptureSourceType

    /// Human-readable name for display
    public let displayName: String

    /// Device manufacturer (empty for screens/cameras)
    public let manufacturer: String

    /// Device model identifier
    public let modelID: String

    /// Unique device identifier
    /// For screens, this contains the CGDirectDisplayID as a string
    public let uniqueID: String
}

// MARK: - CaptureSourceState

/// Current state of a capture source
public enum EnhancedCaptureSourceState: Sendable {
    /// Source is available but not capturing
    case idle

    /// Source is actively capturing and delivering frames
    case capturing

    /// Source was capturing but temporarily interrupted
    /// EnhancedCaptureKit will attempt automatic reconnection
    case interrupted

    /// Source encountered an error
    case error(EnhancedCaptureError)
}

// MARK: - EnhancedCaptureError

/// Errors that can occur during capture operations
public enum EnhancedCaptureError: Error, Sendable {
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
}

/// Permission types that EnhancedCaptureKit may require
public enum PermissionType: Sendable {
    case camera
    case screenRecording
}

/// Current status of a permission request
public enum PermissionStatus: Sendable {
    /// Permission has been granted
    case authorized
    /// Permission has been denied by the user
    case denied
    /// Permission has not been requested yet
    case notDetermined
    /// Permission is restricted by system policy (parental controls, MDM, etc.)
    case restricted
}

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

enum EnhancedCapturePixelFormat {
    case rgb
    case yCbCr
    
    var coreVideoType: OSType {
        switch self {
        case .rgb:
            return kCVPixelFormatType_32BGRA
        case .yCbCr:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            
        }
    }
}

struct EnhancedCaptureVideoSpec {
    var fps: Int32?
    var size: CGSize?
}

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
