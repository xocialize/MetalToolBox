//
//  EnhancedCaptureScreenRules.swift
//  EnhancedCaptureKit
//
//  The two rules display capture follows when a display changes (2.2.2), kept apart from
//  ScreenCaptureKit so they can be tested without a stream.
//

import Foundation

/// The size a display stream delivers its frames at, in the display's points
/// (`SCDisplay.width` / `.height`, what `SCStreamConfiguration` is given).
struct ScreenStreamSize: Equatable, Sendable, CustomStringConvertible {
    var width: Int
    var height: Int

    var description: String { "\(width)×\(height)" }

    /// The size a running stream must change to after its display changed, or nil when it
    /// keeps the one it has.
    ///
    /// ScreenCaptureKit delivers every frame at the configured size for the stream's whole
    /// life and fits the display into it. A display switched to a mode of another shape (a
    /// 16:10 laptop set to 16:9) kept arriving in the old shape, the new desktop letterboxed
    /// inside it, and a consumer laying out by the frame's size never saw a change. So the
    /// stream follows its display: nil when there is no stream yet (its start reads the
    /// display then), when the display reports no size (mid-reconfiguration), or when the
    /// size is unchanged.
    static func resized(stream current: ScreenStreamSize?, display: ScreenStreamSize) -> ScreenStreamSize? {
        guard let current, display.width > 0, display.height > 0, display != current else { return nil }
        return display
    }
}

/// One screen scan at a time, and never a change missed.
///
/// macOS posts `didChangeScreenParametersNotification` more than once during one display
/// change. A scan that arrived while another ran used to be dropped, so the scan that ran
/// could read the display before the change settled and the last state was never read.
/// Now a request during a scan asks for one more pass when it ends.
struct ScreenScanGate: Sendable {
    private(set) var isScanning = false
    private var scanAgain = false

    /// Whether to start scanning now. While a scan runs: false, and the running scan
    /// passes once more when it finishes.
    mutating func request() -> Bool {
        guard !isScanning else {
            scanAgain = true
            return false
        }
        isScanning = true
        return true
    }

    /// The pass just ended: whether to run another.
    mutating func passEnded() -> Bool {
        if scanAgain {
            scanAgain = false
            return true
        }
        isScanning = false
        return false
    }
}
