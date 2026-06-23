//
//  ZoneLayoutGenerator.swift
//  ZoneKit
//
//  Created by Dustin Nielson on 2/27/26.
//

//
//  Core layout calculator using a VFL-inspired constraint system for
//  positioning multiple content zones within a render canvas.
//
//  Implements the LogicExample pipeline:
//    1. Parse constraints to determine working canvas
//    2. AspectFit input into working canvas
//    3. If result exceeds renderSafe bounding box → two-stage aspectFit
//    4. Compute zone alias (pixel-based canvasModifier)
//    5. Compute x/y position
//

import Foundation
import CoreGraphics
import OSLog
import LoggingKit

/// Internal typealias for concise references within ZoneKit
public typealias ZLG = ZoneLayoutGenerator

public class ZoneLayoutGenerator: NSObject {

    weak var delegate: ZoneLayoutGeneratorDelegate?

    /// Last-printed debug snapshot per zone identifier.
    /// Only prints when values actually change.
    private var lastDebugSnapshots: [String: ZLGDebugSnapshot] = [:]

    public init(delegate: ZoneLayoutGeneratorDelegate) {
        self.delegate = delegate
        super.init()
    }

    // MARK: - Public API

    public func calculateLayoutFromConfig(config: ZoneLayoutConfiguration) {
        lastDebugSnapshots.removeAll()
        var zoneAliases: [ZLGZoneAlias] = []
        var calculatedZones: [CalculatedZone] = []

        for zoneConfig in config.zoneConfigurations {
            let result = calculateWorkingSpace(
                renderCanvasSize: config.renderCanvasSize,
                canvasOrigin: config.canvasOrigin,
                zoneConfig: zoneConfig,
                zoneAliases: zoneAliases,
                configIdentifier: config.identifier
            )
            if let workingSet = result {
                zoneAliases.append(workingSet.zoneAlias)
                calculatedZones.append(workingSet.calculatedZoneLayout)
            }
        }

        let layout = ZLGZoneLayout(ZoneLayoutGeneratorConfiguration: config, calculatedZones: calculatedZones)
        self.delegate?.zoneLayoutGenerator(self, didCalculateLayout: layout)
    }

    // MARK: - Per-Zone Calculation

