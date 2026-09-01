//
//  VideoPlayer.swift
//  VideoPlayerKit
//
//  Created by Dustin Nielson on 4/12/25.
//
//  OPTIMIZATIONS:
//  - Dedicated processing queue for asynchronous buffer operations
//  - Unique identifier for tracking multiple player instances
//  - Loop completion delegate callback for synchronized playback management
//  - Both synchronous and asynchronous buffer checking methods
//
//  METAL COMPATIBILITY:
//  AVPlayerItemVideoOutput MUST include kCVPixelBufferMetalCompatibilityKey: true
//  in its pixelBufferAttributes. Without this, CVPixelBuffers from video frames
//  cannot be converted to MTLTextures via CVMetalTextureCache on iOS. macOS
//  produces Metal-compatible buffers by default, so the omission only manifests
//  as a silent failure on iOS (video plays but frames never render).
//  ImageProcessingKit and CaptureKit already set this flag on their outputs.
//

#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import Cocoa
#endif
import AVFoundation
import OSLog
import LoggingKit


public protocol VideoPlayerDelegate: AnyObject {

    func VideoPlayerBuffer(pixelBuffer: CVPixelBuffer?)
    func videoPlayerDidCompleteLoop(identifier: String)
}

public class VideoPlayer: NSObject, @unchecked Sendable {

    public weak var delegate: VideoPlayerDelegate?

    /// Unique identifier for this video player instance
    public let identifier: String

    /// Dedicated queue for video buffer processing to avoid blocking the main render loop
    private let processingQueue: DispatchQueue

    var player:AVPlayer = AVPlayer()
    var playerLooper: AVPlayerLooper?
    var playerItem:AVPlayerItem?

    var videoOutput:AVPlayerItemVideoOutput?
    
    /// Cache the last pixel buffer to avoid returning nil between frames
    private var lastPixelBuffer: CVPixelBuffer?

    /// Stored observer token for AVPlayerItemDidPlayToEndTime notification.
    /// Must be removed in deinit/stopVideo to prevent observer accumulation.
    private var playbackEndObserver: (any NSObjectProtocol)?

    // MARK: - Sections (play a clip of the file, not the whole file)

    /// The part of the file being played. `videoUrl` alone plays whatever
    /// section is current (the whole file unless one was set); use
    /// ``play(url:section:)`` to set both together.
    public private(set) var section: PlaybackSection = .wholeFile

    /// Boundary time observer at the section's END, on the item's own clock —
    /// the reason a trimmed clip ends where it was authored regardless of how
    /// long the player took to load. `nil` when the section runs to the file's end.
    private var sectionEndObserver: Any?

    /// A lap is signalled ONCE. When a section ends at (or beyond) the file's
    /// end, both the boundary observer and `AVPlayerItemDidPlayToEndTime` can
    /// fire for the same lap; the first to arrive signals and latches, the
    /// seek back to `start` clears the latch.
    private var lapSignaled = false

    /// The section's start as a precise seek target.
    private var sectionStartTime: CMTime {
        CMTime(seconds: section.start, preferredTimescale: 600)
    }

    public var videoUrl: URL?  {
        didSet{
            guard videoUrl != nil else {
                stopVideo()
                lastPixelBuffer = nil
                return
            }
            loopVideo()
        }
    }

    /// Plays `url` — or the given `section` of it — looping the section.
    /// The preferred entry point for sectioned playback: it sets the section
    /// BEFORE the url's observer starts loading, so the first frame is already
    /// the clip's first frame.
    public func play(url: URL, section: PlaybackSection = .wholeFile) {
        self.section = section
        videoUrl = url
    }

