# EnhancedCaptureKit vs swift-capture-kit — gap analysis

*2026-09-01. Compared `EnhancedCaptureKit` (this package, ~2.2K lines) against
[atelier-socle/swift-capture-kit](https://github.com/atelier-socle/swift-capture-kit) 0.1.1
(~44K lines incl. tests, Apache 2.0). Target: an iPad Pro app that composites
live capture through the Metal pipeline in this package.*

## Verdict

swift-capture-kit is a broad, well-documented **streaming** library: every audio and
video source, every Apple codec, file output, a transport-agnostic streaming pipeline,
platform bitrate presets. Its data plane is the wrong shape for us: every source copies
each frame out of its `CVPixelBuffer` into a heap `Data` and discards the IOSurface —
the thing `TextureConverter` needs for zero-copy `CVMetalTextureCache` uploads — and
every consumer copies it back. Nothing from its frame path is adoptable.

What *was* worth taking is the list of capabilities it covers that we did not, plus a
few self-contained ideas. Those are now implemented in our own code (no source was
copied, so the Apache 2.0 NOTICE obligation is not triggered).

## Capability comparison

| Capability | EnhancedCaptureKit (before) | swift-capture-kit | EnhancedCaptureKit (now) |
|---|---|---|---|
| Frame delivery | `CMSampleBuffer`, IOSurface-backed, zero-copy to Metal | `Data` copy per frame, IOSurface lost | unchanged (kept) |
| Cameras (iOS) | front/back wide via `DiscoverySession` | wide/ultra-wide/tele/TrueDepth, zoom, torch, focus, photo | + zoom, torch, focus/exposure point, Center Stage |
| External UVC / HDMI capture (macOS, iPadOS 17) | yes | yes (`ExternalCameraSource`) | unchanged |
| iOS device over USB (macOS, CoreMediaIO) | yes | no | unchanged |
| Display capture (macOS, ScreenCaptureKit) | yes, 30 fps, cursor on, all frames forwarded | display/window/app/region | + configurable fps & cursor, only `.complete` frames forwarded, **system audio** |
| **Microphone capture (iOS/macOS)** | **none** | `AVAudioEngine` tap → interleaved Float32 `Data` | **`AVCaptureAudioDataOutput` on the shared session → `CMSampleBuffer`**, mic sources discovered as `.microphone` |
| **Muxed device audio (HDMI card embedded audio)** | macOS: speaker preview only; iOS: nothing | not modelled (audio and video are separate sources) | **sample buffers on both platforms** + macOS speaker preview (kept on by default, independent of `audioEnabled`) |
| System audio (macOS) | none | `SystemAudioSource` (SCStream) | on the screen source when `screenAudioEnabled` (needs no microphone permission) |
| Audio levels | none | scalar peak/RMS; EBU R128 fields are placeholders (RMS − 0.691) | AVFoundation `AVCaptureAudioChannel` peak/average per channel, throttled |
| `AVAudioSession` handling (iOS) | none | sets `.playAndRecord/.measurement` unconditionally | policy: automatic / applicationManaged / detached; preferred-input helpers |
| Format / frame-rate selection | picked widest format, then `.high` preset overrode it on iOS | first format matching fps (no resolution match) | `EnhancedCaptureVideoPreference` → scored selection, `.inputPriority` on iOS/tvOS, re-applied after input joins |
| Pixel format | BGRA hard-coded | NV12/BGRA/P010/… | BGRA default; 420v/420f end to end — `YCbCrTextureConverter` converts on the GPU in `TextureConverter` and the compositor (2.0.0) |
| Session interruptions (iOS) | none (`.interrupted` state existed but was never set) | none | `wasInterrupted` / `interruptionEnded` → delegate + per-source state |
| Runtime errors / media-services reset | none | none | reported; auto-restart on `AVErrorMediaServicesWereReset` |
| iPad multitasking camera access (Split View, Stage Manager) | none | none | enabled when entitled (`isMultitaskingCameraAccessSupported`) |
| Camera rotation (iOS 17 `RotationCoordinator`) | none — portrait iPad shows the camera sideways | none | `.none` (default; connection pinned to 0°, compositor rotates) or `.horizonLevelCapture` (gravity-level, physically rotated buffers); angle reported at discovery and on change |
| Error surface | log lines only; `EnhancedCaptureError` never thrown | `CaptureError` enum, thrown | `didEncounterError` delegate + `sourceStateDidChange` |
| Permissions | camera at init, screen recording (result discarded) | actor with cache, mic/camera/screen | + microphone (only when audio enabled), screen result reported truthfully |
| Multi-camera | no | `AVCaptureMultiCamSession` (no hardware-cost guard) | `multiCameraEnabled` → `AVCaptureMultiCamSession` with multi-cam-only formats, hardware/system-pressure budget check, system pressure reporting (2.0.0) |
| Encoders, file output, streaming, presets, adaptive quality | no | yes | no — out of scope for a texture pipeline |
| Test pattern / colour / black sources | no | yes (`Data`-based, drifting timer) | `.testPattern` source: pool-backed BGRA or 420v/420f, strict timer, host-clock PTS, frame counter; runs on the Simulator (2.0.0) |
| Concurrency model | delegate + `AVCaptureSession` subclass, main-actor discovery, lock-guarded hot path | actors + `AsyncStream` (unbounded buffering everywhere) | delegate kept; `EnhancedCaptureStreams` façade adds `AsyncStream`s with newest-frame buffering; kit now *owns* its session (2.0.0) |
| Platforms | macOS 15 / iOS 16 (17 at runtime) / tvOS 18 | macOS 14 / iOS 17 / visionOS 1 | unchanged |

## What changed in EnhancedCaptureKit

### New public API

- `EnhancedCaptureConfiguration` and `init(delegate:configuration:)`. `init(delegate:)`
  uses `.default`, which reproduces the previous behaviour — audio off, BGRA, no format
  preference, sensor-oriented camera buffers, macOS speaker preview on — apart from
  the additions listed under "Behaviour changes" below.
- `EnhancedCaptureSourceType.microphone`; `EnhancedCaptureSource.media` / `hasAudio` /
  `hasVideo`. A muxed HDMI card is `[.video, .audio]`.
- Delegate methods, all with default no-op implementations:
  `enhancedCaptureDidOutputAudioSampleBuffer(sampleBuffer:source:)`,
  `enhancedCapture(_:didUpdateAudioLevel:for:)`,
  `enhancedCapture(_:sourceStateDidChange:for:)`,
  `enhancedCapture(_:sessionInterruptionDidChange:)`,
  `enhancedCapture(_:didEncounterError:for:)`,
  `enhancedCapture(_:videoRotationAngleDidChange:for:)`.
- `EnhancedCaptureVideoPreference` (`.hd1080p30`, `.hd1080p60`, `.uhd4K30`),
  `EnhancedCapturePixelFormat`, `EnhancedCaptureAudioSessionPolicy`,
  `EnhancedCaptureRotationMode`, `EnhancedCaptureInterruptionReason`,
  `EnhancedCaptureSessionInterruption`, `EnhancedCaptureAudioLevel`.
- Controls: `setZoomFactor(_:for:)` (iOS/tvOS), `setTorchMode(_:for:)`,
  `setFocusAndExposurePoint(_:for:)`, `EnhancedCaptureKit.setCenterStageEnabled(_:)`,
  `restartSession()`, `state(for:)`; iOS/tvOS `availableAudioInputs()` /
  `setPreferredAudioInput(_:)`.

### Source-compatible but worth knowing

- New enum cases: `EnhancedCaptureSourceType.microphone`, `PermissionType.microphone`,
  `EnhancedCaptureError.deviceConfigurationFailed` / `.sessionRuntimeError`. Exhaustive
  `switch` statements in consumers need the new cases.
- `EnhancedCaptureError` is now `CustomStringConvertible`; `PermissionStatus` is `Equatable`.

### Behaviour changes

- **macOS default format**: previously "first widest format", now "largest area, then
  non-binned, then highest frame rate, then device order". Usually the same format;
  a device listing several equal-size formats (e.g. uncompressed@5 fps and MJPEG@30 fps)
  now gets the faster one. Set `configuration.videoPreference` for anything else.
- **Camera rotation (iOS 17+)**: `cameraRotationMode` defaults to `.none`, which now
  pins the video connection to 0° — Spring-2024 and later iPads otherwise default the
  front camera's data output to 180°. The `.horizonLevelCapture` mode physically
  rotates buffers (AVFoundation re-configures the pipeline on each orientation
  change). There is no "horizon-level preview" mode: `AVCaptureDevice.RotationCoordinator`
  only computes that angle for a `CALayer` in a view hierarchy, which the kit does not
  own; rotate in the compositor instead.
- **Audio preview (macOS)** stays on by default and is independent of `audioEnabled`
  and of microphone permission, as before — but it now applies only to devices with
  video (muxed capture cards). A microphone source never gets a speaker preview.
- **Audio permission timing**: a source enabled while the microphone prompt is still
  pending is not refused; its audio (or, for a microphone source, the whole source)
  is attached when the permission resolves. Microphone status is read live at enable
  time, not cached from the init-time check. If the camera is denied but the
  microphone granted, the session is started for audio anyway.
- **Multitasking camera access (iPad)** is enabled by default when the app is entitled
  (`multitaskingCameraAccessEnabled`); previously the kit never touched it.
- **Media-services reset** now restarts the session automatically
  (`restartsAfterMediaServicesReset`); previously there was no runtime-error observer.
- **Format preference on iOS / tvOS** is applied once, inside the session's
  configuration block after the input joins (`.inputPriority`), not at discovery.
- **Frame-rate lock** keeps fractional rates (29.97 / 59.94) and clamps into the
  format's reported range; rounding to an integer timescale produced a duration
  AVFoundation rejects with an uncatchable exception.
- **iOS format**: previously the widest format was set and then silently discarded when
  the `.high` preset took over. Now the format is untouched unless a preference is set,
  in which case `.inputPriority` is used and the preference is re-applied after the input
  joins the session (AVFoundation resets it at that moment on iOS).
- **Display capture** forwards only `SCFrameStatus.complete` frames. Idle/blank/suspended
  frames carry no new pixels and used to trigger a GPU upload each.
- **Display capture follows its display's size** (2.2.2). A stream's output size was set
  once, at its start, and the screen scan only noticed displays added or removed, so a
  display switched to a mode of another shape (a 16:10 laptop set to 16:9) kept arriving
  in the old shape, the new desktop letterboxed inside each frame — and a compositor laying
  out by the frame's size never re-fitted it. The scan now re-configures a running stream
  to its display's new size (`EnhancedCaptureScreen.displayDidChange(to:)`, restarting it
  if ScreenCaptureKit refuses), and a display change that lands mid-scan runs one more
  pass instead of being dropped (`ScreenScanGate`). `EnhancedCaptureScreenTests` resizes a
  live stream of the main display when Screen Recording is already granted.
