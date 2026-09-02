//
//  EnhancedCaptureConfiguration.swift
//  EnhancedCaptureKit
//
//  Construction-time options for EnhancedCaptureKit. Every default reproduces
//  the pre-configuration behaviour of the kit, so `init(delegate:)` consumers
//  see no change; new capabilities (audio, iPad session handling, format
//  preference) are opt-in.
//

import Foundation
import CoreGraphics

// MARK: - Video format preference

/// What the kit should ask a device for. `nil` fields mean "don't care".
///
/// When a preference is set the session runs with `.inputPriority` so the
/// device's `activeFormat` is honoured; without one the session keeps the
/// `.high` preset and the device's default format (the historical behaviour).
public struct EnhancedCaptureVideoPreference: Sendable, Equatable {
    /// Smallest acceptable frame size. The kit picks the format that meets or
    /// exceeds it with the least excess; `nil` selects the largest format.
    public var preferredSize: CGSize?

    /// Frame rate the format must support and the device is then locked to.
    public var preferredFrameRate: Double?

    public init(preferredSize: CGSize? = nil, preferredFrameRate: Double? = nil) {
        self.preferredSize = preferredSize
        self.preferredFrameRate = preferredFrameRate
    }

    /// 1080p at 30 fps — a sane iPad default that avoids photo-oriented formats.
    public static let hd1080p30 = EnhancedCaptureVideoPreference(
        preferredSize: CGSize(width: 1920, height: 1080), preferredFrameRate: 30
    )

    /// 1080p at 60 fps.
    public static let hd1080p60 = EnhancedCaptureVideoPreference(
        preferredSize: CGSize(width: 1920, height: 1080), preferredFrameRate: 60
    )

    /// UHD 4K at 30 fps.
    public static let uhd4K30 = EnhancedCaptureVideoPreference(
        preferredSize: CGSize(width: 3840, height: 2160), preferredFrameRate: 30
    )
}

// MARK: - Audio session policy (iOS / tvOS)

/// Who owns `AVAudioSession` while the kit captures audio on iOS / tvOS.
public enum EnhancedCaptureAudioSessionPolicy: Sendable, Hashable {
    /// `AVCaptureSession` configures the shared audio session itself
    /// (`automaticallyConfiguresApplicationAudioSession = true`). Right for
    /// apps that don't otherwise play or record audio.
    case automatic

    /// The app configures `AVAudioSession` (category, mode, preferred input)
    /// and the kit leaves it alone. Use this when the app also plays audio.
    case applicationManaged

    /// The capture session uses its own private audio session
    /// (`usesApplicationAudioSession = false`). Isolates capture from the
    /// app's playback entirely; the app cannot route capture input.
    case detached
}

// MARK: - Camera rotation (iOS)

/// How camera frames are rotated before delivery on iOS / iPadOS.
///
/// Camera buffers arrive in sensor orientation (landscape, home-button right).
/// Without rotation a portrait iPad shows the camera sideways.
///
/// There is no interface-orientation ("horizon-level preview") mode:
/// `AVCaptureDevice.RotationCoordinator` only computes that angle for a
/// `CALayer` that is in a view hierarchy, and the kit owns no such layer.
/// Rotating in the compositor is free and is the recommended path for a
/// texture pipeline; `.horizonLevelCapture` exists for frames that leave
/// the device.
public enum EnhancedCaptureRotationMode: Sendable, Hashable {
    /// Deliver sensor-oriented buffers; the compositor applies any rotation.
    /// The video connection is pinned to 0° (Spring-2024 and later iPads
    /// default the front camera's data output to 180° otherwise).
    case none

    /// Follow gravity so frames are upright relative to the real horizon
    /// regardless of UI orientation (`videoRotationAngleForHorizonLevelCapture`).
    /// AVFoundation physically rotates every buffer, so this costs a render
    /// pass per frame and re-configures the pipeline on each orientation change.
    /// Right for recording or sending frames off-device.
    case horizonLevelCapture
}

// MARK: - Configuration

/// Options fixed at `EnhancedCaptureKit` construction.
public struct EnhancedCaptureConfiguration: Sendable, Equatable {

    // MARK: Audio