    /// Calculates the layout for a single zone following the LogicExample pipeline:
    ///   1. Parse constraints → extract edges, spacing, zone alias references
    ///   2. Resolve zone alias references to pixel offsets
    ///   3. Compute working canvas (renderCanvas - spacing reductions)
    ///   4. AspectFit input into working canvas
    ///   5. If result exceeds renderSafe bounding box → two-stage aspectFit
    ///   6. Compute zone alias canvasModifier
    ///   7. Compute x/y position
    ///   8. Return ZLGWorkingSet
    internal func calculateWorkingSpace(
        renderCanvasSize: CGSize,
        canvasOrigin: CanvasOrigin,
        zoneConfig: ZoneConfiguration,
        zoneAliases: [ZLGZoneAlias],
        configIdentifier: Int64
    ) -> ZLGWorkingSet? {

        let renderCanvas = renderCanvasSize
        // Per LogicExample: H: spacing uses canvas width, V: spacing uses canvas height
        let horizontalDimension = renderCanvas.width
        let verticalDimension = renderCanvas.height

        let originalZoneSize = zoneConfig.size

        // Step 1: Extract H: and V: constraints
        let constraints = zoneConfig.zoneBaseConfig.constraints
        var hConstraintStr: String?
        var vConstraintStr: String?

        for constraint in constraints {
            let trimmed = constraint.trimmingCharacters(in: .whitespaces)
            guard let firstChar = trimmed.first else { continue }
            switch firstChar {
            case "H", "h": hConstraintStr = trimmed
            case "V", "v": vConstraintStr = trimmed
            default: continue
            }
        }

        guard let hStr = hConstraintStr, let vStr = vConstraintStr else {
            mlog.error("Missing horizontal or vertical constraint for \(zoneConfig.zoneBaseConfig.identifier)")
            return nil
        }

        // Step 2: Resolve zone alias references to pixel offsets
        let resolvedH = resolveZoneAliases(in: hStr, aliases: zoneAliases, orientation: .horizontal,
                                           canvasOrigin: canvasOrigin, referenceDimension: horizontalDimension)
        let resolvedV = resolveZoneAliases(in: vStr, aliases: zoneAliases, orientation: .vertical,
                                           canvasOrigin: canvasOrigin, referenceDimension: verticalDimension)

        // Step 3: Parse resolved constraint strings
        guard let hParsed = parseConstraintString(resolvedH),
              let vParsed = parseConstraintString(resolvedV) else {
            mlog.error("Failed to parse constraints for \(zoneConfig.zoneBaseConfig.identifier)")
            return nil
        }

        // Step 4: Calculate working canvas by subtracting spacing from render canvas
        let hReduction = calculateSpacingReduction(
            leading: hParsed.leadingEdge, trailing: hParsed.trailingEdge,
            referenceDimension: horizontalDimension
        )
        let vReduction = calculateSpacingReduction(
            leading: vParsed.leadingEdge, trailing: vParsed.trailingEdge,
            referenceDimension: verticalDimension
        )

        let workingCanvas = CGSize(
            width: renderCanvas.width - hReduction,
            height: renderCanvas.height - vReduction
        )

        // Step 5+6: AspectFit with automatic renderSafe detection
        // Try a direct aspectFit first. If the result exceeds the renderSafe bounding
        // box, re-fit using the two-stage renderSafe path. This replaces orientation
        // enum comparison with a concrete geometric check.
        guard let directFit = aspectFit(container: workingCanvas, item: originalZoneSize) else {
            mlog.error("AspectFit failed for \(zoneConfig.zoneBaseConfig.identifier)")
            return nil
        }

        let fitResult: ZLGAspectFitComputedSize

        // Compute the renderSafe bounding box from the configured aspect ratio
        let safeRatio = zoneConfig.zoneBaseConfig.renderSafeAspectRatio
        if let safeBounds = aspectFit(
            container: renderCanvas,
            item: CGSize(width: safeRatio.AspectWidth, height: safeRatio.AspectHeight)
        ) {
            // If the direct fit exceeds the safe bounding box in either dimension,
            // the renderSafeAspectRatio is required — re-fit into the safe bounds
            let needsRenderSafe = directFit.width > safeBounds.width + 0.01
                                || directFit.height > safeBounds.height + 0.01

            if needsRenderSafe {
                let safeWorkingSpace = CGSize(width: safeBounds.width, height: safeBounds.height)
                guard let safeFit = aspectFit(container: safeWorkingSpace, item: originalZoneSize) else {
                    mlog.error("RenderSafe aspectFit failed for \(zoneConfig.zoneBaseConfig.identifier)")
                    return nil
                }
                fitResult = safeFit
            } else {
                fitResult = directFit
            }
        } else {
            fitResult = directFit
        }

        // Step 7: Compute zone alias canvasModifier
        // For zones with spacing, include the spacing in the alias footprint
        let hSpacingPixels = hReduction
        let vSpacingPixels = vReduction
        let aliasWidth = fitResult.width + hSpacingPixels
        let aliasHeight = fitResult.height + vSpacingPixels

        let zoneAlias = ZLGZoneAlias(
            zone: zoneConfig.zoneBaseConfig.identifier,
            canvasModifier: CGSize(width: aliasWidth, height: aliasHeight)
        )

        // Step 8: Compute x/y position
        let xPosition = calculateXPosition(
            constraint: hParsed,
            renderCanvas: renderCanvas,
            aspectFitWidth: fitResult.width,
            referenceDimension: horizontalDimension
        )

        let yPosition = calculateYPosition(
            constraint: vParsed,
            renderCanvas: renderCanvas,
            aspectFitHeight: fitResult.height,
            referenceDimension: verticalDimension,
            canvasOrigin: canvasOrigin
        )

        let calculatedZone = CalculatedZone(
            zoneIdentifier: zoneConfig.zoneBaseConfig.identifier,
            identifier: configIdentifier,
            xPosition: xPosition,
            yPosition: yPosition,
            calculatedScale: fitResult.scale,
            calculatedWidth: fitResult.width,
            calculatedHeight: fitResult.height
        )

        // DEBUG: Only print when values change for this zone
        let usedRenderSafe = (fitResult.width != directFit.width || fitResult.height != directFit.height)
        let snapshot = ZLGDebugSnapshot(
            zoneIdentifier: zoneConfig.zoneBaseConfig.identifier,
            inputWidth: originalZoneSize.width,
            inputHeight: originalZoneSize.height,
            renderCanvasWidth: renderCanvas.width,
            renderCanvasHeight: renderCanvas.height,
            hConstraint: hStr,
            resolvedH: resolvedH,
            vConstraint: vStr,
            resolvedV: resolvedV,
            workingCanvasWidth: workingCanvas.width,
            workingCanvasHeight: workingCanvas.height,
            renderSafeApplied: usedRenderSafe,
            fitWidth: fitResult.width,
            fitHeight: fitResult.height,
            fitScale: fitResult.scale,
            xPosition: xPosition,
            yPosition: yPosition,
            aliasZone: zoneAlias.zone,
            aliasModifierWidth: zoneAlias.canvasModifier.width,
            aliasModifierHeight: zoneAlias.canvasModifier.height
        )

        return ZLGWorkingSet(calculatedZoneLayout: calculatedZone, zoneAlias: zoneAlias)
    }

