//
//  EnhancedCaptureTestPattern.swift
//  EnhancedCaptureKit
//
//  A capture source that needs no hardware: colour bars, ramps or a solid
//  colour rendered into Metal-compatible pixel buffers and delivered as
//  CMSampleBuffers with host-clock timestamps, so the compositor sees exactly
//  what a camera or capture card would hand it. Runs on the iOS Simulator.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import LoggingKit

// MARK: - Pattern

/// What the synthetic source draws. Colours are 75 % amplitude (191/255), as
/// broadcast bars are, so highlights are not clipped by later processing.
public enum EnhancedCaptureTestPattern: Sendable, Hashable {
    /// Seven colour bars over a black-to-white ramp.
    case colorBars
    /// Horizontal grey ramp, black at the left edge.
    case grayRamp
    /// 64-pixel checkerboard of two greys.
    case checkerboard
    /// One flat colour, components 0…1.
    case solid(red: Double, green: Double, blue: Double)

    /// Identifier used in the source id and display name.
    var name: String {
        switch self {
        case .colorBars:    return "color-bars"
        case .grayRamp:     return "gray-ramp"
        case .checkerboard: return "checkerboard"
        case .solid:        return "solid"
        }
    }
}

// MARK: - Renderer (pure; unit-testable)

/// Draws a pattern once into a BGRA template and derives the biplanar YCbCr
/// planes from it, so the per-frame work is a row copy plus the marker.
enum EnhancedCaptureTestPatternRenderer {

    /// Colour bars (white, yellow, cyan, green, magenta, red, blue) at 75 %.
    static let barColors: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0),
        (191, 0, 191), (191, 0, 0), (0, 0, 191),
    ]

    /// BGRA bytes, `width * height * 4`, no row padding.
    static func bgraTemplate(_ pattern: EnhancedCaptureTestPattern, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let barsBottom = height * 2 / 3
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b): (UInt8, UInt8, UInt8)
                switch pattern {
                case .colorBars:
                    if y < barsBottom {
                        let bar = min(barColors.count - 1, x * barColors.count / max(1, width))
                        let c = barColors[bar]
                        (r, g, b) = (c.r, c.g, c.b)
                    } else {
                        let v = UInt8(clamping: x * 255 / max(1, width - 1))
                        (r, g, b) = (v, v, v)
                    }
                case .grayRamp:
                    let v = UInt8(clamping: x * 255 / max(1, width - 1))
                    (r, g, b) = (v, v, v)
                case .checkerboard:
                    let dark = ((x / 64) + (y / 64)) % 2 == 0
                    let v: UInt8 = dark ? 64 : 191
                    (r, g, b) = (v, v, v)
                case .solid(let red, let green, let blue):
                    (r, g, b) = (component(red), component(green), component(blue))
                }
                let offset = (y * width + x) * 4
                bytes[offset] = b
                bytes[offset + 1] = g
                bytes[offset + 2] = r
                bytes[offset + 3] = 255
            }
        }
        return bytes
    }

    /// Luma plane (`width * height`) and interleaved CbCr plane
    /// (`(width/2) * (height/2) * 2`) for a BGRA template, BT.709.
    static func yCbCrPlanes(fromBGRA bgra: [UInt8], width: Int, height: Int, fullRange: Bool) -> (luma: [UInt8], chroma: [UInt8]) {
        var luma = [UInt8](repeating: 0, count: width * height)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        var chroma = [UInt8](repeating: 128, count: chromaWidth * chromaHeight * 2)

        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let (yv, cb, cr) = yCbCr(r: bgra[o + 2], g: bgra[o + 1], b: bgra[o], fullRange: fullRange)
                luma[y * width + x] = yv
                if x % 2 == 0 && y % 2 == 0 {
                    let c = ((y / 2) * chromaWidth + x / 2) * 2
                    chroma[c] = cb
                    chroma[c + 1] = cr
                }
            }
        }
        return (luma, chroma)
    }

    /// BT.709 RGB → Y'CbCr for one pixel.
    static func yCbCr(r: UInt8, g: UInt8, b: UInt8, fullRange: Bool) -> (y: UInt8, cb: UInt8, cr: UInt8) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let yp = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
        let cbp = (bf - yp) / 1.8556
        let crp = (rf - yp) / 1.5748
        if fullRange {
            return (component(yp), component(0.5 + cbp), component(0.5 + crp))
        }
        return (
            UInt8(clamping: Int((16 + 219 * yp).rounded())),
            UInt8(clamping: Int((128 + 224 * cbp).rounded())),
            UInt8(clamping: Int((128 + 224 * crp).rounded()))
        )
    }

    /// Luma code value of white for the marker.
    static func whiteLuma(fullRange: Bool) -> UInt8 { fullRange ? 255 : 235 }

    /// Layout of the 16-square frame counter for a frame `width` pixels wide:
    /// squares `square` px on a `cell` px pitch starting 8 px in, capped at
    /// 16 px squares / 20 px pitch and shrunk for narrow frames. `nil` when
    /// the frame is too narrow to hold 16 squares of at least 4 px.
    static func counterGeometry(width: Int) -> (cell: Int, square: Int)? {
        let cell = min(20, (width - 16) / 16)
        guard cell >= 5 else { return nil }
        return (cell, cell * 4 / 5)
    }

    /// Left edge of counter square `bit` (0 = most significant).
    static func counterX(bit: Int, geometry: (cell: Int, square: Int)) -> Int {
        8 + bit * geometry.cell
    }

    private static func component(_ value: Double) -> UInt8 {
        UInt8(clamping: Int((max(0, min(1, value)) * 255).rounded()))
    }
}

