//
//  EnhancedCaptureObservers.swift
//  EnhancedCaptureKit
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


// MARK: - EnhancedCaptureKit Observers

@available(macOS 10.15, iOS 16.0, *)
extension EnhancedCaptureKit {

    /// Enables notification observers for capture session and device events
    func enableObservers() {
        // Session lifecycle observers
        addSessionStartObserver()
        addSessionStopObserver()
        addRuntimeErrorObserver()

        // Device connection observers
        addDeviceConnectedObserver()
        addDeviceDisconnectedObserver()

        // Screen change observers (macOS only)
        #if os(macOS)
        addScreensDidChangeObserver()
        #endif

        // Interruptions (iOS / iPadOS only: backgrounding, other apps, system pressure)
        #if os(iOS)
        addInterruptionObservers()
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
            object: self,
            queue: nil
        ) { _ in
            mlog.debug("Capture session started")
        }
        observers.append(observer)
    }

    private func addSessionStopObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStopRunningNotification,
            object: self,
            queue: nil
        ) { _ in
            mlog.debug("Capture session stopped")
        }
        observers.append(observer)
    }

    private func addRuntimeErrorObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: self,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let boxed = UncheckedSendable(error)
            self?.runOnMainActor { $0.handleRuntimeError(boxed.value) }
        }
        observers.append(observer)
    }

    #if os(iOS)
    private func addInterruptionObservers() {
        let began = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: self,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            self?.runOnMainActor { $0.handleSessionInterruption(.began(reason: rawReason.map(EnhancedCaptureInterruptionReason.init(rawAVReason:)))) }
        }
        observers.append(began)

        let ended = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.runOnMainActor { $0.handleSessionInterruption(.ended) }
        }
        observers.append(ended)
    }
    #endif

    private func addDeviceDisconnectedObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            // Delivered on .main; the funnel enters main-actor isolation.
            let boxed = UncheckedSendable(device)
            self?.runOnMainActor { $0.deviceLost(device: boxed.value) }
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
            let boxed = UncheckedSendable(device)
            self?.runOnMainActor { $0.deviceFound(device: boxed.value) }
        }
        observers.append(observer)
    }
}

// MARK: - Interruption reason mapping

#if os(iOS)
extension EnhancedCaptureInterruptionReason {
    /// Maps the raw `AVCaptureSession.InterruptionReason` value carried in the
    /// notification's `AVCaptureSessionInterruptionReasonKey`.
    init(rawAVReason raw: Int) {
        switch AVCaptureSession.InterruptionReason(rawValue: raw) {
        case .videoDeviceNotAvailableInBackground:              self = .videoDeviceNotAvailableInBackground
        case .audioDeviceInUseByAnotherClient:                  self = .audioDeviceInUseByAnotherClient
        case .videoDeviceInUseByAnotherClient:                  self = .videoDeviceInUseByAnotherClient
        case .videoDeviceNotAvailableWithMultipleForegroundApps: self = .videoDeviceNotAvailableWithMultipleForegroundApps
        case .videoDeviceNotAvailableDueToSystemPressure:       self = .videoDeviceNotAvailableDueToSystemPressure
        default:                                                self = .unknown(raw)
        }
    }
}
#endif
