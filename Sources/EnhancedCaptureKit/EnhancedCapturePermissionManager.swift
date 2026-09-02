//
//  EnhancedCapturePermissionManager.swift
//  EnhancedCaptureKit
//
//  Created by Dustin Nielson on 2/27/26.
//

import Foundation
import AVFoundation
import OSLog
import LoggingKit
#if os(macOS)
import ScreenCaptureKit
#endif


// MARK: - PermissionManagerDelegate

@available(iOS 16.0, *)
protocol PermissionManagerDelegate: AnyObject {
    func permissionManager(_ manager: PermissionManager, didResolvePermission type: PermissionType, status: PermissionStatus)
}

// MARK: - PermissionManager

@available(macOS 14.0, iOS 16.0, *)
class PermissionManager: @unchecked Sendable {

    private weak var delegate: PermissionManagerDelegate?

    init(delegate: PermissionManagerDelegate) {
        self.delegate = delegate
    }

    // MARK: - Synchronous status

    /// Current status without prompting.
    static func currentStatus(for type: PermissionType) -> PermissionStatus {
        switch type {
        case .camera:
            return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .screenRecording:
            #if os(macOS)
            return CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
            #else
            return .restricted
            #endif
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized:     return .authorized
        case .notDetermined:  return .notDetermined
        case .denied:         return .denied
        case .restricted:     return .restricted
        @unknown default:     return .denied
        }
    }

    // MARK: - Permission Checking

    /// Checks camera (always), microphone (when `includeMicrophone`), and on
    /// macOS screen recording. Each resolution is reported to the delegate;
    /// `.notDetermined` permissions are requested and reported asynchronously
    /// on the main queue.
    func checkPermissions(includeMicrophone: Bool) {
        mlog.debug("Checking permissions (microphone: \(includeMicrophone))")
        checkAVPermission(.camera, mediaType: .video)
        if includeMicrophone {
            checkAVPermission(.microphone, mediaType: .audio)
        }

        #if os(macOS)
        checkScreenRecordingPermission()
        #endif
    }

    /// Checks (and if needed requests) microphone access on its own.
    func checkMicrophonePermission() {
        checkAVPermission(.microphone, mediaType: .audio)
    }

    private func checkAVPermission(_ type: PermissionType, mediaType: AVMediaType) {
        let status = Self.map(AVCaptureDevice.authorizationStatus(for: mediaType))

        switch status {
        case .authorized:
            mlog.info("\(String(describing: type)) permission: authorized")
            delegate?.permissionManager(self, didResolvePermission: type, status: .authorized)

        case .notDetermined:
            mlog.debug("\(String(describing: type)) permission not determined — requesting access")
            AVCaptureDevice.requestAccess(for: mediaType) { [weak self] granted in
                guard let self = self else { return }
                let resolvedStatus: PermissionStatus = granted ? .authorized : .denied
                mlog.info("\(String(describing: type)) permission request result: \(String(describing: resolvedStatus))")
                DispatchQueue.main.async {
                    self.delegate?.permissionManager(self, didResolvePermission: type, status: resolvedStatus)
                }
            }

        case .denied:
            mlog.error("\(String(describing: type)) permission: denied")
            delegate?.permissionManager(self, didResolvePermission: type, status: .denied)

        case .restricted:
            mlog.error("\(String(describing: type)) permission: restricted")
            delegate?.permissionManager(self, didResolvePermission: type, status: .restricted)
        }
    }

    #if os(macOS)
    private func checkScreenRecordingPermission() {
        let hasPermission = CGPreflightScreenCaptureAccess()

        if hasPermission {
            mlog.info("Screen recording permission: authorized")
            delegate?.permissionManager(self, didResolvePermission: .screenRecording, status: .authorized)
        } else {
            mlog.info("Screen recording permission: not granted — requesting")
            // Returns true only if access is already granted; a fresh grant
            // takes effect after the app relaunches. Report the actual answer.
            let granted = CGRequestScreenCaptureAccess()
            delegate?.permissionManager(self, didResolvePermission: .screenRecording, status: granted ? .authorized : .denied)
        }
    }
    #endif
}
