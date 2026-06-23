//
//  PlatformAliases.swift
//  DataModelKit
//
//  Cross-platform type aliases for iOS/macOS/tvOS compatibility.
//

import Foundation
import SwiftUI

#if os(iOS) || os(tvOS)
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformView = UIView
public typealias PlatformImage = UIImage
public typealias PlatformHostingController = UIHostingController
#elseif os(macOS)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformView = NSView
public typealias PlatformImage = NSImage
public typealias PlatformHostingController = NSHostingController
#endif