    // MARK: - Constraint Parsing

    /// Resolve zone alias references in a constraint string.
    /// Replaces `[zoneN]` with a pixel offset derived from the alias's canvasModifier.
    /// For `V:[zone3]-2-[zone2]`, zone2's canvasModifier.height becomes the pixel offset.
    private func resolveZoneAliases(
        in constraint: String,
        aliases: [ZLGZoneAlias],
        orientation: ZLGConstraintOrientation,
        canvasOrigin: CanvasOrigin,
        referenceDimension: CGFloat
    ) -> String {
        var result = constraint

        for alias in aliases {
            guard result.contains("[\(alias.zone)]") else { continue }

            // Get the pixel dimension from the alias that matches this constraint orientation
            let aliasPixels: CGFloat
            switch orientation {
            case .horizontal:
                aliasPixels = alias.canvasModifier.width
            case .vertical:
                aliasPixels = alias.canvasModifier.height
            }

            // Convert pixel offset to a percentage of referenceDimension so the existing
            // spacing parser can handle it uniformly
            let aliasPercentage = (aliasPixels / referenceDimension) * 100.0

            // Check for pattern: -X-[zoneN] (spacing before zone alias)
            let spacingPattern = "-((?:[0-9]*\\.)?[0-9]+)-\\[\(alias.zone)\\]"
            if let spacingRegex = try? NSRegularExpression(pattern: spacingPattern, options: []),
               let match = spacingRegex.firstMatch(in: result, options: [], range: NSRange(result.startIndex..., in: result)) {

                var precedingSpacing: CGFloat = 0.0
                if match.numberOfRanges > 1 {
                    let spacingRange = match.range(at: 1)
                    if spacingRange.location != NSNotFound,
                       let range = Range(spacingRange, in: result) {
                        if let spacingValue = Double(result[range]) {
                            precedingSpacing = CGFloat(spacingValue)
                        }
                    }
                }

                let totalPercentage = precedingSpacing + aliasPercentage
                let fullMatchRange = Range(match.range, in: result)!

                result = result.replacingOccurrences(
                    of: String(result[fullMatchRange]),
                    with: String(format: "-%.4f", totalPercentage)
                )
            } else {
                // Simple replacement: [zoneN] → percentage value
                result = result.replacingOccurrences(
                    of: "[\(alias.zone)]",
                    with: String(format: "%.4f", aliasPercentage)
                )
            }
        }

        return result
    }

