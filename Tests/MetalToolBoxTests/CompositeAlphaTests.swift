//
//  CompositeAlphaTests.swift
//  MetalToolBox
//
//  TextureCompositorEngine's blend state, read from its output bytes. Zone textures are straight alpha; the
//  output must be premultiplied over the transparent canvas: colour = rgb · a, alpha = a. Before the fix the
//  alpha source factor was `.sourceAlpha`, which made the output alpha a² (128 → 64, 64 → 16), so translucent
//  content displayed at a fraction of its opacity.
//

import XCTest
import Metal
@testable import TextureCompositorEngine
import ZoneLayoutGenerator

final class CompositeAlphaTests: XCTestCase {

    /// A 4×4 white texture, straight alpha, one alpha per row.
    private func probeTexture(device: MTLDevice, alphas: [UInt8]) -> MTLTexture? {
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for row in 0..<4 {
            for col in 0..<4 {
                let i = (row * 4 + col) * 4
                bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255; bytes[i + 3] = alphas[row]
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 16)
        return texture
    }

    /// The output's bytes, read after everything on `queue` has run, via a shared copy (the output is not CPU-readable).
    private func bytes(of texture: MTLTexture, queue: MTLCommandQueue) -> [UInt8]? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let copy = queue.device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        copy.getBytes(&out, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return out
    }

    func testStraightAlphaZoneCompositesToPremultipliedOutputWithItsOwnAlpha() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("No Metal device") }
        guard let engine = TextureCompositorEngine(device: device, shaderLibrary: nil, commandQueue: queue) else {
            throw XCTSkip("TextureCompositorEngine unavailable (shader library)")
        }
        let alphas: [UInt8] = [255, 128, 64, 16]
        guard let probe = probeTexture(device: device, alphas: alphas) else { return XCTFail("probe texture") }

        // A 16×16 canvas with the 4×4 placed 1:1 at (4, 4): 25 % leading, 50 % trailing on both axes.
        let canvas = CGSize(width: 16, height: 16)
        engine.updateCanvasSize(canvas)
        let zone = ZoneConfiguration(
            zoneBaseConfig: ZoneConfigOptions(identifier: "zone0", zIndex: 0, orientation: .square,
                                              renderSafeAspectRatio: (AspectWidth: 1, AspectHeight: 1),
                                              constraints: ["H:|-25-[zone0]-50-|", "V:|-25-[zone0]-50-|"]),
            size: CGSize(width: 4, height: 4))
        engine.configureZones([zone])
        engine.setZoneTexture(probe, forZone: "zone0")
        engine.updateLayoutConfig()
        engine.render()

        guard let output = engine.outputTexture, let out = bytes(of: output, queue: queue) else { return XCTFail("no output") }
        XCTAssertEqual(output.pixelFormat, .bgra8Unorm)
        for (row, alpha) in alphas.enumerated() {
            let i = ((4 + row) * 16 + 5) * 4          // column 5, inside the placed 4×4; bgra order
            let (b, g, r, a) = (out[i], out[i + 1], out[i + 2], out[i + 3])
            // Premultiplied over transparent: every channel equals the source alpha.
            XCTAssertEqual(Int(r), Int(alpha), accuracy: 1, "row \(row): red should be white · \(alpha)")
            XCTAssertEqual(Int(g), Int(alpha), accuracy: 1, "row \(row): green")
            XCTAssertEqual(Int(b), Int(alpha), accuracy: 1, "row \(row): blue")
            XCTAssertEqual(Int(a), Int(alpha), accuracy: 1, "row \(row): alpha must be the source's, not its square")
        }
        // Outside the zone the canvas stays transparent black.
        XCTAssertEqual(Array(out[0..<4]), [0, 0, 0, 0])
    }
}
