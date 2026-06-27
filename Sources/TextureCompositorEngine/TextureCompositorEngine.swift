//
//  TextureCompositorEngine.swift
//  ZoneKit
//
//  Created by Dustin Nielson on 2/27/26.
//
//  High-performance Metal-based compositor that uses ZoneLayoutGenerator for layout calculation
//  and produces single-texture output from multiple zone inputs.
//
//  The engine manages the complete compositing pipeline:
//  1. Zone registration via configureZones()
//  2. Layout calculation via internal ZoneLayoutGenerator instance
//  3. Per-zone texture updates via setZoneTexture() or processIncomingPixelBuffer()
//  4. Multi-zone compositing via render() → outputTexture
//

import Foundation
import MetalKit
import MetalPerformanceShaders
import CoreVideo
import ShaderKit
import ZoneLayoutGenerator
import OSLog
import LoggingKit

#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif



public class TextureCompositorEngine {

    // MARK: - Layout Engine

    var zlg: ZLG?
    var layoutConfig: ZoneLayoutConfiguration?
    var layoutIdentifier: Int64?

    // MARK: - Metal Resources

    var device: MTLDevice?
    var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var fullScreenPipelineState: MTLRenderPipelineState?
    private var scaleFilter: MPSImageScale?

    /// Lock for thread-safe texture access (pixel buffers can come from background queues)
    private let textureLock = NSLock()

    // MARK: - Zone State

    var textureQueue: [TextureQueueItem] = []

    /// The composited output texture. Consumers read this after each render() call.
    public private(set) var outputTexture: MTLTexture?

    /// Hold-frame: last successfully composited output, delivered when no zones have content.
    private var lastValidOutputTexture: MTLTexture?

    /// Zones whose actual input texture size differs from the configured ZoneConfiguration.size.
    /// Accumulated per-zone in setZoneTexture/processIncomingPixelBuffer; flushed when
    /// layout recalculation is triggered at the top of render().
    private var pendingInputSizeChanges: [String: CGSize] = [:]

    /// When true, a layout recalculation has been requested but not yet received.
    /// Render will use hold-frame until the new layout arrives.
    /// (Currently ZLG is synchronous so this is set and cleared in the same call stack,
    /// but provides infrastructure for future async layout calculation.)
    private var layoutPending: Bool = false

    /// Last-printed MPS debug snapshot per zone index.
    /// Suppresses duplicate output in the 60fps render loop.
    private var lastRenderDebugSnapshots: [Int: FZCEDebugSnapshot] = [:]

    /// Injected shader library — used instead of Bundle.module when provided.
    private var shaderLibrary: EnhancedShaderLibrary?

    // MARK: - Initialization

    public init?(device: MTLDevice?, shaderLibrary: MTLLibrary? = nil, commandQueue: MTLCommandQueue? = nil) {
        if device != nil {
            self.device = device
        } else {
            self.device = MTLCreateSystemDefaultDevice()
        }
        if let lib = shaderLibrary {
            self.shaderLibrary = EnhancedShaderLibrary(library: lib)
        }
        if commandQueue != nil {
            self.commandQueue = commandQueue
        } else {
            guard let device = self.device else { return nil }
            self.commandQueue = device.makeCommandQueue()
        }
        zlg = ZLG(delegate: self)
        guard let device = self.device, let _ = self.commandQueue, let _ = zlg else {
            return nil
        }

        // Create CVMetalTextureCache for efficient pixel buffer conversion
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let textureCache = cache else {
            return nil
        }
        self.textureCache = textureCache

        // Initialize MPS scale filter.
        // Lanczos provides higher quality (multi-tap) but internally allocates RGBA16Float
        // temporaries (~66 MB each at 2160×3840). On low-RAM devices like iPhone 8 (2 GB)
        // this causes an OOM crash. Use Bilinear on devices with < 3 GB RAM; all others
        // (including Apple TV 4K and modern iPhones) get Lanczos.
        #if os(macOS)
        self.scaleFilter = MPSImageLanczosScale(device: device)
        #else
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let threeGB: UInt64 = 3 * 1024 * 1024 * 1024
        if physicalMemory >= threeGB {
            self.scaleFilter = MPSImageLanczosScale(device: device)
        } else {
            self.scaleFilter = MPSImageBilinearScale(device: device)
        }
        mlog.info("MPS scale filter: \(physicalMemory >= threeGB ? "Lanczos" : "Bilinear") (RAM: \(physicalMemory / (1024*1024)) MB)")
        #endif

        initPipeLineState()
        initLayoutConfig()
    }

    // MARK: - Layout Configuration

