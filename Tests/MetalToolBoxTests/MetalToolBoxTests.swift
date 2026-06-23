//
//  MetalToolBoxTests.swift
//  MetalToolBox
//

import XCTest
import Metal
import CoreVideo
@testable import MetalToolBox

final class MetalToolBoxTests: XCTestCase {

    // MARK: - TextureConverter

    func testTextureConverterEmptyTexture() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let converter = TextureConverter(device: device)
        let texture = converter.emptyTexture()
        XCTAssertNotNil(texture)
        XCTAssertEqual(texture?.width, 1)
        XCTAssertEqual(texture?.height, 1)
    }

    func testTextureConverterConvertsPixelBuffer() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let converter = TextureConverter(device: device)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 32,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        guard let pixelBuffer else { return }

        let texture = converter.convert(pixelBuffer)
        XCTAssertNotNil(texture)
        XCTAssertEqual(texture?.width, 64)
        XCTAssertEqual(texture?.height, 32)
        converter.flush()
    }
}

final class MetalViewTests: XCTestCase {

    func testMetalViewInitializationWithDevice() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // Skip test if no Metal device available (CI environment)
            return
        }

        if #available(macOS 14.0, iOS 16.0, tvOS 18.0, *) {
            let view = EnhancedMetalView(device: device)
            XCTAssertNotNil(view.device)
            XCTAssertTrue(view.maintainAspectRatio)
            XCTAssertNil(view.displayTexture)
        }
    }

    func testMetalViewClearTexture() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }

        if #available(macOS 14.0, iOS 16.0, tvOS 18.0, *) {
            let view = EnhancedMetalView(device: device)
            view.clearTexture()
            XCTAssertNil(view.displayTexture)
        }
    }

    func testMetalViewPauseResume() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }

        if #available(macOS 14.0, iOS 16.0, tvOS 18.0, *) {
            let view = EnhancedMetalView(device: device)
            view.pauseRendering()
            XCTAssertTrue(view.isPaused)
            view.resumeRendering()
            XCTAssertFalse(view.isPaused)
        }
    }
}
