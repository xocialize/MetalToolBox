//
//  TextureSquare.swift
//  MetalToolBox
//
//  Normalizes an incoming texture to a square so it can be displayed in a
//  square EnhancedMetalView without distortion.
//
//  - Square input is passed straight through (no allocation, no GPU work).
//  - Landscape / portrait input is centered, at its native pixel size, inside
//    a transparent square whose side equals the source's longer edge. The
//    source pixels are blit-copied (no resampling, so no quality loss); the
//    surrounding letterbox / pillarbox padding is left transparent.
//
//  This is a non-actor wrapper designed for synchronous render-loop callbacks —
//  it can be called directly without `await`. The square destination texture is
//  cached and reused across calls while its dimensions and pixel format are
//  unchanged (see `square(_:)` for the reuse caveat).
//

import Foundation
import Metal


public final class TextureSquare {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    /// Cached square destination, reused while side length and pixel format hold.
    private var squareTexture: MTLTexture?

    /// - Parameters:
    ///   - device: The Metal device used to allocate the square texture.
    ///   - commandQueue: Queue used to encode the clear + blit. When `nil`, a
    ///     dedicated queue is created. Pass the app's shared queue to keep the
    ///     squaring ordered with the rest of the frame's GPU work.
    public init?(device: MTLDevice, commandQueue: MTLCommandQueue? = nil) {
        self.device = device
        if let commandQueue {
            self.commandQueue = commandQueue
        } else if let created = device.makeCommandQueue() {
            self.commandQueue = created
        } else {
            mlog.error("TextureSquare: failed to create command queue")
            return nil
        }
    }

    /// Return a square version of `source`.
    ///
    /// - Square input is returned unchanged.
    /// - Non-square input is centered at native size inside a transparent
    ///   square (side = `max(width, height)`) and returned.
    ///
    /// The returned non-square result is a cached texture that is reused on the
    /// next call with matching dimensions. The work is committed but **not**
    /// waited on, so callers must consume the result on the same Metal device —
    /// GPU submission order guarantees the clear + blit complete before any
    /// later-submitted read. Do not hold the result across frames if you also
    /// call `square(_:)` again, since the next call overwrites it in place.
    public func square(_ source: MTLTexture) -> MTLTexture? {
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else {
            mlog.error("TextureSquare: source has zero dimension (\(width)×\(height))")
            return nil
        }

        // Already square — pass through untouched.
        if width == height { return source }

        let side = max(width, height)
        guard let destination = destinationTexture(side: side, pixelFormat: source.pixelFormat) else {
            return nil
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            mlog.error("TextureSquare: failed to create command buffer")
            return nil
        }

        // Clear the square to transparent so the padding around the centered
        // source is empty (and any stale pixels from a prior, differently-sized
        // source are wiped).
        clear(destination, commandBuffer: commandBuffer)

        // Center the source at its native size within the square.
        let originX = (side - width) / 2
        let originY = (side - height) / 2

        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            mlog.error("TextureSquare: failed to create blit encoder")
            return nil
        }
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: originX, y: originY, z: 0)
        )
        blit.endEncoding()

        commandBuffer.commit()

        return destination
    }

    // MARK: - Texture Utilities

    /// Return the cached square texture, reallocating when the required side
    /// length or pixel format changes.
    private func destinationTexture(side: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        if let squareTexture,
           squareTexture.width == side,
           squareTexture.height == side,
           squareTexture.pixelFormat == pixelFormat {
            return squareTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: side,
            height: side,
            mipmapped: false
        )
        // `.renderTarget` is required for the transparent clear pass; `.shaderRead`
        // lets the square feed straight into EnhancedMetalView's sampler.
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            mlog.error("TextureSquare: failed to create \(side)×\(side) square texture")
            return nil
        }

        squareTexture = texture
        return texture
    }

    /// Clear a texture to transparent black via a no-draw render pass.
    private func clear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            mlog.error("TextureSquare: failed to create clear encoder")
            return
        }
        encoder.endEncoding()
    }
}
