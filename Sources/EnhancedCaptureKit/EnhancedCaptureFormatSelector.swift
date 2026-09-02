//
//  EnhancedCaptureFormatSelector.swift
//  EnhancedCaptureKit
//
//  Picks an AVCaptureDevice.Format for an EnhancedCaptureVideoPreference.
//  The scoring works on a plain value type so it can be unit-tested without
//  camera hardware; the AVFoundation glue lives in the extensions below.
//

import Foundation
import AVFoundation
import CoreMedia
import LoggingKit

/// Hardware-independent description of one `AVCaptureDevice.Format`.
struct EnhancedCaptureFormatCandidate: Equatable {
    var width: Int32
    var height: Int32
    /// Supported frame-rate ranges, min…max, one per `AVFrameRateRange`.
    var frameRateRanges: [ClosedRange<Double>]
    /// iOS: the sensor is pixel-binned for this format (lower quality, higher
    /// fps). Always `false` on macOS.
    var isBinned: Bool = false
    /// iOS: the format can run inside an `AVCaptureMultiCamSession`. Always
    /// `true` on macOS, which has no multi-camera session.
    var isMultiCamSupported: Bool = true
    /// iOS: the format can deliver depth data (`supportedDepthDataFormats`
    /// is non-empty). Always `false` on macOS.
    var supportsDepth: Bool = false

    var pixelArea: Int { Int(width) * Int(height) }

    var maxFrameRate: Double { frameRateRanges.map(\.upperBound).max() ?? 0 }

    func supports(frameRate fps: Double) -> Bool {
        frameRateRanges.contains { $0.lowerBound <= fps && fps <= $0.upperBound }
    }

    func covers(_ size: CGSize) -> Bool {
        CGFloat(width) >= size.width && CGFloat(height) >= size.height
    }
}

enum EnhancedCaptureFormatSelector {

    /// Index of the best candidate for `preference`, or `nil` when `candidates` is empty.
    ///
    /// Rules, in order:
    /// 0. With `requireMultiCamSupport`, drop candidates that cannot run in a
    ///    multi-camera session (no fallback: such a format cannot be used).
    /// 0b. With `preferDepthSupport`, keep depth-capable candidates when there
    ///    are any (depth is optional: fall back to all if none can).
    /// 1. Keep only candidates supporting `preferredFrameRate` (fall back to
    ///    all remaining candidates if none do).
    /// 2. With a `preferredSize`, prefer candidates that cover it, choosing the
    ///    one with the least excess area; if none cover it, the largest.
    /// 3. Without a size, the largest area.
    /// 4. Ties: non-binned first, then the higher maximum frame rate, then the
    ///    earlier index (device order is stable and usually preferred-first).
    static func bestIndex(
        among candidates: [EnhancedCaptureFormatCandidate],
        preference: EnhancedCaptureVideoPreference,
        requireMultiCamSupport: Bool = false,
        preferDepthSupport: Bool = false
    ) -> Int? {
        guard !candidates.isEmpty else { return nil }

        var pool = Array(candidates.indices)
        if requireMultiCamSupport {
            pool = pool.filter { candidates[$0].isMultiCamSupported }
            guard !pool.isEmpty else { return nil }
        }
        if preferDepthSupport {
            let depthPool = pool.filter { candidates[$0].supportsDepth }
            if !depthPool.isEmpty { pool = depthPool }
        }
        if let fps = preference.preferredFrameRate {
            let fpsPool = pool.filter { candidates[$0].supports(frameRate: fps) }
            if !fpsPool.isEmpty { pool = fpsPool }
        }

        // Primary key: for a size preference, negative excess area among
        // covering formats (so "least excess" sorts first); non-covering
        // formats rank below every covering one, largest first.
        func primary(_ index: Int) -> (tier: Int, key: Int) {
            let c = candidates[index]
            if let size = preference.preferredSize {
                if c.covers(size) {
                    let target = Int(size.width) * Int(size.height)
                    return (0, c.pixelArea - target)      // smaller excess wins
                }
                return (1, -c.pixelArea)                   // larger wins
            }
            return (0, -c.pixelArea)                       // larger wins
        }

        return pool.min { lhs, rhs in
            let lp = primary(lhs), rp = primary(rhs)
            if lp.tier != rp.tier { return lp.tier < rp.tier }
            if lp.key != rp.key { return lp.key < rp.key }
            let lc = candidates[lhs], rc = candidates[rhs]
            if lc.isBinned != rc.isBinned { return !lc.isBinned }
            if lc.maxFrameRate != rc.maxFrameRate { return lc.maxFrameRate > rc.maxFrameRate }
            return lhs < rhs
        }
    }

