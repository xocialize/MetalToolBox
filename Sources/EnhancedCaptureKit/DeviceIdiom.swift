//
//  DeviceIdiom.swift
//  EnhancedCaptureKit
//
//  Created by Dustin Nielson on 02/27/26.
//

#if os(iOS)
import UIKit

/// Lightweight utility for querying the current device idiom.
///
/// Use this to branch between iPhone and iPad code paths at runtime.
/// All properties must be accessed on the main thread — annotated `@MainActor`
/// so the compiler enforces this rather than relying on the caller.
///
/// ```swift
/// if DeviceIdiom.isPad {
///     // iPad-specific path
/// }
/// ```
public struct DeviceIdiom {

    private init() {}

    /// Returns `true` when running on an iPad.
    @MainActor
    public static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Returns `true` when running on an iPhone.
    @MainActor
    public static var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
}
#endif
