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

    // MARK: - Permission Checking

    func checkPermissions() {
        mlog.debug("Checking permissions")
        checkCameraPermission()

        #if os(macOS)
        checkScreenRecordingPermission()
        #endif
    }

    private func checkCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            mlog.info("Camera permission: authorized")
            delegate?.permissionManager(self, didResolvePermission: .camera, status: .authorized)

        case .notDetermined:
            mlog.debug("Camera permission not determined — requesting access")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self = self else { return }
                let resolvedStatus: PermissionStatus = granted ? .authorized : .denied
                mlog.info("Camera permission request result: \(String(describing: resolvedStatus))")
                DispatchQueue.main.async {
                    self.delegate?.permissionManager(self, didResolvePermission: .camera, status: resolvedStatus)
                }
            }

        case .denied:
            mlog.error("Camera permission: denied")
            delegate?.permissionManager(self, didResolvePermission: .camera, status: .denied)

        case .restricted:
            mlog.error("Camera permission: restricted")
            delegate?.permissionManager(self, didResolvePermission: .camera, status: .restricted)

        @unknown default:
            mlog.error("Camera permission: unknown — treating as denied")
            delegate?.permissionManager(self, didResolvePermission: .camera, status: .denied)
        }
    }

    #if os(macOS)
    private func checkScreenRecordingPermission() {
        let hasPermission = CGPreflightScreenCaptureAccess()

        if hasPermission {
            mlog.info("Screen recording permission: authorized")
            delegate?.permissionManager(self, didResolvePermission: .screenRecording, status: .authorized)
        } else {
            mlog.info("Screen recording permission: not granted")
            mlog.debug("Requesting screen recording access")
            let _ = CGRequestScreenCaptureAccess()
            // Screen recording permission requires app restart once granted.
            // Report denied — CaptureKitScreen self-guards via CGPreflightScreenCaptureAccess().
            delegate?.permissionManager(self, didResolvePermission: .screenRecording, status: .denied)
        }
    }
    #endif
}
