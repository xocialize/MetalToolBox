//
//  VideoMerge.swift
//  VideoPlayerKit
//
//  Created by Dustin Nielson on 2/8/26.
//
//  Composes multiple video file URLs into a single AVPlayerItem using
//  an in-memory AVMutableComposition. Designed for reassembling chunked
//  video content delivered as individual mediaItems due to bandwidth constraints.
//

import AVFoundation
import OSLog
import LoggingKit


/// Errors that can occur during video merge composition.
public enum VideoMergeError: Error, Sendable {
    /// No URLs were provided to merge.
    case emptyURLList
    /// An asset could not load its duration or tracks.
    case assetLoadFailed(url: URL, description: String)
    /// No video tracks were found in any of the provided assets.
    case noVideoTracksFound
    /// Failed to create a mutable track in the composition.
    case trackCreationFailed
    /// Failed to insert a time range into the composition track.
    case trackInsertionFailed(url: URL, description: String)
}

/// Composes multiple video file URLs into a single AVPlayerItem
/// using an in-memory AVMutableComposition (no disk export).
///
/// Usage:
/// ```swift
/// let merger = VideoMerge()
/// let playerItem = try await merger.compose(urls: chunkURLs)
/// videoPlayer.loadMergedVideo(playerItem: playerItem)
/// ```
public final class VideoMerge: Sendable {

    public init() {}

    /// Compose multiple video URLs into a single AVPlayerItem.
    ///
    /// Creates an AVMutableComposition with concatenated video and audio tracks.
    /// Audio tracks are optional — chunks that lack audio are handled gracefully
    /// by only inserting their video track data.
    ///
    /// - Parameter urls: Ordered list of local file URLs to merge. Chunk order matters.
    /// - Returns: An AVPlayerItem backed by the in-memory composition, ready for playback.
    /// - Throws: ``VideoMergeError`` if composition fails.
    public func compose(urls: [URL]) async throws -> AVPlayerItem {
        guard !urls.isEmpty else {
            throw VideoMergeError.emptyURLList
        }

        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoMergeError.trackCreationFailed
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var insertionTime = CMTime.zero
        var hasVideoContent = false
        var hasAudioContent = false

        for url in urls {
            let asset = AVURLAsset(url: url)

            let duration: CMTime
            do {
                duration = try await asset.load(.duration)
            } catch {
                throw VideoMergeError.assetLoadFailed(
                    url: url,
                    description: error.localizedDescription
                )
            }

            let timeRange = CMTimeRangeMake(start: .zero, duration: duration)

            // Video track insertion
            do {
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                if let sourceVideoTrack = videoTracks.first {
                    try compositionVideoTrack.insertTimeRange(
                        timeRange,
                        of: sourceVideoTrack,
                        at: insertionTime
                    )
                    hasVideoContent = true
                }
            } catch {
                throw VideoMergeError.trackInsertionFailed(
                    url: url,
                    description: error.localizedDescription
                )
            }

            // Audio track insertion (optional — skip gracefully if missing)
            if let compositionAudioTrack {
                do {
                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                    if let sourceAudioTrack = audioTracks.first {
                        try compositionAudioTrack.insertTimeRange(
                            timeRange,
                            of: sourceAudioTrack,
                            at: insertionTime
                        )
                        hasAudioContent = true
                    }
                } catch {
                    // Audio insertion failure is non-fatal — continue without audio for this chunk
                    mlog.error("Audio track insertion skipped for \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            insertionTime = CMTimeAdd(insertionTime, duration)
        }

        guard hasVideoContent else {
            throw VideoMergeError.noVideoTracksFound
        }

        // Remove empty audio track if no chunks contained audio
        if !hasAudioContent, let compositionAudioTrack {
            composition.removeTrack(compositionAudioTrack)
        }

        let playerItem = AVPlayerItem(asset: composition)
        playerItem.preferredForwardBufferDuration = 0.5
        return playerItem
    }
}
