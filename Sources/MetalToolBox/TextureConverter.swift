//
//  TextureConverter.swift
//  MetalToolBox
//
//  Synchronous CVPixelBuffer → MTLTexture conversion for the render loop.
//  Uses CVMetalTextureCache for zero-copy GPU texture creation.
//
//  This is a non-actor wrapper designed for synchronous render-loop callbacks —
//  it can be called directly without `await`.
//

import Foundation
import Metal
import CoreVideo


public final class TextureConverter {

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    public init(device: MTLDevice) {
        self.device = device
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        if status == kCVReturnSuccess {
            self.textureCache = cache
        } else {
            mlog.error("Failed to create texture cache, status: \(status)")
        }

    }

    /// Flush stale entries from the texture cache.
    /// Call periodically (e.g., once per frame in the render loop) to release
    /// CVMetalTexture wrappers from prior frames whose backing CVPixelBuffer
    /// has been deallocated. Active textures still in use are not affected.
    public func flush() {
        guard let textureCache else { return }
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    public func emptyTexture() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else {
            mlog.error("TextureConverter.emptyTexture: failed to create 1×1 texture")
            return nil
        }
        let zero: [UInt8] = [0, 0, 0, 0]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: zero,
            bytesPerRow: 4
        )
        return texture
    }

    /// Convert a CVPixelBuffer to an MTLTexture via zero-copy CVMetalTextureCache.
    /// - Parameter pixelBuffer: The pixel buffer to convert (BGRA or RGBA)
    /// - Returns: An MTLTexture backed by the pixel buffer, or nil on failure
    public func convert(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else {
            mlog.error("TextureConverter.convert: textureCache is nil")
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Detect pixel format and choose appropriate Metal format
        let pixelFormat: MTLPixelFormat
        let osType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch osType {
        case kCVPixelFormatType_32BGRA:
            pixelFormat = .bgra8Unorm
        case kCVPixelFormatType_32RGBA:
            pixelFormat = .rgba8Unorm
        default:
            // Default to BGRA — the common output format for capture/video sources
            pixelFormat = .bgra8Unorm
        }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture else {
            mlog.error("CVMetalTextureCacheCreateTextureFromImage failed: status=\(status), width=\(width), height=\(height), format=\(osType)")
            return nil
        }

        return CVMetalTextureGetTexture(cvTexture)
    }
}