    /// Parse a single constraint string (H: or V:) into its components.
    private func parseConstraintString(_ constraint: String) -> ParsedConstraintComponent? {
        guard constraint.count >= 2,
              let firstChar = constraint.first,
              let orientation = ZLGConstraintOrientation(prefix: firstChar) else {
            return nil
        }

        let bodyStartIndex = constraint.index(constraint.startIndex, offsetBy: 2)
        let body = String(constraint[bodyStartIndex...])

        var zoneIdentifier = ""

        var currentIndex = body.startIndex
        var tokens: [String] = []
        var currentToken = ""

        while currentIndex < body.endIndex {
            let char = body[currentIndex]

            if char == "|" {
                if !currentToken.isEmpty { tokens.append(currentToken); currentToken = "" }
                tokens.append("|")
            } else if char == "[" {
                if !currentToken.isEmpty { tokens.append(currentToken); currentToken = "" }
                var bracketContent = "["
                currentIndex = body.index(after: currentIndex)
                while currentIndex < body.endIndex && body[currentIndex] != "]" {
                    bracketContent.append(body[currentIndex])
                    currentIndex = body.index(after: currentIndex)
                }
                if currentIndex < body.endIndex { bracketContent.append("]") }
                tokens.append(bracketContent)
            } else if char == "-" {
                currentToken.append(char)
            } else if char.isNumber || char == "." {
                currentToken.append(char)
            } else {
                if !currentToken.isEmpty { tokens.append(currentToken); currentToken = "" }
            }

            currentIndex = body.index(after: currentIndex)
        }

        if !currentToken.isEmpty { tokens.append(currentToken) }

        var foundZone = false
        var beforeZone = true
        var leadingSpacing: CGFloat? = nil
        var trailingSpacing: CGFloat? = nil
        var hasLeadingEdge = false
        var hasTrailingEdge = false

        for token in tokens {
            if token == "|" {
                if !foundZone { hasLeadingEdge = true } else { hasTrailingEdge = true }
            } else if token.hasPrefix("[") {
                foundZone = true
                beforeZone = false
                let bracketContent = token.dropFirst().dropLast()
                zoneIdentifier = String(bracketContent)
            } else if token.contains("-") {
                let numericPart = token.replacingOccurrences(of: "-", with: "")
                if let value = Double(numericPart) {
                    if beforeZone {
                        leadingSpacing = CGFloat(value)
                    } else {
                        trailingSpacing = CGFloat(value)
                    }
                }
                // No default fallback — bare `-` without a number is treated as 0
            }
        }

        let leadingEdge = EdgeConstraint(
            isCanvasEdge: hasLeadingEdge || (!hasLeadingEdge && !hasTrailingEdge) || (leadingSpacing == nil && !foundZone),
            spacingPercentage: leadingSpacing
        )

        let trailingEdge = EdgeConstraint(
            isCanvasEdge: hasTrailingEdge || (!hasLeadingEdge && !hasTrailingEdge),
            spacingPercentage: trailingSpacing
        )

        guard !zoneIdentifier.isEmpty else { return nil }

        return ParsedConstraintComponent(
            orientation: orientation,
            leadingEdge: leadingEdge,
            trailingEdge: trailingEdge,
            zoneIdentifier: zoneIdentifier
        )
    }

    private func calculateSpacingReduction(
        leading: EdgeConstraint,
        trailing: EdgeConstraint,
        referenceDimension: CGFloat
    ) -> CGFloat {
        var reduction: CGFloat = 0

        if let leadingSpacing = leading.spacingPercentage {
            reduction += referenceDimension * (leadingSpacing / 100.0)
        }

        if let trailingSpacing = trailing.spacingPercentage {
            reduction += referenceDimension * (trailingSpacing / 100.0)
        }

        return reduction
    }

    // MARK: - Position Calculators

    private func calculateXPosition(
        constraint: ParsedConstraintComponent,
        renderCanvas: CGSize,
        aspectFitWidth: CGFloat,
        referenceDimension: CGFloat
    ) -> CGFloat {
        let leadingEdge = constraint.leadingEdge
        let trailingEdge = constraint.trailingEdge

        // Both edges, no spacing → center
        if leadingEdge.isCanvasEdge && trailingEdge.isCanvasEdge &&
           leadingEdge.spacingPercentage == nil && trailingEdge.spacingPercentage == nil {
            return (renderCanvas.width - aspectFitWidth) / 2.0
        }

        // Leading edge with spacing → offset from left
        if let leadingSpacing = leadingEdge.spacingPercentage {
            return referenceDimension * (leadingSpacing / 100.0)
        }

        // Trailing edge with spacing → offset from right
        if let trailingSpacing = trailingEdge.spacingPercentage, trailingEdge.isCanvasEdge {
            let spacing = referenceDimension * (trailingSpacing / 100.0)
            return renderCanvas.width - aspectFitWidth - spacing
        }

        // Trailing edge only, no spacing → flush right
        if trailingEdge.isCanvasEdge && !leadingEdge.isCanvasEdge && leadingEdge.spacingPercentage == nil {
            return renderCanvas.width - aspectFitWidth
        }

        // Default: center
        return (renderCanvas.width - aspectFitWidth) / 2.0
    }

