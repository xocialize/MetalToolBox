//
//  CaptureKitObservers.swift
//  CaptureKit
//
//  Created by Dustin Nielson on 1/9/26.
//

import Foundation
#if os(macOS)
import Cocoa
#elseif os(iOS)
import UIKit
#endif
import AVFoundation
import OSLog
import LoggingKit


// MARK: - CaptureManager Observers

@available(macOS 10.15, iOS 16.0, *)
extension EnhancedCaptureKit {

    /// Enables notification observers for capture session and device events
    func enableObservers() {
        // Session lifecycle observers
        addSessionStartObserver()
        addSessionStopObserver()

        // Device connection observers
        addDeviceConnectedObserver()
        addDeviceDisconnectedObserver()

        // Screen change observers (macOS only)
        #if os(macOS)
        addScreensDidChangeObserver()
        #endif

        mlog.debug("Notification observers enabled")
    }

    /// Removes all notification observers
    func disableObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        mlog.debug("Notification observers disabled")
    }

    // MARK: - Private Observer Setup Methods

    #if os(macOS)
    private func addScreensDidChangeObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.screensDidUpdate()
            }
        }

        observers.append(observer)
    }
    #endif

    private func addSessionStartObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: nil,
            queue: nil
        ) { _ in
            mlog.debug("Capture session started")
            // Device refresh can be triggered here if needed
        }
        observers.append(observer)
    }

    private func addSessionStopObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStopRunningNotification,
            object: nil,
            queue: nil
        ) { _ in
            mlog.debug("Capture session stopped")
        }
        observers.append(observer)
    }

    private func addDeviceDisconnectedObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            // Delivered on .main; the funnel enters main-actor isolation.
            self?.runOnMainActor { $0.deviceLost(device: device) }
        }
        observers.append(observer)
    }

    private func addDeviceConnectedObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            // Delivered on .main; the funnel enters main-actor isolation.
            self?.runOnMainActor { $0.deviceFound(device: device) }
        }
        observers.append(observer)
    }
}
