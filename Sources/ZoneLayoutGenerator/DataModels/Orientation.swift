//
//  Orientation.swift
//  ZoneLayoutGenerator (vendored from DataModelKit)
//
//  Screen orientation determined by dimensions.
//

import Foundation
import CoreGraphics

public enum Orientation: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case portrait = "portrait"
    case landscape = "landscape"
    case square = "square"
    case other = "other"

    /// Determines orientation based on CGSize dimensions
    public static func determine(size: CGSize) -> Orientation {
        if size.width > size.height {
            return .landscape
        } else if size.height > size.width {
            return .portrait
        } else if size.width > 0 {
            return .square
        } else {
            return .other
        }
    }

    /// Pixel dimensions for standard orientations (HD default)
    public var dimensions: (width: Int, height: Int) {
        switch self {
        case .portrait: return (1080, 1920)
        case .landscape: return (1920, 1080)
        case .square: return (1080, 1080)
        case .other: return (1920, 1080)
        }
    }

    public init(fromAPIValue value: String?) {
        guard let value = value else {
            self = .other
            return
        }

        if let match = Orientation(rawValue: value) {
            self = match
        } else {
            EnumLogger.logUnknownValue(value, forEnum: "Orientation")
            self = .other
        }
    }

    public var description: String { rawValue }
}
