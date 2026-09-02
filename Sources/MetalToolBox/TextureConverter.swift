//
//  TextureConverter.swift
//  MetalToolBox
//
//  Synchronous CVPixelBuffer → MTLTexture conversion for the render loop.
//  Uses CVMetalTextureCache for zero-copy GPU texture creation; biplanar
//  YCbCr (420v / 420f) frames go through one compute dispatch to BGRA.
//
//  This is a non-actor wrapper designed for synchronous render-loop callbacks —
//  it can be called directly without `await`.
//

import Foundation
import Metal
import CoreVideo
import ShaderKit


public final class TextureConverter {

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    private let shaderLibrary: MTLLibrary?
    private let commandQueue: MTLCommandQueue?
    private var ycbcrConverter: YCbCrTextureConverter?
    private var ycbcrConverterUnavailable = false
    private let ycbcrLock = NSLock()

    /// - Parameters:
    ///   - device: The Metal device.
    ///   - shaderLibrary: Library containing the MetalToolBox shaders; resolved
    ///     via `EnhancedShaderLibrary(device:)` when `nil`. Needed only for
    ///     biplanar YCbCr input.
    ///   - commandQueue: The queue the consumer renders with. When set, YCbCr
    ///     conversions are ordered ahead of the consumer's render passes
    ///     without blocking; when `nil` each conversion waits for the GPU.
    public init(device: MTLDevice, shaderLibrary: MTLLibrary? = nil, commandQueue: MTLCommandQueue? = nil) {
        self.device = device
        self.shaderLibrary = shaderLibrary
        self.commandQueue = commandQueue
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

    /// Convert a CVPixelBuffer to an MTLTexture.
    ///
    /// BGRA and RGBA buffers are wrapped zero-copy via `CVMetalTextureCache`.
    /// Biplanar YCbCr buffers (`420v` / `420f`, what cameras produce natively)
    /// are converted to BGRA on the GPU; see ``YCbCrTextureConverter`` for the
    /// lifetime of the returned texture.
    ///
    /// - Parameter pixelBuffer: The pixel buffer to convert.
    /// - Returns: A BGRA/RGBA `MTLTexture`, or nil on failure.
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
        case _ where YCbCrTextureConverter.handles(osType):
            return convertYCbCr(pixelBuffer, textureCache: textureCache)
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

    // MARK: - YCbCr

    private func convertYCbCr(_ pixelBuffer: CVPixelBuffer, textureCache: CVMetalTextureCache) -> MTLTexture? {
        guard let converter = resolveYCbCrConverter() else {
            return nil
        }
        return converter.convert(pixelBuffer, textureCache: textureCache)
    }

    /// Built on first use so BGRA-only consumers never pay for the pipeline.
    private func resolveYCbCrConverter() -> YCbCrTextureConverter? {
        ycbcrLock.lock()
        defer { ycbcrLock.unlock() }
        if let ycbcrConverter { return ycbcrConverter }
        if ycbcrConverterUnavailable { return nil }

        let library: EnhancedShaderLibrary?
        if let shaderLibrary {
            library = EnhancedShaderLibrary(library: shaderLibrary)
        } else {
            library = EnhancedShaderLibrary(device: device)
        }
        guard let library, let converter = YCbCrTextureConverter(device: device, shaderLibrary: library, commandQueue: commandQueue) else {
            mlog.error("TextureConverter: biplanar YCbCr input needs the MetalToolBox shader library — dropping frames")
            ycbcrConverterUnavailable = true
            return nil
        }
        ycbcrConverter = converter
        return converter
    }
}
