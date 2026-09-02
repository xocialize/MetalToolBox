//
//  YCbCrConversionTests.swift
//  MetalToolBox
//
//  Round-trips synthetic 420v / 420f frames through TextureConverter and
//  checks the BGRA the GPU produced. Skips without a Metal device.
//

import XCTest
import Metal
import CoreVideo
@testable import MetalToolBox
import ShaderKit

final class YCbCrConversionTests: XCTestCase {

    private func makeBiPlanar(format: OSType, width: Int, height: Int, y: UInt8, cb: UInt8, cr: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XCTSkip("CVPixelBufferCreate failed (\(status)) — no biplanar support here")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            memset(lumaBase.advanced(by: row * lumaStride), Int32(y), width)
        }
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        for row in 0..<chromaHeight {
            let line = chromaBase.advanced(by: row * chromaStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<chromaWidth {
                line[x * 2] = cb
                line[x * 2 + 1] = cr
            }
        }
        return buffer
    }

    /// Reads one BGRA pixel back from a (possibly private) texture via a blit.
    private func pixel(at x: Int, _ y: Int, of texture: MTLTexture, device: MTLDevice) -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let shared = device.makeTexture(descriptor: descriptor)!
        let queue = device.makeCommandQueue()!
        let commandBuffer = queue.makeCommandBuffer()!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: texture, to: shared)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: 4)
        shared.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return bytes
    }

    private func requireDeviceAndLibrary() throws -> (MTLDevice, MTLLibrary) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        guard let library = EnhancedShaderLibrary(device: device)?.library else { throw XCTSkip("Shader library unavailable") }
        return (device, library)
    }

    func testHandlesOnlyBiPlanarFormats() {
        XCTAssertTrue(YCbCrTextureConverter.handles(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        XCTAssertTrue(YCbCrTextureConverter.handles(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        XCTAssertFalse(YCbCrTextureConverter.handles(kCVPixelFormatType_32BGRA))
        XCTAssertFalse(YCbCrTextureConverter.handles(kCVPixelFormatType_422YpCbCr8))
    }

    func testVideoRangeGreyConvertsToBGRA() throws {
        let (device, library) = try requireDeviceAndLibrary()
        let converter = TextureConverter(device: device, shaderLibrary: library)
        // 420v: Y 128 → (128−16)/219 = 0.5114 → 130; neutral chroma.
        let buffer = try makeBiPlanar(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 64, height: 32, y: 128, cb: 128, cr: 128)

        let texture = try XCTUnwrap(converter.convert(buffer))
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(texture.width, 64)
        XCTAssertEqual(texture.height, 32)

        let bgra = pixel(at: 10, 7, of: texture, device: device)
        for channel in 0..<3 {
            XCTAssertEqual(Int(bgra[channel]), 130, accuracy: 2, "channel \(channel)")
        }
        XCTAssertEqual(bgra[3], 255)
    }

    func testFullRangeGreyAndRedTint() throws {
        let (device, library) = try requireDeviceAndLibrary()
        let converter = TextureConverter(device: device, shaderLibrary: library)

        // 420f: Y 128 with neutral chroma is exactly mid grey.
        let grey = try makeBiPlanar(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, width: 32, height: 32, y: 128, cb: 128, cr: 128)
        let greyTexture = try XCTUnwrap(converter.convert(grey))
        let greyPixel = pixel(at: 3, 3, of: greyTexture, device: device)
        for channel in 0..<3 {
            XCTAssertEqual(Int(greyPixel[channel]), 128, accuracy: 2)
        }

        // Positive Cr pushes red above blue in every matrix; BGRA order puts red at index 2.
        let warm = try makeBiPlanar(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, width: 32, height: 32, y: 128, cb: 128, cr: 200)
        let warmTexture = try XCTUnwrap(converter.convert(warm))
        let warmPixel = pixel(at: 3, 3, of: warmTexture, device: device)
        XCTAssertGreaterThan(warmPixel[2], warmPixel[0], "red channel must exceed blue for Cr > 128 (bytes are B,G,R,A)")
        XCTAssertGreaterThan(Int(warmPixel[2]), 128 + 80)
    }

    func testOutputTexturesRotateThroughARing() throws {
        let (device, library) = try requireDeviceAndLibrary()
        let converter = TextureConverter(device: device, shaderLibrary: library)
        let buffer = try makeBiPlanar(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 16, height: 16, y: 100, cb: 128, cr: 128)

        let first = try XCTUnwrap(converter.convert(buffer))
        let second = try XCTUnwrap(converter.convert(buffer))
        let third = try XCTUnwrap(converter.convert(buffer))
        let fourth = try XCTUnwrap(converter.convert(buffer))
        XCTAssertFalse(first === second)
        XCTAssertFalse(second === third)
        XCTAssertTrue(first === fourth, "ring depth is three: the fourth conversion reuses the first texture")
    }

    func testBGRAPathIsUnchanged() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let converter = TextureConverter(device: device)
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let texture = try XCTUnwrap(converter.convert(try XCTUnwrap(buffer)))
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(texture.width, 8)
    }
}