    public func initLayoutConfig() {

        layoutIdentifier = Int64(Date().timeIntervalSince1970)
        guard let layoutIdentifier else { return }

        layoutConfig = ZoneLayoutConfiguration(
            name: "CompositorEngine",
            identifier: layoutIdentifier,
            renderCanvasSize: CGSize(width: 3840, height: 2160),
            canvasOrigin: .topLeft,
            zoneConfigurations: []
        )

        createOutputTexture()
    }

    /// Trigger layout recalculation from current zone configurations.
    /// Builds zone configs from the textureQueue and runs ZLG.
    public func updateLayoutConfig() {
        guard var config = layoutConfig, let zlg else { return }

        var zoneConfigurations: [ZoneConfiguration] = []
        for textureItem in textureQueue {
            zoneConfigurations.append(textureItem.config)
        }

        config.zoneConfigurations = zoneConfigurations
        layoutConfig = config

        // Trigger ZLG layout calculation — results arrive via delegate
        zlg.calculateLayoutFromConfig(config: config)
    }

    // MARK: - Input Size Recalculation

    /// Recalculate layout using actual input sizes for zones that changed.
    /// Updates ZoneConfiguration.size to match the real source texture dimensions
    /// while preserving the zone's ZoneConfigOptions (identifier, zIndex, orientation,
    /// renderSafeAspectRatio, constraints). Then triggers ZLG recalculation.
    private func requestLayoutRecalculation() {
        layoutPending = true

        textureLock.lock()
        let changes = pendingInputSizeChanges
        pendingInputSizeChanges.removeAll()

        // Update each changed zone's config with the actual input size.
        // ZoneConfigOptions is preserved — only the size (input dimensions) changes.
        for (identifier, newSize) in changes {
            if let item = textureQueue.first(where: {
                $0.config.zoneBaseConfig.identifier == identifier
            }) {
                item.config = ZoneConfiguration(
                    zoneBaseConfig: item.config.zoneBaseConfig,
                    size: newSize
                )
            }
        }
        textureLock.unlock()

        // Trigger ZLG recalculation with updated configs — results arrive via delegate
        updateLayoutConfig()
    }

    // MARK: - Canvas Management

    /// Update the render canvas size. Reallocates output and composite textures,
    /// then triggers layout recalculation for the new canvas dimensions.
    public func updateCanvasSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard layoutConfig?.renderCanvasSize != size else { return }

        layoutConfig?.renderCanvasSize = size
        createOutputTexture()
        allocateCompositeTextures()

