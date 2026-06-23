//
//  ZoneLayoutDelegate.swift
//  ZoneKit
//
//  Created by Dustin Nielson on 2/27/26.
//

import Foundation

/// Internal typealias for concise references within ZoneKit
public typealias ZoneGeneratorDelegate = ZoneLayoutGeneratorDelegate

public protocol ZoneLayoutGeneratorDelegate: AnyObject {
    func zoneLayoutGenerator(_ generator: ZoneLayoutGenerator, didCalculateLayout layout: ZLGZoneLayout)
}
