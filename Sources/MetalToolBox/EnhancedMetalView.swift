//
//  EnhancedMetalView.swift
//  MetalToolBox
//
//  Cross-platform MTKView subclass for displaying a single MTLTexture.
//  Compatible with macOS 14+, iOS 16+, iPadOS 18+, tvOS 18+
//
//  This is a pure display surface — all layout/compositing is handled upstream
//  before the final texture reaches this view.
//

import Foundation
import MetalKit
// Re-exported so `import MetalToolBox` also surfaces the cross-platform
// type aliases (PlatformColor/PlatformView) and the shader library.
@_exported import PlatformTypes
@_exported import ShaderKit

#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif


// MARK: - EnhancedMetalView

/// A high-performance, cross-platform MTKView subclass that serves as a primary
/// display surface for a composited Metal texture.
///
/// Features:
/// - Cross-platform support: macOS, iOS, iPadOS, tvOS
/// - Thread-safe texture updates
/// - Triple-buffered rendering (prevents frame drops)
/// - Aspect-fit display (maintains texture aspect ratio)
/// - Timer-driven drawing at 60 FPS
/// - Minimal API surface
@available(macOS 14.0, iOS 16.0, tvOS 18.0, *)
public class EnhancedMetalView: MTKView {

    // MARK: - Public Properties

    /// The texture to display. Thread-safe access.
    /// Set this from any thread (e.g., from compositor delegate callback).
    public var displayTexture: MTLTexture? {
        get {
            textureLock.lock()
            defer { textureLock.unlock() }
            return _displayTexture
        }
        set {
            textureLock.lock()
            _displayTexture = newValue
            textureLock.unlock()
        }
    }

    /// Background color when no texture is displayed
    public var clearBackgroundColor: PlatformColor = .clear {
        didSet {
            updateClearColor()
        }
    }

    /// Whether to maintain aspect ratio when displaying texture
    public var maintainAspectRatio: Bool = true

    /// Rotation angle in radians applied to the displayed texture.
    /// Default is `0` (no rotation). Set to `-Float.pi / 2` for -90° rotation.
    /// Rotation happens in the vertex shader — no impact on bounds, drawableSize, or FPS.
    /// The settings preview leaves this at `0`;
    ///  For the external screen this should match the render canvas with consideration taken into the portraitBottomLeft/Right
    public var displayRotation: Float = 0

    // MARK: - Private Properties

    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private let textureLock = NSLock()
    private var _displayTexture: MTLTexture?
    private var commandQueue: MTLCommandQueue?
    private var renderPipelineState: MTLRenderPipelineState?
    private var rotatedRenderPipelineState: MTLRenderPipelineState?

    /// Injected shader library — used instead of device.makeDefaultLibrary() when provided.
    private var shaderLibrary: EnhancedShaderLibrary?

    // MARK: - Initialization

    /// Creates a new EnhancedMetalView with the specified Metal device
    /// - Parameters:
    ///   - device: The Metal device to use for rendering
    ///   - shaderLibrary: Optional shader library for pipeline setup (falls back to auto-resolve)
    ///   - commandQueue: Optional shared Metal command queue (creates new one if nil)
    public init(device: MTLDevice, shaderLibrary: MTLLibrary? = nil, commandQueue: MTLCommandQueue? = nil) {
        super.init(frame: .zero, device: device)
        if let lib = shaderLibrary {
            self.shaderLibrary = EnhancedShaderLibrary(library: lib)
        }
        commonInit(commandQueue: commandQueue)
    }