- **Screen-recording permission** reports the real `CGRequestScreenCaptureAccess()`
  result instead of always `.denied`.
- **Audio-only devices** are discovered as `.microphone` sources only when
  `audioEnabled` is on; with it off nothing about discovery changes.
- The `kCVPixelBufferMetalCompatibilityKey` entry in `videoSettings` is macOS-only now.
  iOS rejects unknown keys in `AVCaptureVideoDataOutput.videoSettings`, and its buffers
  are IOSurface-backed regardless.
- Queue labels are `com.xocialize.MetalToolBox.*` (were `com.mvs.*` / `com.capturekit.*`).

### Dead code and defects removed

- `EnhancedCaptureCameraController` (iOS) was never instantiated; it duplicated camera
  discovery the main kit already does and would have opened the camera a second time. Deleted.
- `shouldAddCaptureDevice(_:)` (a hard-coded vendor allowlist) was never called. Deleted.
- `dataAudioOutput` was created for every device and never connected. It is now the
  audio delivery path.
- `EnhancedCaptureVideoSpec` / `updateFormat(with:)` were internal and unused; replaced
  by the tested `EnhancedCaptureFormatSelector`.
- `previewLayer.frame` was mutated on whatever thread posted the format-change
  notification; it now hops to main.
- Device dedup by display name collapsed a capture card's separate audio endpoint into
  its video endpoint; the check is now per media kind.