    /// Precise seek (zero tolerance both sides) in media seconds.
    /// `completion` receives AVFoundation's finished flag on the main queue.
    public func seek(to seconds: Double, completion: (@Sendable (Bool) -> Void)? = nil) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard let completion else { return }
            DispatchQueue.main.async { completion(finished) }
        }
    }
    
    public var playerIsPause:Bool = false {
        didSet {}
    }

    public convenience init(delegate: VideoPlayerDelegate, identifier: String) {
        self.init(identifier: identifier)
        self.delegate = delegate
        videoPlayerInit()
    }

    public init(identifier: String) {
        self.identifier = identifier
        self.processingQueue = DispatchQueue(
            label: "com.xocialize.videoplayer.\(identifier)",
            qos: .userInteractive,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
        super.init()
    }
    
    deinit {
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func videoPlayerInit(){ //self.player.currentItem

        installEndObserver()

       videoOutput = {
            let v = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
                String(kCVPixelBufferMetalCompatibilityKey): true  // Required for CVMetalTextureCache on iOS
            ])
            return v
        }()
        
        player.volume = 1.0
        
        player.isMuted = false
        
        player.actionAtItemEnd = .none
        
    }
    
    public func loopVideo(){

        guard let videoUrl, let videoOutput else { return }

        // Re-register the playback-end observer if stopVideo() removed it.
        // Without this, videoPlayerDidCompleteLoop never fires after a stop→play cycle.
        if playbackEndObserver == nil { installEndObserver() }
        removeSectionEndObserver()
        lapSignaled = false

        let videoItem = AVPlayerItem(url: videoUrl)

        videoItem.add(videoOutput)

        videoItem.preferredForwardBufferDuration = TimeInterval(0.5)

        player.replaceCurrentItem(with: videoItem)

        // Precise: a clip that starts mid-file must start ON its first frame,
        // not the nearest keyframe before it.
        player.seek(to: sectionStartTime, toleranceBefore: .zero, toleranceAfter: .zero)

        if let end = section.end {
            let endTime = NSValue(time: CMTime(seconds: end, preferredTimescale: 600))
            sectionEndObserver = player.addBoundaryTimeObserver(forTimes: [endTime], queue: .main) { [weak self] in
                self?.completeLap()
            }
        }

        player.play()

}

    /// `AVPlayerItemDidPlayToEndTime` → a lap of the current item. Registered
    /// once at init and again after a stop. Loops return to the SECTION's
    /// start, not zero.
    private func installEndObserver() {
        playbackEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] vidObjItem in
            guard let self = self else { return }
            guard let vItem = vidObjItem.object as? AVPlayerItem else { return }
            if vItem == self.player.currentItem {
                self.completeLap()
            }
        }
    }

    /// One lap of the section is done: signal the delegate ONCE, return to the
    /// section's start, keep playing. Both the boundary observer and the
    /// end-of-item notification route here; `lapSignaled` de-duplicates a lap
    /// that both report (a section ending at the file's end).
    private func completeLap() {
        if !lapSignaled {
            lapSignaled = true
            delegate?.videoPlayerDidCompleteLoop(identifier: identifier)
        }
        player.seek(to: sectionStartTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.lapSignaled = false
        }
        player.play()
    }

    private func removeSectionEndObserver() {
        if let sectionEndObserver {
            player.removeTimeObserver(sectionEndObserver)
            self.sectionEndObserver = nil
        }
    }
    
    /// Play a pre-composed AVPlayerItem (e.g., from VideoMerge.compose()).
    ///
    /// Attaches the video output for pixel buffer extraction and starts looped playback.
    /// This replaces any currently playing content. The existing loop observer handles
    /// seek-to-zero on completion, and directBufferCheck() works unchanged.
    ///
    /// - Parameter playerItem: An AVPlayerItem, typically from ``VideoMerge/compose(urls:)``
    public func loadMergedVideo(playerItem: AVPlayerItem) {
        if let videoOutput {
            playerItem.add(videoOutput)
        }

        playerItem.preferredForwardBufferDuration = 0.5

        player.replaceCurrentItem(with: playerItem)
        player.seek(to: CMTime.zero)
        player.play()
    }

    public func stopVideo(pausePlayer:Bool = false){
        player.pause()
        removeSectionEndObserver()
        lapSignaled = false
        player.replaceCurrentItem(with: nil) // We need to do this or we'll get a stray frame during the renderLoop even when the video isn't active.
        lastPixelBuffer = nil
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObserver = nil
        }
    }
    
    
    // This could be called from the render loop instead of the direct methods below.
    public func indirectBufferCheck() {
        guard let videoOutput else {
            
            delegate?.VideoPlayerBuffer(pixelBuffer: lastPixelBuffer)
            return  }
        if videoOutput.hasNewPixelBuffer(forItemTime: player.currentTime()) {
            if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
                lastPixelBuffer = pixelBuffer
                delegate?.VideoPlayerBuffer(pixelBuffer: pixelBuffer)
            } else {
                mlog.error("indirectBufferCheck: cannot convert pixel buffer")
                delegate?.VideoPlayerBuffer(pixelBuffer: lastPixelBuffer)
            }
        } else {
            delegate?.VideoPlayerBuffer(pixelBuffer: lastPixelBuffer)
        }
    }
    
    /// Direct buffer check - optimized for synchronous calls from render loop
    /// Returns pixel buffer immediately if available, or the last cached buffer if no new frame
    public func directBufferCheck() -> CVPixelBuffer? {
        guard let videoOutput else { return lastPixelBuffer }
        
        let currentTime = player.currentTime()
        
        // Check if there's a new pixel buffer available
        if videoOutput.hasNewPixelBuffer(forItemTime: currentTime) {
            if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) {
                // Cache the new buffer and return it
                lastPixelBuffer = pixelBuffer
                return pixelBuffer
            } else {
                mlog.error("directBufferCheck [\(self.identifier)]: cannot convert pixel buffer")
                // Return cached buffer as fallback
                return lastPixelBuffer
            }
        } else {
            // No new buffer available, return the cached one
            return lastPixelBuffer
        }
    }

    /// Asynchronous buffer check using dedicated processing queue
    /// Calls completion handler with pixel buffer on the processing queue
    public func asyncBufferCheck(completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
        processingQueue.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let videoOutput = self.videoOutput else {
                completion(nil)
                return
            }
            let currentTime = self.player.currentTime()
            if videoOutput.hasNewPixelBuffer(forItemTime: currentTime) {
                if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) {
                    completion(pixelBuffer)
                } else {
                    mlog.error("asyncBufferCheck [\(self.identifier)]: cannot convert pixel buffer")
                    completion(nil)
                }
            } else {
                completion(nil)
            }
        }
    }
}