// MARK: - Source

protocol EnhancedCaptureTestPatternSourceDelegate: AnyObject {
    nonisolated func testPatternSource(_ source: EnhancedCaptureTestPatternSource, didOutput sampleBuffer: CMSampleBuffer)
}

/// Generates frames on a strict timer into a `CVPixelBufferPool` and hands
/// them out as `CMSampleBuffer`s stamped from the host clock — the same clock
/// AVFoundation stamps camera frames with, so real and synthetic sources mix.
///
/// When `animated`, every frame carries a moving 8-pixel white bar and a row
/// of 16 squares encoding the frame counter in binary (white = 1, MSB left),
/// so motion, drops and latency are visible to the eye and measurable from a
/// screenshot.
final class EnhancedCaptureTestPatternSource: @unchecked Sendable {

    let captureSource: EnhancedCaptureSource
    let pattern: EnhancedCaptureTestPattern
    let width: Int
    let height: Int
    let frameRate: Double
    let pixelFormat: EnhancedCapturePixelFormat
    let animated: Bool

    weak var delegate: EnhancedCaptureTestPatternSourceDelegate?

    private let queue = DispatchQueue(label: "com.xocialize.MetalToolBox.EnhancedCaptureTestPattern", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var frameIndex: Int64 = 0

    private let templateBGRA: [UInt8]
    private let templateLuma: [UInt8]
    private let templateChroma: [UInt8]

    /// Frames produced since `start()`; read from any thread.
    var framesProduced: Int64 {
        queue.sync { frameIndex }
    }

    init(configuration: EnhancedCaptureConfiguration, delegate: EnhancedCaptureTestPatternSourceDelegate) {
        self.pattern = configuration.testPattern
        // Even dimensions keep the 4:2:0 chroma grid exact.
        self.width = max(16, Int(configuration.testPatternSize.width.rounded()) & ~1)
        self.height = max(16, Int(configuration.testPatternSize.height.rounded()) & ~1)
        self.frameRate = min(240, max(1, configuration.testPatternFrameRate))
        self.pixelFormat = configuration.pixelFormat
        self.animated = configuration.testPatternAnimated
        self.delegate = delegate

        let name = pattern.name
        self.captureSource = EnhancedCaptureSource(
            id: "test-pattern-\(name)",
            type: .testPattern,
            displayName: "Test Pattern (\(name) \(width)×\(height) @ \(Int(frameRate.rounded())) fps)",
            manufacturer: "MetalToolBox",
            modelID: "TestPattern",
            uniqueID: "test-pattern-\(name)",
            media: .video
        )

        let bgra = EnhancedCaptureTestPatternRenderer.bgraTemplate(pattern, width: width, height: height)
        self.templateBGRA = bgra
        if pixelFormat == .bgra {
            self.templateLuma = []
            self.templateChroma = []
        } else {
            let planes = EnhancedCaptureTestPatternRenderer.yCbCrPlanes(
                fromBGRA: bgra, width: width, height: height, fullRange: pixelFormat == .yCbCr420FullRange
            )
            self.templateLuma = planes.luma
            self.templateChroma = planes.chroma
        }
    }

    deinit {
        timer?.cancel()
    }

    // MARK: Control

    /// Starts frame delivery. Returns the error that prevented it, if any.
    func start() -> EnhancedCaptureError? {
        queue.sync {
            guard timer == nil else { return nil }
            if pool == nil {
                guard let created = makePool() else {
                    return .captureStartFailed(reason: "could not create pixel buffer pool for test pattern")
                }
                pool = created
            }
            let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            let interval = 1.0 / frameRate
            source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
            mlog.info("Test pattern started: \(self.captureSource.displayName)")
            return nil
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
        mlog.info("Test pattern stopped")
    }

    // MARK: Frame production (on `queue`)

    private func makePool() -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat.coreVideoType,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess else {
            mlog.error("CVPixelBufferPoolCreate failed: \(status)")
            return nil
        }
        return pool
    }

    private func tick() {
        guard let pool else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else {
            mlog.warning("Test pattern: pool exhausted (consumer holding buffers?) — frame skipped")
            frameIndex += 1
            return
        }

        fill(pixelBuffer, frame: frameIndex)
        tagColor(pixelBuffer)

        if formatDescription == nil {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
            formatDescription = description
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1000, timescale: CMTimeScale((frameRate * 1000).rounded())),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        frameIndex += 1
        guard status == noErr, let sampleBuffer else {
            mlog.error("Test pattern: CMSampleBufferCreateReadyWithImageBuffer failed: \(status)")
            return
        }
        delegate?.testPatternSource(self, didOutput: sampleBuffer)
    }

    private func fill(_ pixelBuffer: CVPixelBuffer, frame: Int64) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let markerX = animated ? Int((frame * 4) % Int64(width)) : nil

        switch pixelFormat {
        case .bgra:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            templateBGRA.withUnsafeBytes { template in
                for y in 0..<height {
                    let src = template.baseAddress!.advanced(by: y * width * 4)
                    memcpy(base.advanced(by: y * stride), src, width * 4)
                }
            }
            if let markerX {
                let barWidth = min(8, width - markerX)
                for y in 0..<height {
                    memset(base.advanced(by: y * stride + markerX * 4), 0xFF, barWidth * 4)
                }
                drawCounterBGRA(base: base, stride: stride, frame: frame)
            }

        case .yCbCr420VideoRange, .yCbCr420FullRange:
            let fullRange = pixelFormat == .yCbCr420FullRange
            guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let chromaWidth = width / 2
            let chromaHeight = height / 2
            templateLuma.withUnsafeBytes { luma in
                for y in 0..<height {
                    memcpy(lumaBase.advanced(by: y * lumaStride), luma.baseAddress!.advanced(by: y * width), width)
                }
            }
            templateChroma.withUnsafeBytes { chroma in
                for y in 0..<chromaHeight {
                    memcpy(chromaBase.advanced(by: y * chromaStride), chroma.baseAddress!.advanced(by: y * chromaWidth * 2), chromaWidth * 2)
                }
            }
            if let markerX {
                let white = Int32(EnhancedCaptureTestPatternRenderer.whiteLuma(fullRange: fullRange))
                let barWidth = min(8, width - markerX)
                for y in 0..<height {
                    memset(lumaBase.advanced(by: y * lumaStride + markerX), white, barWidth)
                }
                let cx = markerX / 2
                let cw = min(4, chromaWidth - cx)
                for y in 0..<chromaHeight {
                    memset(chromaBase.advanced(by: y * chromaStride + cx * 2), 128, cw * 2)
                }
                drawCounterLuma(base: lumaBase, stride: lumaStride, frame: frame, white: white)
            }
        }
    }