    /// Discover microphones and capture the audio ports of muxed devices
    /// (HDMI capture cards) as sample buffers / levels. Requires
    /// `NSMicrophoneUsageDescription`; the kit requests microphone permission
    /// during initialisation when this is on. Does not affect the macOS
    /// speaker preview (`audioPreviewEnabled`) or display system audio
    /// (`screenAudioEnabled`).
    public var audioEnabled: Bool = false

    /// Deliver audio sample buffers (device and display audio) to
    /// `EnhancedCaptureDelegate.enhancedCaptureDidOutputAudioSampleBuffer(sampleBuffer:source:)`.
    /// With this off and `audioLevelMeteringEnabled` on, device audio is still
    /// captured for metering but no buffers reach the delegate.
    public var deliversAudioSampleBuffers: Bool = true

    /// macOS only: play a muxed device's embedded audio (HDMI capture card)
    /// through the default output via `AVCaptureAudioPreviewOutput`.
    /// Independent of `audioEnabled` and of microphone permission, and never
    /// applied to microphone sources (that would feed the mic to the speakers).
    /// Historical signage behaviour — on before this configuration existed,
    /// so it stays on by default on macOS.
    public var audioPreviewEnabled: Bool = {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }()

    /// Volume for the macOS audio preview output (0…1).
    public var audioPreviewVolume: Float = 1.0

    /// Report per-channel peak / average levels of device sources through
    /// `EnhancedCaptureDelegate.enhancedCapture(_:didUpdateAudioLevel:for:)`.
    /// Uses AVFoundation's own channel metering on the audio data output, so it
    /// costs nothing extra. Requires `audioEnabled`. Display (ScreenCaptureKit)
    /// audio has no meters.
    public var audioLevelMeteringEnabled: Bool = false

    /// Minimum spacing between audio level callbacks, in seconds.
    public var audioLevelInterval: TimeInterval = 0.05

    /// macOS only: include system audio when capturing a display via
    /// ScreenCaptureKit. The current process is always excluded. Governed by
    /// Screen Recording permission, not the microphone: it does not need
    /// `audioEnabled`. Delivered only when `deliversAudioSampleBuffers` is on.
    public var screenAudioEnabled: Bool = false

    /// iOS / tvOS: ownership of `AVAudioSession` while capturing.
    public var audioSessionPolicy: EnhancedCaptureAudioSessionPolicy = .automatic

    // MARK: Video

    /// Pixel format requested from video data outputs. See ``EnhancedCapturePixelFormat``.
    public var pixelFormat: EnhancedCapturePixelFormat = .bgra

    /// Format preference applied to every video device. `nil` keeps each
    /// device's default format and the `.high` session preset.
    public var videoPreference: EnhancedCaptureVideoPreference? = nil

    /// Frames per second requested from ScreenCaptureKit display capture (macOS).
    public var screenFrameRate: Int32 = 30

    /// Draw the cursor into display captures (macOS).
    public var screenShowsCursor: Bool = true

    // MARK: iOS / iPadOS session behaviour

    /// Keep the camera running in Split View, Slide Over and Stage Manager.
    /// Applied only when `AVCaptureSession.isMultitaskingCameraAccessSupported`
    /// is true, which needs the
    /// `com.apple.developer.avfoundation.multitasking-camera-access`
    /// entitlement or the `voip` background mode.
    public var multitaskingCameraAccessEnabled: Bool = true

    /// Rotation applied to built-in camera frames on iOS. `.none` delivers
    /// sensor-oriented buffers (the pre-configuration behaviour); the compositor
    /// rotates for free.
    public var cameraRotationMode: EnhancedCaptureRotationMode = .none

    /// Restart the session automatically after `AVError.mediaServicesWereReset`.
    public var restartsAfterMediaServicesReset: Bool = true

    public init() {}

    /// Everything off except video and the macOS speaker preview — identical to
    /// the kit's behaviour before this type existed, apart from the additions
    /// recorded under "Behaviour changes" in `Docs/EnhancedCaptureKit-GapAnalysis.md`.
    public static let `default` = EnhancedCaptureConfiguration()

    /// Audio on with sample-buffer delivery and level metering; macOS audio
    /// preview off (the consumer routes audio itself).
    public static var audioVideo: EnhancedCaptureConfiguration {
        var config = EnhancedCaptureConfiguration()
        config.audioEnabled = true
        config.audioPreviewEnabled = false
        config.audioLevelMeteringEnabled = true
        return config
    }
}
