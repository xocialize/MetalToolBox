//
//  PlaybackSection.swift
//  VideoPlayerKit
//
//  A window of a file to play — a CLIP of a video rather than the whole file.
//

import Foundation

/// The part of a video file to play: `start` seconds in, for `duration` seconds
/// (`nil` = through the file's end). Looping returns to `start`, not zero.
///
/// Times are MEDIA time — the player detects the section's end with a boundary
/// time observer on the item's own clock, so load latency never shortens the
/// clip and a trimmed window ends exactly where it was authored.
public struct PlaybackSection: Equatable, Sendable {

    /// Seconds into the file where playback (and every loop) begins.
    public var start: Double
    /// Seconds to play from `start`; `nil` plays through the file's end.
    public var duration: Double?

    public init(start: Double = 0, duration: Double? = nil) {
        self.start = max(0, start)
        self.duration = duration.map { max(0, $0) }
    }

    /// The whole file, from the top.
    public static let wholeFile = PlaybackSection()

    /// The section's end in media time, or `nil` for "the file's end".
    public var end: Double? { duration.map { start + $0 } }

    /// Fits the section inside an asset of `total` seconds: a start past the end
    /// collapses to the final frame's neighbourhood, and an end past the end
    /// becomes "the file's end" (the player's end-of-item path takes over).
    /// A non-positive `total` (unknown duration) returns the section unchanged.
    public func clamped(toAssetDuration total: Double) -> PlaybackSection {
        guard total > 0 else { return self }
        let start = min(self.start, max(0, total - Self.minimumClip))
        guard let end else { return PlaybackSection(start: start, duration: nil) }
        if end >= total { return PlaybackSection(start: start, duration: nil) }
        return PlaybackSection(start: start, duration: max(0, end - start))
    }

    /// The least a clamped section keeps in front of the file's end (seconds).
    static let minimumClip: Double = 0.05
}

/// What a ``VideoPlayer`` does when a section ends (2.2.0).
public enum SectionEndAction: Equatable, Sendable {
    /// Signal a lap, return to the section's start and keep playing. The
    /// default, and the only behaviour before 2.2.0: a preview that loops a
    /// trimmed clip wants this.
    case loop
    /// Signal once and stop ON the section's last frame. Nothing plays until the
    /// next ``VideoPlayer/play(url:section:)``, and a resume does not play on
    /// past the out-point. A sequencer that decides what follows each clip (a
    /// hold, the next clip, or the end of a show) wants this: with `.loop` the
    /// lap has already returned to the start by the time it decides, so a hold
    /// would freeze on the section's FIRST frame.
    case hold
}
