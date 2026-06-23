//
//  PlaylistRenderType.swift
//  ZoneLayoutGenerator (vendored from DataModelKit)
//
//  Render type for playlist items, indicating content format.
//

import Foundation

public enum PlaylistRenderType: String, Codable, Sendable, CaseIterable {
    case jpegImage = "image/jpeg"
    case pngImage = "image/png"
    case webpImage = "image/webp"
    case mp4Video = "video/mp4"
    case chunkedVideo = "video/chunked"
    case sessionSet = "sessions/sessionSet"
    case linkSet = "web/uri"
    case other = "other"

    public init(fromAPIValue value: String?) {
        guard let value = value else {
            self = .other
            return
        }

        if let match = PlaylistRenderType(rawValue: value) {
            self = match
        } else {
            EnumLogger.logUnknownValue(value, forEnum: "PlaylistRenderType")
            self = .other
        }
    }

    public var description: String { rawValue }
}
