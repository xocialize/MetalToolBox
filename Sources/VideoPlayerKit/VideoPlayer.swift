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

    /// What the player does when a section ends. See ``SectionEndAction``.
    ///
    /// Belongs to the PLAYER, not the clip: a consumer that sequences clips
    /// itself sets `.hold` once, and every section it plays then ends on its
    /// last frame and waits for the next ``play(url:section:)``.
    public var actionAtSectionEnd: SectionEndAction = .loop

    /// Set when a `.hold` section has ended: the player is stopped on the
    /// section's last frame, and a resume does not play on past the out-point.
    /// Cleared by the next load and by ``stopVideo()``.
    public private(set) var hasFinishedSection = false

    /// How close to the out-point a frame may start and still be refused:
    /// rounding room for a frame whose time is the out-point itself. Frames are
    /// at least 8 ms apart even at 120 fps, so no earlier frame can fall inside.
    static let outPointTolerance: Double = 0.001

    /// Whether audio is muted. Kept across loads: it belongs to the player, not
    /// the clip, so a preview that starts muted stays muted from clip to clip.
    public var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    /// The playhead in media seconds, on the item's own clock. It holds still
    /// while playback is held and after a `.hold` section ends. 0 with nothing
    /// loaded.
    public var mediaTime: Double {
        guard player.currentItem != nil else { return 0 }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
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
    
    /// Whether playback is HELD on its current frame.
    ///
    /// Setting this pauses or resumes the underlying player and touches nothing
    /// else — not the item, not the section observer, not the last delivered
    /// pixel buffer. So a render loop reading ``directBufferCheck()`` keeps
    /// presenting the frame it already has (a natural freeze), and a resume
    /// continues from exactly where the hold landed: the clock is AVPlayer's,
    /// so no consumer has to track a position.
    ///
    /// This is the opposite of ``stopVideo()``, which tears the item down and
    /// clears the buffer precisely so a stale frame CANNOT be presented.
    ///
    /// ⚠️ Before 2.1.0 this property's observer was empty — setting it flipped
    /// a flag and nothing else, so a caller believed playback was held while it
    /// carried on regardless. It is honoured now.
    public var playerIsPause: Bool = false {
        didSet {
            guard playerIsPause != oldValue else { return }
            if playerIsPause {
                player.pause()
            } else if player.currentItem != nil, !hasFinishedSection {
                // Resuming with nothing loaded is not a play; `stopVideo()`
                // clears the hold on its way out and must not start anything.
                // Nor is resuming a `.hold` section that has already ended:
                // there is nothing left of it, and playing on would run past
                // the out-point.
                player.play()
            }
        }
    }

    /// Hold playback on the current frame. See ``playerIsPause``.
    public func pause() { playerIsPause = true }

    /// Continue from exactly where ``pause()`` left off.
    public func resume() { playerIsPause = false }

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
        hasFinishedSection = false

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

        // A fresh load is playing by definition: a hold left over from the
        // previous clip must not silently swallow this one.
        playerIsPause = false

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
    ///
    /// With `.hold`, the section ends instead: pause where it is and signal
    /// once. There is no seek, so the last frame the section presented stays
    /// the last frame (the out-point filter in the buffer checks refuses any
    /// frame the clock reached past it). A `.loop` lap has already sought back
    /// to the start by the time a delegate that pauses asynchronously gets to
    /// run, which is why a sequencer that holds at a boundary needs `.hold`.
    private func completeLap() {
        if actionAtSectionEnd == .hold {
            guard !hasFinishedSection else { return }
            hasFinishedSection = true
            lapSignaled = true
            player.pause()
            delegate?.videoPlayerDidCompleteLoop(identifier: identifier)
            return
        }
        if !lapSignaled {
            lapSignaled = true
            delegate?.videoPlayerDidCompleteLoop(identifier: identifier)
        }
        player.seek(to: sectionStartTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.lapSignaled = false
        }
        // A lap landing while playback is held must not un-hold it.
        if !playerIsPause { player.play() }
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

    /// Tear the current item down: stop, drop the observers, and clear the last
    /// buffer so a render loop cannot present a stray frame from content that is
    /// no longer active. To HOLD the current frame instead, use ``pause()``.
    public func stopVideo(){
        player.pause()
        removeSectionEndObserver()
        lapSignaled = false
        hasFinishedSection = false
        player.replaceCurrentItem(with: nil) // We need to do this or we'll get a stray frame during the renderLoop even when the video isn't active.
        lastPixelBuffer = nil
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObserver = nil
        }
        // Nothing is loaded, so nothing is held. Assigned last, with the item
        // already gone, so the observer above cannot start playback.
        playerIsPause = false
    }

    @available(*, deprecated, message: "`pausePlayer` was never read — this took the same path either way. Use stopVideo() to tear down, or pause() to hold the current frame.")
    public func stopVideo(pausePlayer: Bool) { stopVideo() }
    
    
    // MARK: - Frames

    /// What a frame check found at the item's current time.
    private enum Frame {
        /// Nothing new since the last check.
        case none
        /// A frame to present.
        case new(CVPixelBuffer)
        /// A frame at or past the section's out-point. It belongs to no lap,
        /// so the frame before it stays on screen.
        case pastOutPoint
        /// AVFoundation said a frame was ready, then could not hand it over.
        case failed
    }

    /// The frame for `time`, unless it starts at or after the section's `end`.
    ///
    /// This is what makes an out-point frame-exact: a section `[start, end)`
    /// shows its last frame before `end` and never the frame AT `end`, however
    /// late the boundary observer lands. Before 2.2.0 the clock could reach the
    /// out-point frame before the lap was signalled, so it showed for a frame
    /// (a trimmed clip's next second flashed at every loop). `end` is read by
    /// the caller, on the caller's thread.
    private static func frame(from output: AVPlayerItemVideoOutput, at time: CMTime, end: Double?) -> Frame {
        guard output.hasNewPixelBuffer(forItemTime: time) else { return .none }
        var shownAt = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &shownAt) else {
            return .failed
        }
        if let end, shownAt.isNumeric, shownAt.seconds >= end - outPointTolerance { return .pastOutPoint }
        return .new(buffer)
    }

    // This could be called from the render loop instead of the direct methods below.
    public func indirectBufferCheck() {
        guard let videoOutput else {
            delegate?.VideoPlayerBuffer(pixelBuffer: lastPixelBuffer)
            return
        }
        switch Self.frame(from: videoOutput, at: player.currentTime(), end: section.end) {
        case .new(let pixelBuffer):
            lastPixelBuffer = pixelBuffer
        case .failed:
            mlog.error("indirectBufferCheck: cannot convert pixel buffer")
        case .none, .pastOutPoint:
            break
        }
        delegate?.VideoPlayerBuffer(pixelBuffer: lastPixelBuffer)
    }

    /// Direct buffer check - optimized for synchronous calls from render loop
    /// Returns pixel buffer immediately if available, or the last cached buffer if no new frame.
    /// A frame at or past the section's out-point is never returned: the one
    /// before it is (see ``frame(from:at:end:)``).
    public func directBufferCheck() -> CVPixelBuffer? {
        guard let videoOutput else { return lastPixelBuffer }
        switch Self.frame(from: videoOutput, at: player.currentTime(), end: section.end) {
        case .new(let pixelBuffer):
            lastPixelBuffer = pixelBuffer
        case .failed:
            mlog.error("directBufferCheck [\(self.identifier)]: cannot convert pixel buffer")
        case .none, .pastOutPoint:
            break
        }
        return lastPixelBuffer
    }

    /// Asynchronous buffer check using dedicated processing queue
    /// Calls completion handler with pixel buffer on the processing queue,
    /// or nil when there is no new frame to show.
    public func asyncBufferCheck(completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
        let end = section.end   // read here, where `section` is written, not on the queue
        processingQueue.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let videoOutput = self.videoOutput else {
                completion(nil)
                return
            }
            switch Self.frame(from: videoOutput, at: self.player.currentTime(), end: end) {
            case .new(let pixelBuffer):
                completion(pixelBuffer)
            case .failed:
                mlog.error("asyncBufferCheck [\(self.identifier)]: cannot convert pixel buffer")
                completion(nil)
            case .none, .pastOutPoint:
                completion(nil)
            }
        }
    }
}
