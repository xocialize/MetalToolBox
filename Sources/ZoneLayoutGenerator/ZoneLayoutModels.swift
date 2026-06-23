//
//  ZoneLayoutGeneratorModels.swift
//  FlexibleZoneLayoutGenerator
//
//  Created by Dustin Nielson on 1/25/26.
//

import Foundation
import CoreGraphics

public struct ZLGZoneLayout {
    public let zoneLayoutConfiguration: ZoneLayoutConfiguration
    public let calculatedZones: [CalculatedZone]

    public init(ZoneLayoutGeneratorConfiguration: ZoneLayoutConfiguration, calculatedZones: [CalculatedZone]) {
        self.zoneLayoutConfiguration = ZoneLayoutGeneratorConfiguration
        self.calculatedZones = calculatedZones
    }
}

public struct ZoneConfigOptions {
    public let identifier: String
    public let zIndex: Int
    public let orientation: Orientation
    public let renderSafeAspectRatio: (AspectWidth: CGFloat, AspectHeight: CGFloat)
    public let constraints: [String]

    public init(
        identifier: String,
        zIndex: Int,
        orientation: Orientation,
        renderSafeAspectRatio: (AspectWidth: CGFloat, AspectHeight: CGFloat),
        constraints: [String]
    ) {
        self.identifier = identifier
        self.zIndex = zIndex
        self.orientation = orientation
        self.renderSafeAspectRatio = renderSafeAspectRatio
        self.constraints = constraints
    }
}

public struct ZoneConfiguration {
    public let zoneBaseConfig: ZoneConfigOptions
    public let size: CGSize
    public let resolvedOrientation: Orientation?

    public init(zoneBaseConfig: ZoneConfigOptions, size: CGSize) {
        self.zoneBaseConfig = zoneBaseConfig
        self.size = size
        self.resolvedOrientation = Orientation.determine(size: size)
    }
}

public enum CanvasOrigin {
    case topLeft, bottomLeft, topRight, bottomRight
}

public struct ZoneLayoutConfiguration {
    public var name: String
    public var identifier: Int64
    public var renderCanvasSize: CGSize
    public var calculatedOrientation: Orientation?
    public var canvasOrigin: CanvasOrigin
    public var zoneConfigurations: [ZoneConfiguration]

    public init(
        name: String,
        identifier: Int64,
        renderCanvasSize: CGSize,
        canvasOrigin: CanvasOrigin,
        zoneConfigurations: [ZoneConfiguration]
    ) {
        self.name = name
        self.identifier = identifier
        self.renderCanvasSize = renderCanvasSize
        self.calculatedOrientation = Orientation.determine(size: renderCanvasSize)
        self.canvasOrigin = canvasOrigin
        self.zoneConfigurations = zoneConfigurations
    }
}

public struct CalculatedZone {
    public let zoneIdentifier: String
    public let identifier: Int64
    public let xPosition: CGFloat
    public let yPosition: CGFloat
    public let calculatedScale: CGFloat

    /// The aspect-fit destination width in canvas pixels.
    /// This is the MPS destination width — the actual pixel size the zone occupies on the canvas.
    public let calculatedWidth: CGFloat

    /// The aspect-fit destination height in canvas pixels.
    /// This is the MPS destination height — the actual pixel size the zone occupies on the canvas.
    public let calculatedHeight: CGFloat

    public init(
        zoneIdentifier: String,
        identifier: Int64,
        xPosition: CGFloat,
        yPosition: CGFloat,
        calculatedScale: CGFloat,
        calculatedWidth: CGFloat,
        calculatedHeight: CGFloat
    ) {
        self.zoneIdentifier = zoneIdentifier
        self.identifier = identifier
        self.xPosition = xPosition
        self.yPosition = yPosition
        self.calculatedScale = calculatedScale
        self.calculatedWidth = calculatedWidth
        self.calculatedHeight = calculatedHeight
    }
}