    /// The frame duration for `fps`, kept fractional — `1000 / round(fps × 1000)`
    /// — so 59.94 stays 59.94 rather than rounding to 60. `nil` for a rate that
    /// is not a positive finite number representable in a `CMTimeScale`.
    ///
    /// Rounding to an integer timescale is not merely imprecise: 1/60 s is
    /// shorter than a 59.94 fps format's minimum frame duration, and
    /// `activeVideoMinFrameDuration` raises `NSInvalidArgumentException` for
    /// an unsupported value — an ObjC exception Swift cannot catch.
    static func frameDuration(forFrameRate fps: Double) -> CMTime? {
        guard fps.isFinite, fps > 0 else { return nil }
        let scaled = (fps * 1000).rounded()
        guard scaled >= 1, scaled <= Double(Int32.max) else { return nil }
        return CMTime(value: 1000, timescale: CMTimeScale(scaled))
    }
}

// MARK: - AVFoundation glue

extension AVCaptureDevice.Format {
    var enhancedCandidate: EnhancedCaptureFormatCandidate {
        let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let ranges = videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }
        #if os(iOS)
        let binned = isVideoBinned
        let multiCam = isMultiCamSupported
        let depth = !supportedDepthDataFormats.isEmpty
        #else
        let binned = false
        let multiCam = true
        let depth = false
        #endif
        return EnhancedCaptureFormatCandidate(
            width: dims.width, height: dims.height, frameRateRanges: ranges,
            isBinned: binned, isMultiCamSupported: multiCam, supportsDepth: depth
        )
    }
}

extension AVCaptureDevice {

    /// Applies `preference` to the device: selects the best format and, when a
    /// frame rate is requested, locks the min/max frame duration to it.
    /// With `requireMultiCamSupport` only formats an `AVCaptureMultiCamSession`
    /// accepts are considered. Returns the chosen format, or `nil` when the
    /// device has no usable format.
    @discardableResult
    func applyVideoPreference(_ preference: EnhancedCaptureVideoPreference, requireMultiCamSupport: Bool = false, preferDepthSupport: Bool = false) throws -> AVCaptureDevice.Format? {
        let videoFormats = formats.filter {
            CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Video
        }
        let candidates = videoFormats.map(\.enhancedCandidate)
        guard let index = EnhancedCaptureFormatSelector.bestIndex(
            among: candidates, preference: preference,
            requireMultiCamSupport: requireMultiCamSupport, preferDepthSupport: preferDepthSupport
        ) else {
            return nil
        }
        let format = videoFormats[index]
        let candidate = candidates[index]

        try lockForConfiguration()
        defer { unlockForConfiguration() }

        activeFormat = format
        if let fps = preference.preferredFrameRate,
           let range = format.videoSupportedFrameRateRanges.first(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }),
           let requested = EnhancedCaptureFormatSelector.frameDuration(forFrameRate: fps) {
            // Clamp into the range AVFoundation reported so the value is always
            // one the setter accepts (see `frameDuration(forFrameRate:)`).
            var duration = requested
            if duration < range.minFrameDuration { duration = range.minFrameDuration }
            if duration > range.maxFrameDuration { duration = range.maxFrameDuration }
            activeVideoMinFrameDuration = duration
            activeVideoMaxFrameDuration = duration
        }
        mlog.debug("Selected format \(candidate.width)x\(candidate.height) @ ≤\(candidate.maxFrameRate) fps for \(self.localizedName)")
        return format
    }
}