        // Trigger layout recalculation with the new canvas size
        updateLayoutConfig()
    }

    private func createOutputTexture() {
        guard let device, let layoutConfig else { return }
        let width = Int(layoutConfig.renderCanvasSize.width)
        let height = Int(layoutConfig.renderCanvasSize.height)
        guard width > 0, height > 0 else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]

        outputTexture = device.makeTexture(descriptor: descriptor)

        if outputTexture == nil {
            mlog.error("Failed to create output texture")
        }
    }

    // MARK: - Zone Registration

    /// Register zone configurations. Call before layout calculation.
    /// Preserves existing textures for zones that already exist.
    /// Allocates canvas-sized compositeTextures for MPS scaling.
    public func configureZones(_ configurations: [ZoneConfiguration]) {
        textureLock.lock()
        defer { textureLock.unlock() }

        textureQueue = configurations.map { config in
            // Preserve existing texture if zone already exists
            let existing = textureQueue.first(where: {
                $0.config.zoneBaseConfig.identifier == config.zoneBaseConfig.identifier
            })
            let item = TextureQueueItem(texture: existing?.texture, config: config)
            // Preserve existing compositeTexture or it will be allocated after layout
            item.compositeTexture = existing?.compositeTexture
            return item
        }

        lastRenderDebugSnapshots.removeAll()

        // Allocate canvas-sized compositeTextures
        allocateCompositeTextures()
    }

    // MARK: - Zone Input

    /// Set an already-converted MTLTexture for a named zone.
    /// CPU-only: stores the texture and detects input size changes for layout recalculation.
    public func setZoneTexture(_ texture: MTLTexture, forZone identifier: String) {
        textureLock.lock()
        defer { textureLock.unlock() }

        guard let item = textureQueue.first(where: {
            $0.config.zoneBaseConfig.identifier == identifier
        }) else { return }

        // Detect input size change — if the actual source dimensions differ from
        // what ZLG last computed layout for, flag for recalculation.
        let newSize = CGSize(width: CGFloat(texture.width), height: CGFloat(texture.height))
        if item.lastInputSize != newSize {
            pendingInputSizeChanges[identifier] = newSize
        }

        // Lazily allocate composite texture when zone first receives content
        if item.compositeTexture == nil, let layoutConfig {
            let cw = Int(layoutConfig.renderCanvasSize.width)
            let ch = Int(layoutConfig.renderCanvasSize.height)
            if cw > 0, ch > 0 {
                item.compositeTexture = blankTexture(width: cw, height: ch)
            }
        }

        item.texture = texture
        item.lastInputSize = newSize
    }

    /// Clear the source texture for a named zone.
    /// Call this when the app clears a zone's content so FZCE stops compositing stale frames.
    /// The next render pass will detect nil source and clear the compositeTexture.
    public func clearZoneTexture(forZone identifier: String) {
        textureLock.lock()
        defer { textureLock.unlock() }

        guard let item = textureQueue.first(where: {
            $0.config.zoneBaseConfig.identifier == identifier
        }) else { return }

        item.texture = nil
        item.compositeTexture = nil  // Release composite — will be lazily re-allocated on next content
    }

    /// Flush stale entries from the engine's internal CVMetalTextureCache.
    /// Call periodically (e.g., once per frame) to release CVMetalTexture wrappers
    /// from prior frames whose backing CVPixelBuffer has been deallocated.
    public func flushTextureCache() {
        guard let textureCache else { return }
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Accept a CVPixelBuffer for a named zone. Converts to MTLTexture synchronously
    /// using the engine's CVMetalTextureCache (zero-copy when possible).
    public func processIncomingPixelBuffer(pixelBuffer: CVPixelBuffer, destinationZone: String) {
        guard let textureCache else {
            mlog.error("No texture cache available")
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let mtlFormat: MTLPixelFormat
        switch format {
        case kCVPixelFormatType_32BGRA:
            mtlFormat = .bgra8Unorm
        case kCVPixelFormatType_32RGBA:
            mtlFormat = .rgba8Unorm
        default:
            mtlFormat = .bgra8Unorm
        }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            mtlFormat,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess,
              let cvTex = cvTexture,
              let mtlTexture = CVMetalTextureGetTexture(cvTex) else {
            mlog.error("Failed to convert pixel buffer for zone: \(destinationZone)")
            return
        }

        textureLock.lock()
        defer { textureLock.unlock() }

        guard let item = textureQueue.first(where: {
            $0.config.zoneBaseConfig.identifier == destinationZone
        }) else { return }

        // Detect input size change — same logic as setZoneTexture
        let newSize = CGSize(width: CGFloat(mtlTexture.width), height: CGFloat(mtlTexture.height))
        if item.lastInputSize != newSize {
            pendingInputSizeChanges[destinationZone] = newSize
        }

        item.texture = mtlTexture
        item.lastInputSize = newSize
    }

    // MARK: - Pipeline State

    func initPipeLineState() {
        guard let device else { return }

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

        let pixelFormat = MTLPixelFormat.bgra8Unorm

        guard let fragmentFunction = resolvedShaderLib.fragmentDisplay() else {
            mlog.error("Failed to load fragment function: \(EnhancedShaderFunction.fragmentDisplay)")
            return
        }

        // Full-screen pipeline for alpha compositing canvas-sized layers
        guard let fullScreenVertexFunction = resolvedShaderLib.vertexFullScreen() else {
            mlog.error("Failed to load vertex function: \(EnhancedShaderFunction.vertexFullScreen)")
            return
        }

        let fullScreenDescriptor = MTLRenderPipelineDescriptor()
        fullScreenDescriptor.label = "FZC Full-Screen Composite Pipeline"
        fullScreenDescriptor.vertexFunction = fullScreenVertexFunction
        fullScreenDescriptor.fragmentFunction = fragmentFunction
        fullScreenDescriptor.colorAttachments[0].pixelFormat = pixelFormat

        // Alpha blending: standard source-over for transparency
        fullScreenDescriptor.colorAttachments[0].isBlendingEnabled = true
        fullScreenDescriptor.colorAttachments[0].rgbBlendOperation = .add
        fullScreenDescriptor.colorAttachments[0].alphaBlendOperation = .add
        fullScreenDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        fullScreenDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        fullScreenDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        fullScreenDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            fullScreenPipelineState = try device.makeRenderPipelineState(descriptor: fullScreenDescriptor)
        } catch {
            mlog.error("Failed to create full-screen pipeline state: \(error.localizedDescription)")
        }
    }

    // MARK: - Rendering

    /// Composite all zones to outputTexture. Call once per frame.
    /// Phase 1: MPS scale each zone's source texture onto its canvas-sized compositeTexture.
    /// Phase 2: Alpha-blend compositeTextures in zIndex order onto outputTexture.
    /// Single command buffer, non-blocking (no waitUntilCompleted).
    public func render() {
        // Check for pending input size changes and trigger layout recalculation.
        // This batches all per-zone size changes into a single ZLG call.
        if !pendingInputSizeChanges.isEmpty {
            requestLayoutRecalculation()
        }

        // If layout is pending (future async ZLG), hold last frame
        if layoutPending {
            if let lastValid = lastValidOutputTexture {
                self.outputTexture = lastValid
            }
            return
        }

        guard let outputTexture,
              let fullScreenPipelineState,
              let commandQueue,
              let scaleFilter else {
            return
        }

        // Snapshot zone state under lock — CPU only
        textureLock.lock()
        let sortedItems = textureQueue.sorted(by: { $0.zIndex < $1.zIndex })
        struct ZoneSnapshot {
            let sourceTexture: MTLTexture?
            let compositeTexture: MTLTexture?
            let pixelPosition: CGPoint?
            let pixelSize: CGSize?
        }
        let snapshots: [ZoneSnapshot] = sortedItems.map { item in
            ZoneSnapshot(
                sourceTexture: item.texture,
                compositeTexture: item.compositeTexture,
                pixelPosition: item.pixelPosition,
                pixelSize: item.pixelSize
            )
        }
        textureLock.unlock()

        // Check if any zone has content
        let hasContent = snapshots.contains(where: { $0.sourceTexture != nil })
        if !hasContent {
            // Hold-frame: deliver last valid output
            if let lastValid = lastValidOutputTexture {
                self.outputTexture = lastValid
            }
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // === Clear compositeTextures for zones with no source ===
        // When a zone's source texture is nil (cleared by the app), its compositeTexture
        // retains stale content from the last frame. Clear it so Phase 2 blends nothing.
        for snapshot in snapshots {
            if snapshot.sourceTexture == nil, let composite = snapshot.compositeTexture {
                clearTexture(composite, commandBuffer: commandBuffer)
            }
        }

        // === Phase 1: MPS scale each zone's source → compositeTexture ===
        for snapshot in snapshots {
            guard let source = snapshot.sourceTexture,
                  let destination = snapshot.compositeTexture,
                  let position = snapshot.pixelPosition,
                  let size = snapshot.pixelSize,
                  size.width > 0, size.height > 0 else { continue }

            // Clear compositeTexture to transparent
            clearTexture(destination, commandBuffer: commandBuffer)

            // ZLG defines the destination rectangle (pixelSize @ pixelPosition) on the canvas.
            // The actual source texture may differ from the configured zone size, so we
            // aspect-fit the real source into the ZLG destination frame. This is not
            // re-doing layout — it's bridging from actual source dimensions to the
            // ZLG-defined rectangle while preserving aspect ratio.
            let sourceW = CGFloat(source.width)
            let sourceH = CGFloat(source.height)
            let mpsScale = min(size.width / sourceW, size.height / sourceH)
            let scaledW = sourceW * mpsScale
            let scaledH = sourceH * mpsScale

            // Center within the ZLG destination frame
            let offsetX = position.x + (size.width - scaledW) / 2.0
            let offsetY = position.y + (size.height - scaledH) / 2.0

            var transform = MPSScaleTransform(
                scaleX: Double(mpsScale),
                scaleY: Double(mpsScale),
                translateX: Double(offsetX),
                translateY: Double(offsetY)
            )

            withUnsafePointer(to: &transform) { ptr in
                scaleFilter.scaleTransform = ptr
                scaleFilter.encode(
                    commandBuffer: commandBuffer,
                    sourceTexture: source,
                    destinationTexture: destination
                )
            }
        }

        scaleFilter.scaleTransform = nil

        // === Phase 2: Alpha-blend compositeTextures onto outputTexture ===
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = outputTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.pushDebugGroup("FZCE.render")
        encoder.setRenderPipelineState(fullScreenPipelineState)

        for snapshot in snapshots {
            guard let layer = snapshot.compositeTexture else { continue }
            encoder.setFragmentTexture(layer, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.popDebugGroup()
        encoder.endEncoding()

        // Store hold-frame reference before commit
        lastValidOutputTexture = outputTexture

        commandBuffer.commit()
    }

    /// Allocate canvas-sized compositeTextures for zones that have content.
    /// Zones without a source texture don't need a composite — saves ~33 MB per inactive zone.
    /// Composites are lazily allocated in setZoneTexture() when a zone first receives content.
    private func allocateCompositeTextures() {
        guard let layoutConfig else { return }
        let canvasWidth = Int(layoutConfig.renderCanvasSize.width)
        let canvasHeight = Int(layoutConfig.renderCanvasSize.height)
        guard canvasWidth > 0, canvasHeight > 0 else { return }

        for item in textureQueue {
            if item.texture != nil {
                // Zone has content — ensure composite exists at correct canvas size
                if item.compositeTexture == nil ||
                   item.compositeTexture?.width != canvasWidth ||
                   item.compositeTexture?.height != canvasHeight {
                    item.compositeTexture = blankTexture(width: canvasWidth, height: canvasHeight)
                }
            } else {
                // Zone has no content — release composite to save memory
                item.compositeTexture = nil
            }
        }
    }

    // MARK: - Texture Utilities

    /// Clears a texture to transparent black
    private func clearTexture(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        encoder.endEncoding()
    }

    /// Creates a copy of a texture for independent consumer use
    public func copyTexture(_ texture: MTLTexture) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let device, let commandQueue else { return nil }
        guard let copy = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: copy,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )

        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()  // Blocking OK here — copyTexture is a one-shot utility, not per-frame

        return copy
    }

    /// Creates a blank texture for compositing
    private func blankTexture(width: Int, height: Int) -> MTLTexture? {
        guard let device else { return nil }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            mlog.error("Failed to create blank texture")
            return nil
        }

        return texture
    }
}