    private func calculateYPosition(
        constraint: ParsedConstraintComponent,
        renderCanvas: CGSize,
        aspectFitHeight: CGFloat,
        referenceDimension: CGFloat,
        canvasOrigin: CanvasOrigin
    ) -> CGFloat {
        let leadingEdge = constraint.leadingEdge
        let trailingEdge = constraint.trailingEdge
        let isTopLeftOrigin = (canvasOrigin == .topLeft || canvasOrigin == .topRight)

        // Both edges, no spacing → center
        if leadingEdge.isCanvasEdge && trailingEdge.isCanvasEdge &&
           leadingEdge.spacingPercentage == nil && trailingEdge.spacingPercentage == nil {
            return (renderCanvas.height - aspectFitHeight) / 2.0
        }

        // Trailing edge (bottom in topLeft) with spacing
        if let trailingSpacing = trailingEdge.spacingPercentage, trailingEdge.isCanvasEdge {
            let spacing = referenceDimension * (trailingSpacing / 100.0)
            if isTopLeftOrigin {
                return renderCanvas.height - aspectFitHeight - spacing
            } else {
                return spacing
            }
        }

        // Leading edge (top in topLeft) with spacing
        if let leadingSpacing = leadingEdge.spacingPercentage {
            let spacing = referenceDimension * (leadingSpacing / 100.0)
            if isTopLeftOrigin {
                return spacing
            } else {
                return renderCanvas.height - aspectFitHeight - spacing
            }
        }

        // Trailing edge only, no spacing → flush bottom (topLeft) or flush top (bottomLeft)
        if trailingEdge.isCanvasEdge && !leadingEdge.isCanvasEdge && leadingEdge.spacingPercentage == nil {
            if isTopLeftOrigin {
                return renderCanvas.height - aspectFitHeight
            } else {
                return 0.0
            }
        }

        // Default: center
        return (renderCanvas.height - aspectFitHeight) / 2.0
    }

    // MARK: - AspectFit

    internal func aspectFit(container: CGSize, item: CGSize) -> ZLGAspectFitComputedSize? {
        if item.width <= 0 || item.height <= 0 || container.width <= 0 || container.height <= 0 {
            return nil
        }

        let widthRatio = container.width / item.width
        let heightRatio = container.height / item.height
        let scale = min(widthRatio, heightRatio)

        let fittedWidth = item.width * scale
        let fittedHeight = item.height * scale

        return ZLGAspectFitComputedSize(width: fittedWidth, height: fittedHeight, scale: scale)
    }
}

// MARK: - Internal Types

extension ZoneLayoutGenerator {

    /// Captures all values from the ZLG debug block for change detection.
    /// Equatable synthesis enables cheap comparison to suppress duplicate output.
    internal struct ZLGDebugSnapshot: Equatable {
        let zoneIdentifier: String
        let inputWidth: CGFloat
        let inputHeight: CGFloat
        let renderCanvasWidth: CGFloat
        let renderCanvasHeight: CGFloat
        let hConstraint: String
        let resolvedH: String
        let vConstraint: String
        let resolvedV: String
        let workingCanvasWidth: CGFloat
        let workingCanvasHeight: CGFloat
        let renderSafeApplied: Bool
        let fitWidth: CGFloat
        let fitHeight: CGFloat
        let fitScale: CGFloat
        let xPosition: CGFloat
        let yPosition: CGFloat
        let aliasZone: String
        let aliasModifierWidth: CGFloat
        let aliasModifierHeight: CGFloat
    }

    /// Zone alias using the LogicExample model: stores the total pixel footprint
    /// (fitted size + associated spacing) so downstream zones can reference it directly.
    internal struct ZLGZoneAlias {
        let zone: String
        let canvasModifier: CGSize
    }

    /// Return type from per-zone calculation, pairing the layout result with its alias.
    internal struct ZLGWorkingSet {
        let calculatedZoneLayout: CalculatedZone
        let zoneAlias: ZLGZoneAlias
    }

    internal struct EdgeConstraint {
        let isCanvasEdge: Bool
        let spacingPercentage: CGFloat?
    }

    internal struct ParsedConstraintComponent {
        let orientation: ZLGConstraintOrientation
        let leadingEdge: EdgeConstraint
        let trailingEdge: EdgeConstraint
        let zoneIdentifier: String
    }

    internal struct ZLGAspectFitComputedSize {
        let width: CGFloat
        let height: CGFloat
        let scale: CGFloat
    }

    internal enum ZLGConstraintOrientation: String, CaseIterable, Equatable, Hashable {
        case horizontal = "H"
        case vertical = "V"

        public init?(prefix: Character) {
            switch prefix {
            case "H", "h": self = .horizontal
            case "V", "v": self = .vertical
            default: return nil
            }
        }
    }

    /// State of layout calculation
    public enum ZLGLayoutState: Sendable, Equatable {
        case idle
        case calculating
        case ready
        case error(String)

        public static func == (lhs: ZLGLayoutState, rhs: ZLGLayoutState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.calculating, .calculating): return true
            case (.ready, .ready): return true
            case (.error(let l), .error(let r)): return l == r
            default: return false
            }
        }
    }
}
