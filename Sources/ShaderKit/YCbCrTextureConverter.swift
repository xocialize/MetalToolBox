//
//  YCbCrTextureConverter.swift
//  MetalToolBox
//
//  Turns a camera's native biplanar 4:2:0 YCbCr frame (420v / 420f) into a
//  BGRA texture with one compute dispatch. Lets capture run in the format the
//  ISP produces for free — half the memory bandwidth of BGRA at the same
//  resolution — while the rest of the pipeline keeps consuming BGRA.
//

import Foundation
import Metal
import CoreVideo
import OSLog

private let logger = Logger(subsystem: "com.xocialize.MetalToolBox", category: "YCbCrTextureConverter")

/// Converts biplanar YCbCr `CVPixelBuffer`s to BGRA `MTLTexture`s on the GPU.
///
/// Output textures come from a small ring per frame size, so the texture
/// returned for one frame stays valid while the next two frames are being
/// converted. Hold a result longer than that and it will be overwritten.
///
/// **Ordering.** Pass the same `MTLCommandQueue` the consumer renders with and
/// the conversion is encoded ahead of the render without any waiting. Without
/// a shared queue the converter uses a private queue and blocks until the
/// conversion completes (roughly a millisecond at 1080p), which keeps the
/// result safe to read from any other queue.
public final class YCbCrTextureConverter {

    /// Matches the `FZCYCbCrConversion` struct in FZCShaders.metal.
    private struct Conversion {
        var isFullRange: UInt32
        var matrix: UInt32
    }

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let commandQueue: MTLCommandQueue
    private let waitsForCompletion: Bool

    private struct RingKey: Hashable { let width: Int; let height: Int }
    private var rings: [RingKey: [MTLTexture]] = [:]
    private var ringCursor: [RingKey: Int] = [:]
    private let ringDepth = 3
    private let lock = NSLock()

    /// - Parameters:
    ///   - device: The Metal device.
    ///   - shaderLibrary: Library containing `fzc_ycbcrBiPlanarToBGRA`.
    ///   - commandQueue: The consumer's render queue, or `nil` to use a private
    ///     queue and wait for each conversion.
    public init?(device: MTLDevice, shaderLibrary: EnhancedShaderLibrary, commandQueue: MTLCommandQueue? = nil) {
        guard let function = shaderLibrary.computeYCbCrToBGRA() else {
            logger.error("Shader library has no \(EnhancedShaderFunction.computeYCbCrToBGRA)")
            return nil
        }
        do {
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            logger.error("Failed to build YCbCr pipeline: \(error.localizedDescription)")
            return nil
        }
        if let commandQueue {
            self.commandQueue = commandQueue
            self.waitsForCompletion = false
        } else {
            guard let queue = device.makeCommandQueue() else { return nil }
            queue.label = "com.xocialize.MetalToolBox.YCbCrTextureConverter"
            self.commandQueue = queue
            self.waitsForCompletion = true
        }
        self.device = device
    }

    /// `true` for the biplanar 8-bit 4:2:0 formats this converter handles.
    public static func handles(_ pixelFormat: OSType) -> Bool {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    /// Converts `pixelBuffer` (420v or 420f) to a BGRA texture.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The source frame.
    ///   - textureCache: A `CVMetalTextureCache` on the same device, used to
    ///     wrap the two planes without copying.
    /// - Returns: A BGRA texture, or `nil` when the format is not biplanar
    ///   YCbCr or the planes could not be wrapped.
    public func convert(_ pixelBuffer: CVPixelBuffer, textureCache: CVMetalTextureCache) -> MTLTexture? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard Self.handles(format), CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let luma = planeTexture(pixelBuffer, plane: 0, format: .r8Unorm, cache: textureCache),
              let chroma = planeTexture(pixelBuffer, plane: 1, format: .rg8Unorm, cache: textureCache),
              let output = nextOutputTexture(width: width, height: height) else {
            return nil
        }

        var conversion = Conversion(
            isFullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0,
            matrix: Self.matrixIndex(for: pixelBuffer)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            logger.error("Could not create command buffer for YCbCr conversion")
            return nil
        }
        commandBuffer.label = "YCbCr→BGRA"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&conversion, length: MemoryLayout<Conversion>.stride, index: 0)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        if device.supportsFamily(.apple4) || device.supportsFamily(.mac2) {
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: threadsPerGroup)
        } else {
            let groups = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        }
        encoder.endEncoding()

        // Keep the CVMetalTexture wrappers (and so the planes) alive until the GPU is done.
        let retained: [Any] = [luma, chroma]
        commandBuffer.addCompletedHandler { _ in _ = retained }
        commandBuffer.commit()
        if waitsForCompletion {
            commandBuffer.waitUntilCompleted()
        }
        return output
    }

    // MARK: - Private

    private func planeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, format, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            logger.error("Could not wrap plane \(plane): status \(status)")
            return nil
        }
        return texture
    }

    private func nextOutputTexture(width: Int, height: Int) -> MTLTexture? {
        let key = RingKey(width: width, height: height)
        lock.lock()
        defer { lock.unlock() }

        if rings[key] == nil {
            // A new frame size: drop rings for sizes no longer arriving.
            rings.removeAll()
            ringCursor.removeAll()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .private
            var ring: [MTLTexture] = []
            for index in 0..<ringDepth {
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    logger.error("Could not allocate BGRA output \(width)x\(height)")
                    return nil
                }
                texture.label = "YCbCr→BGRA \(width)x\(height) #\(index)"
                ring.append(texture)
            }
            rings[key] = ring
            ringCursor[key] = 0
        }

        let cursor = ringCursor[key] ?? 0
        ringCursor[key] = (cursor + 1) % ringDepth
        return rings[key]?[cursor]
    }

    /// 0 = BT.709 (default for HD camera output), 1 = BT.601, 2 = BT.2020,
    /// from the buffer's `kCVImageBufferYCbCrMatrixKey` attachment.
    private static func matrixIndex(for pixelBuffer: CVPixelBuffer) -> UInt32 {
        guard let attachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) else {
            return 0
        }
        let matrix = attachment as! CFString
        if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) { return 1 }
        if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) { return 2 }
        return 0
    }
}