    /// 16 squares across the top-left, MSB first; see `counterGeometry(width:)`.
    private func drawCounterBGRA(base: UnsafeMutableRawPointer, stride: Int, frame: Int64) {
        guard let geometry = EnhancedCaptureTestPatternRenderer.counterGeometry(width: width),
              8 + geometry.square <= height else { return }
        for bit in 0..<16 {
            let on = (frame >> (15 - bit)) & 1 == 1
            let x0 = EnhancedCaptureTestPatternRenderer.counterX(bit: bit, geometry: geometry)
            for y in 8..<(8 + geometry.square) {
                let row = base.advanced(by: y * stride + x0 * 4)
                memset(row, on ? 0xFF : 0x00, geometry.square * 4)
                if !on {
                    // Alpha stays opaque for the "0" squares.
                    let pixels = row.assumingMemoryBound(to: UInt8.self)
                    for px in 0..<geometry.square { pixels[px * 4 + 3] = 0xFF }
                }
            }
        }
    }

    private func drawCounterLuma(base: UnsafeMutableRawPointer, stride: Int, frame: Int64, white: Int32) {
        guard let geometry = EnhancedCaptureTestPatternRenderer.counterGeometry(width: width),
              8 + geometry.square <= height else { return }
        let black: Int32 = pixelFormat == .yCbCr420FullRange ? 0 : 16
        for bit in 0..<16 {
            let on = (frame >> (15 - bit)) & 1 == 1
            let x0 = EnhancedCaptureTestPatternRenderer.counterX(bit: bit, geometry: geometry)
            for y in 8..<(8 + geometry.square) {
                memset(base.advanced(by: y * stride + x0), on ? white : black, geometry.square)
            }
        }
    }

    /// BT.709 tags so downstream conversion picks the matrix the template used.
    private func tagColor(_ pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }
}
