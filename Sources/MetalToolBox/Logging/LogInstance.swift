//
//  LogInstance.swift
//  MetalToolBox
//
//  Module-level structured-logging instance shared across MetalToolBox.
//
import OSLog
import LoggingKit

// MARK: - Module-level instance

let mlog = ExtendedLog(
    logger: Logger(subsystem: "com.xocialize.MetalToolBox", category: "MetalToolBox"),
    projectTag: "MetalToolBox"
)
