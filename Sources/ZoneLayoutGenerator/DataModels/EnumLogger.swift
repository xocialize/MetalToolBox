//
//  EnumLogger.swift
//  ZoneLayoutGenerator
//
//  Centralized logging for unknown enum values during API data mapping.
//  Helps identify API changes or unexpected values during development.
//
//  Vendored minimal subset of the original DataModelKit utilities.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.xocialize.MetalToolBox", category: "EnumLogger")

public enum EnumLogger {

    /// Log an unknown value that couldn't be mapped to an enum case
    /// - Parameters:
    ///   - value: The string value that couldn't be mapped
    ///   - enumName: The name of the target enum
    ///   - context: Optional additional context (e.g., field path)
    public static func logUnknownValue(
        _ value: String,
        forEnum enumName: String,
        context: String? = nil
    ) {
        if let context {
            logger.warning("Unknown \(enumName, privacy: .public) value: '\(value, privacy: .public)' (context: \(context, privacy: .public)) — defaulting to .other")
        } else {
            logger.warning("Unknown \(enumName, privacy: .public) value: '\(value, privacy: .public)' — defaulting to .other")
        }
    }

    /// Log a batch of unknown values (useful for cartridge processing)
    /// - Parameter unknownValues: Dictionary of [enumName: [unknownValues]]
    public static func logUnknownValuesBatch(_ unknownValues: [String: [String]]) {
        guard !unknownValues.isEmpty else { return }

        logger.warning("Unknown enum values encountered:")
        for (enumName, values) in unknownValues {
            logger.warning("  - \(enumName, privacy: .public): \(values.joined(separator: ", "), privacy: .public)")
        }
    }
}