// MARK: - ZoneGeneratorDelegate

extension TextureCompositorEngine: ZoneGeneratorDelegate {
    public func zoneLayoutGenerator(_ generator: ZoneLayoutGenerator, didCalculateLayout layout: ZLGZoneLayout) {
        layoutPending = false
        let canvasSize = layout.zoneLayoutConfiguration.renderCanvasSize

        for calculatedZone in layout.calculatedZones {
            // Update matching TextureQueueItem with ZLG layout data.
            // calculatedWidth/calculatedHeight are the MPS destination dimensions —
            // the actual pixel rectangle this zone occupies on the canvas.
            if let item = textureQueue.first(where: {
                $0.config.zoneBaseConfig.identifier == calculatedZone.zoneIdentifier
            }) {
                item.pixelPosition = CGPoint(x: calculatedZone.xPosition, y: calculatedZone.yPosition)
                item.pixelSize = CGSize(width: calculatedZone.calculatedWidth, height: calculatedZone.calculatedHeight)
            }
        }

        // Ensure output texture exists at the right size
        if outputTexture == nil ||
           outputTexture?.width != Int(canvasSize.width) ||
           outputTexture?.height != Int(canvasSize.height) {
            createOutputTexture()
        }

        // Allocate canvas-sized composite textures for each zone
        allocateCompositeTextures()
    }
}