- `AVCaptureDevice` captured in `@Sendable` notification closures produced Swift 6
  warnings; wrapped in `UncheckedSendable`.

## Deliberately not adopted

- **`Data`-based `VideoFrame` / `AudioBuffer`, `CaptureOutput`, `TeeOutput`,
  `PreviewOutput`** — two memcpys per frame and the IOSurface is gone. Our
  `CMSampleBuffer` delivery is the point of this library.
- **Encoders, `FileOutput`/`AVAssetWriterEngine`, `StreamingPipeline`, presets, adaptive
  quality** — no requirement, and `AVAssetWriterEngine` starts its session at `.zero`
  while stamping host-clock PTS, so it is not a safe starting point even if recording is
  wanted later.
- **`AudioMeter`** — its EBU R128 values are placeholders. AVFoundation's channel meters
  cost nothing and are correct; if true loudness is ever needed, that is a vDSP
  K-weighting job, not a port.
- **Hand-rolled `AudioFormat` / `VideoFormat` / `ColorSpace` types** — parallel to
  `AVAudioFormat` / `CMFormatDescription` and must be converted at every boundary. Consumers
  read the sample buffer's format description directly.
- **Actor + `AsyncStream` architecture** — a rewrite, not an upgrade, and their streams
  use unbounded buffering (a stalled consumer at 60 fps grows without limit). If an async
  façade is wanted for SwiftUI, it should sit on top of the delegate with
  `.bufferingNewest(1)`.

## iPad Pro checklist

1. **Info.plist**: `NSCameraUsageDescription`; `NSMicrophoneUsageDescription` when
   `audioEnabled` (the kit requests microphone access during init in that case).
