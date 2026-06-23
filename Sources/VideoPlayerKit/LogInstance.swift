//
//  LogInstance.swift
//  VideoPlayerKit
//
//  Module-level structured-logging instance.
//
import OSLog
import LoggingKit

let mlog = ExtendedLog(
    logger: Logger(subsystem: "com.xocialize.MetalToolBox", category: "VideoPlayerKit"),
    projectTag: "VideoPlayerKit"
)
