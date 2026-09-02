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
    /// 1. Keep only candidates supporting `preferredFrameRate` (fall back to
    ///    all candidates if none do).
    /// 2. With a `preferredSize`, prefer candidates that cover it, choosing the
    ///    one with the least excess area; if none cover it, the largest.
    /// 3. Without a size, the largest area.
    /// 4. Ties: non-binned first, then the higher maximum frame rate, then the
    ///    earlier index (device order is stable and usually preferred-first).
    static func bestIndex(
        among candidates: [EnhancedCaptureFormatCandidate],
        preference: EnhancedCaptureVideoPreference
    ) -> Int? {
        guard !candidates.isEmpty else { return nil }

        var pool = Array(candidates.indices)
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
}

// MARK: - AVFoundation glue

extension AVCaptureDevice.Format {
    var enhancedCandidate: EnhancedCaptureFormatCandidate {
        let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let ranges = videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }
        #if os(iOS)
        let binned = isVideoBinned
        #else
        let binned = false
        #endif
        return EnhancedCaptureFormatCandidate(
            width: dims.width, height: dims.height, frameRateRanges: ranges, isBinned: binned
        )
    }
}

extension AVCaptureDevice {

    /// Applies `preference` to the device: selects the best format and, when a
    /// frame rate is requested, locks the min/max frame duration to it.
    /// Returns the chosen format, or `nil` when the device has none.
    @discardableResult
    func applyVideoPreference(_ preference: EnhancedCaptureVideoPreference) throws -> AVCaptureDevice.Format? {
        let videoFormats = formats.filter {
            CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Video
        }
        let candidates = videoFormats.map(\.enhancedCandidate)
        guard let index = EnhancedCaptureFormatSelector.bestIndex(among: candidates, preference: preference) else {
            return nil
        }
        let format = videoFormats[index]
        let candidate = candidates[index]

        try lockForConfiguration()
        defer { unlockForConfiguration() }

        activeFormat = format
        if let fps = preference.preferredFrameRate, candidate.supports(frameRate: fps) {
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            activeVideoMinFrameDuration = duration
            activeVideoMaxFrameDuration = duration
        }
        mlog.debug("Selected format \(candidate.width)x\(candidate.height) @ ≤\(candidate.maxFrameRate) fps for \(self.localizedName)")
        return format
    }
}