2. **Entitlement** `com.apple.developer.avfoundation.multitasking-camera-access`
   (or the `voip` background mode) to keep capturing in Split View / Stage Manager;
   otherwise expect `.videoDeviceNotAvailableWithMultipleForegroundApps` interruptions.
3. **Audio session**: `.automatic` if the app does not play audio; `.applicationManaged`
   if it does (configure `AVAudioSession` yourself, e.g. `.playAndRecord` with
   `.defaultToSpeaker` / Bluetooth options).
4. **External USB-C devices**: UVC cameras/capture cards appear as `.externalDevice`;
   USB audio interfaces do not appear as separate sources on iPadOS — route the single
   `.microphone` source with `setPreferredAudioInput(_:)`.
5. **Rotation**: `.none` (default) delivers sensor-oriented buffers with the connection
   pinned to 0°; rotate in the compositor using the angle from
   `videoRotationAngleDidChange` or the interface orientation. `.horizonLevelCapture`
   is for frames that leave the device (gravity-level, physically rotated).
6. **Format**: set `videoPreference = .hd1080p30` (or `.hd1080p60`) — without it the
   `.high` preset decides, and with the old code the widest (photo) format would have been
   requested.
7. **Thermals**: `.videoDeviceNotAvailableDueToSystemPressure` arrives as an
   interruption; a lower preference or frame rate is the remedy.

## Verification

- `swift build` and `swift test` on macOS: new tests pass (format selector, types,
  configuration defaults). One pre-existing failure in `MetalViewTests` is unrelated (the
  last commit made `maintainAspectRatio` opt-in; the test still asserts the old default).
- `xcodebuild -scheme EnhancedCaptureKit` for `generic/platform=iOS` and `tvOS`: succeed.
- Not exercised on hardware in this pass: microphone delivery, HDMI-card audio, iPad
  rotation and interruption paths. These are the first things to try on the iPad Pro.

## 2.0.0 — follow-ups delivered

The follow-ups listed by the 1.3.x analysis were implemented in priority order.

1. **Multi-camera.** `configuration.multiCameraEnabled` runs an `AVCaptureMultiCamSession`
   on capable iPads / iPhones so front and back cameras can be enabled together. Formats
   are restricted to `isMultiCamSupported` (the configured preference or 1080p30); after
   each camera is added the session's `hardwareCost` / `systemPressureCost` are checked
   and the camera is removed again with `.multiCameraHardwareCostExceeded` if over budget.
   Cameras' `systemPressureState` is reported as `.systemPressureElevated`.
   **Breaking:** to allow the session class to vary, `EnhancedCaptureKit` no longer
   subclasses `AVCaptureSession`; it owns one at `kit.session` (`isRunning` is forwarded).
2. **NV12 in the Metal pipeline.** `YCbCrTextureConverter` (ShaderKit) turns 420v / 420f
   frames into BGRA with one compute dispatch (BT.709 / 601 / 2020 from the buffer's
   attachment, video or full range), wrapping both planes zero-copy and writing into a
   three-deep ring of output textures. `TextureConverter` and
   `TextureCompositorEngine.processIncomingPixelBuffer` use it automatically, so
   `configuration.pixelFormat = .yCbCr420VideoRange` halves capture bandwidth end to end.
3. **Synthetic test source.** `configuration.testPatternEnabled` adds a `.testPattern`
   source: colour bars / grey ramp / checkerboard / solid colour rendered into a
   Metal-compatible `CVPixelBufferPool` on a strict timer, stamped from the host clock, in
   BGRA or YCbCr. A moving bar and a 16-square binary frame counter make drops and
   latency visible. Works on the iOS Simulator, which has no camera.
4. **Async façade.** `EnhancedCaptureStreams` owns a kit and exposes `sources`, `events`,
   `audioLevels`, `videoFrames(for:)`, `audioBuffers(for:)` and `depthFrames(for:)` as
   `AsyncStream`s. Video and depth keep only the newest frame per subscription; audio and
   events keep bounded windows. Frames remain `CMSampleBuffer`s.
5. **Depth / LiDAR.** `configuration.depthDataEnabled` attaches an
   `AVCaptureDepthDataOutput` to cameras with a depth sensor, prefers depth-capable video
   formats, picks the largest float16 depth format, and delivers `AVDepthData` through
   `enhancedCaptureDidOutputDepthData(depthData:timestamp:source:)`; such sources carry
   `.depth` in `media`.

Not done: **ReplayKit** in-app screen capture on iOS (an app compositing live sources has
little use for recording its own screen; add if a need appears) and a **privacy manifest**
(no required-reason APIs are used).

All of the above is compile-checked on macOS, iOS and tvOS and unit-tested where hardware
is not needed (format selection, pattern rendering, GPU YCbCr conversion, stream fan-out).
Multi-camera, depth and real-camera YCbCr paths still await a run on the iPad Pro.