// MARK: - Debug Snapshot

/// Captures MPS scale parameters for change detection in the render loop.
/// All numeric types — zero heap allocation, fast == comparison via synthesized Equatable.
private struct FZCEDebugSnapshot: Equatable {
    let sourceWidth: Int
    let sourceHeight: Int
    let destinationWidth: Int
    let destinationHeight: Int
    let frameWidth: CGFloat
    let frameHeight: CGFloat
    let frameX: CGFloat
    let frameY: CGFloat
    let scaleX: Double
    let scaleY: Double
    let translateX: Double
    let translateY: Double
    let scaledW: CGFloat
    let scaledH: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
}

// MARK: - TextureQueueItem

/// Thread-safe container for zone texture data in the compositing pipeline
public class TextureQueueItem {

    private let itemLock = NSLock()

    public var config: ZoneConfiguration

    /// Convenience: the zone's zIndex from its configuration.
    public var zIndex: Int { config.zoneBaseConfig.zIndex }

    /// Canvas-sized texture for compositing. MPS scales and positions zone content onto this.
    public var compositeTexture: MTLTexture?

    /// ZLG-calculated pixel position on canvas (topLeft origin)
    public var pixelPosition: CGPoint?

    /// ZLG-calculated MPS destination dimensions (calculatedWidth × calculatedHeight)
    public var pixelSize: CGSize?

    /// Tracks the last known input texture dimensions for this zone.
    /// Used to detect when the actual source size changes from the configured size.
    public var lastInputSize: CGSize?

    private var _texture: MTLTexture?

    /// Thread-safe computed property for texture access
    public var texture: MTLTexture? {
        get { itemLock.lock(); defer { itemLock.unlock() }; return _texture }
        set { itemLock.lock(); _texture = newValue; itemLock.unlock() }
    }

    public init(texture: MTLTexture?, config: ZoneConfiguration) {
        self._texture = texture
        self.config = config
    }
}
