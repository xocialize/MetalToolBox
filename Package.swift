// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MetalToolBox",
    platforms: [
        .macOS(.v15),
        .iOS(.v16),
        .tvOS(.v18)
    ],
    products: [
        // Display surface — EnhancedMetalView
        .library(
            name: "MetalToolBox",
            targets: ["MetalToolBox"]
        ),
        // Core layout calculation engine — Foundation + CoreGraphics only
        .library(
            name: "ZoneLayoutGenerator",
            targets: ["ZoneLayoutGenerator"]
        ),
        // Metal-based compositing engine — requires Metal + MPS
        .library(
            name: "TextureCompositorEngine",
            targets: ["TextureCompositorEngine"]
        ),
        // Video-to-texture extraction — AVFoundation-based video playback
        .library(
            name: "VideoPlayerKit",
            targets: ["VideoPlayerKit"]
        ),
        // Screen / camera / device capture stack
        .library(
            name: "EnhancedCaptureKit",
            targets: ["EnhancedCaptureKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/xocialize/LoggingKit.git", from: "1.0.0"),
    ],
    targets: [
        // MARK: - Shared support targets

        // Cross-platform type aliases (PlatformColor / PlatformView / …)
        .target(
            name: "PlatformTypes"
        ),

        // Metal shader library + canonical shader function names + compiled .metal
        .target(
            name: "ShaderKit"
        ),

        // MARK: - Display surface
        .target(
            name: "MetalToolBox",
            dependencies: ["PlatformTypes", "ShaderKit", "LoggingKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // MARK: - Core Layout Calculator
        // Foundation + CoreGraphics only — no Metal dependency.
        .target(
            name: "ZoneLayoutGenerator",
            dependencies: ["LoggingKit"]
        ),

        // MARK: - Metal Composite Engine
        // Shaders provided by ShaderKit via dependency injection.
        .target(
            name: "TextureCompositorEngine",
            dependencies: ["ZoneLayoutGenerator", "ShaderKit", "LoggingKit"]
        ),

        // MARK: - Video Player
        // AVFoundation-based video frame extraction with Metal-compatible CVPixelBuffer output.
        .target(
            name: "VideoPlayerKit",
            dependencies: ["LoggingKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // MARK: - Capture Stack
        // Screen, external-device, iOS-device, and camera capture.
        // Re-exports ZoneLayoutGenerator, TextureCompositorEngine, and VideoPlayerKit.
        .target(
            name: "EnhancedCaptureKit",
            dependencies: [
                "ZoneLayoutGenerator",
                "TextureCompositorEngine",
                "VideoPlayerKit",
                "LoggingKit",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "MetalToolBoxTests",
            dependencies: ["MetalToolBox"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