    /// Creates a new EnhancedMetalView with a frame and optional Metal device
    /// - Parameters:
    ///   - frame: The frame rectangle for the view
    ///   - device: The Metal device to use (if nil, creates system default device)
    ///   - shaderLibrary: Optional shader library for pipeline setup (falls back to auto-resolve)
    ///   - commandQueue: Optional shared Metal command queue (creates new one if nil)
    public init(frame frameRect: CGRect, device: MTLDevice?, shaderLibrary: MTLLibrary? = nil, commandQueue: MTLCommandQueue? = nil) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        if let lib = shaderLibrary {
            self.shaderLibrary = EnhancedShaderLibrary(library: lib)
        }
        commonInit(commandQueue: commandQueue)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        if self.device == nil {
            self.device = MTLCreateSystemDefaultDevice()
        }
        commonInit(commandQueue: nil)
    }

    private func commonInit(commandQueue sharedQueue: MTLCommandQueue? = nil) {
        guard let device = self.device else {
            mlog.fault("No Metal device available")
            return
        }

        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = false
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 60

        configurePlatformSpecificSettings()
        updateClearColor()

        if let queue = sharedQueue {
            self.commandQueue = queue
            mlog.info("Using shared Metal command queue")
        } else {
            self.commandQueue = device.makeCommandQueue()
            mlog.info("Created new Metal command queue")
        }

        initPipelineState()
        mlog.info("Initialized successfully on \(self.platformName())")
    }

    private func configurePlatformSpecificSettings() {
        #if os(macOS)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.layer?.isOpaque = false
        self.layer?.autoresizingMask = [.layerHeightSizable, .layerWidthSizable]
        self.layer?.contentsGravity = .resizeAspect
        #elseif os(iOS)
        self.isOpaque = false
        self.contentMode = .scaleAspectFit
        #elseif os(tvOS)
        self.isOpaque = false
        self.contentMode = .scaleAspectFit
        self.clipsToBounds = true
        #endif
    }

    private func platformName() -> String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        #if targetEnvironment(macCatalyst)
        return "Mac Catalyst"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        #elseif os(tvOS)
        return "tvOS"
        #else
        return "Unknown Platform"
        #endif
    }

    // MARK: - Pipeline Setup

    private func initPipelineState() {
        guard let device = self.device else {
            mlog.fault("Failed to init pipeline — no Metal device")
            return
        }

        // Resolve shader library: use injected library, or auto-resolve via EnhancedShaderLibrary
        let resolvedShaderLib: EnhancedShaderLibrary
        if let injected = self.shaderLibrary {
            resolvedShaderLib = injected
        } else if let autoResolved = EnhancedShaderLibrary(device: device) {
            resolvedShaderLib = autoResolved
            self.shaderLibrary = autoResolved
        } else {
            mlog.error("Failed to resolve Metal shader library")
            return
        }

        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()

        renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        renderPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        renderPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        renderPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        renderPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        renderPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        renderPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        renderPipelineDescriptor.vertexFunction = resolvedShaderLib.vertexFullScreen()
        renderPipelineDescriptor.fragmentFunction = resolvedShaderLib.fragmentDisplay()

        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
            mlog.info("Pipeline state created successfully")
        } catch {
            mlog.error("Failed to create pipeline state: \(error.localizedDescription)")
        }

        // Create rotated pipeline (same fragment shader, rotated vertex shader)
        if let rotatedVertexFn = resolvedShaderLib.vertexRotated(),
           let fragmentFn = resolvedShaderLib.fragmentDisplay() {
            let rotatedDescriptor = MTLRenderPipelineDescriptor()
            rotatedDescriptor.colorAttachments[0].isBlendingEnabled = true
            rotatedDescriptor.colorAttachments[0].rgbBlendOperation = .add
            rotatedDescriptor.colorAttachments[0].alphaBlendOperation = .add
            rotatedDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            rotatedDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            rotatedDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            rotatedDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            rotatedDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            rotatedDescriptor.vertexFunction = rotatedVertexFn
            rotatedDescriptor.fragmentFunction = fragmentFn

            do {
                rotatedRenderPipelineState = try device.makeRenderPipelineState(descriptor: rotatedDescriptor)
                mlog.info("Rotated pipeline state created successfully")
            } catch {
                mlog.error("Failed to create rotated pipeline state: \(error.localizedDescription)")
            }
        } else {
            mlog.info("Rotated vertex shader not found — rotation will be unavailable")
        }
    }

    // MARK: - Private Methods

    private func updateClearColor() {
        #if os(macOS)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        if let rgbColor = clearBackgroundColor.usingColorSpace(.deviceRGB) {
            rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        }
        self.clearColor = MTLClearColor(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))

        #elseif os(iOS) || os(tvOS)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        clearBackgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.clearColor = MTLClearColor(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
        #endif
    }

    // MARK: - Public Methods

    /// Pauses rendering (useful when view is not visible)
    public func pauseRendering() {
        self.isPaused = true
    }

    /// Resumes rendering after pause
    public func resumeRendering() {
        self.isPaused = false
    }

    /// Clears the current display texture
    public func clearTexture() {
        displayTexture = nil
    }

    /// Returns layout constraints to fill the parent view
    /// - Parameter parentView: The view to constrain to
    /// - Returns: Array of constraints anchoring all four edges
    public func getConstraints(parentView: PlatformView) -> [NSLayoutConstraint] {
        return [
            self.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            self.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
            self.topAnchor.constraint(equalTo: parentView.topAnchor),
            self.bottomAnchor.constraint(equalTo: parentView.bottomAnchor)
        ]
    }
}

// MARK: - MTKViewDelegate

@available(macOS 14.0, iOS 16.0, tvOS 18.0, *)
extension EnhancedMetalView: MTKViewDelegate {

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle size changes if needed in the future
    }

    public func draw(in view: MTKView) {
        _ = inFlightSemaphore.wait(timeout: .distantFuture)

        if view.drawableSize.width == 0 || view.drawableSize.height == 0 {
            inFlightSemaphore.signal()
            return
        }

        guard let commandQueue,
              let renderPipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            inFlightSemaphore.signal()
            return
        }

        let capturedTexture = displayTexture

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        guard let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        commandEncoder.pushDebugGroup("EnhancedMetalView.draw")

        // Use rotated pipeline when displayRotation is non-zero, otherwise standard pipeline
        let rotation = displayRotation
        if rotation != 0, let rotatedPipeline = rotatedRenderPipelineState {
            commandEncoder.setRenderPipelineState(rotatedPipeline)
            var angle = rotation
            commandEncoder.setVertexBytes(&angle, length: MemoryLayout<Float>.size, index: 0)
        } else {
            commandEncoder.setRenderPipelineState(renderPipelineState)
        }

        if let texture = capturedTexture {
            commandEncoder.setFragmentTexture(texture, index: 0)
            commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        }

        commandEncoder.popDebugGroup()
        commandEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
