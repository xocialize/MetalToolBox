//
//  RealAssetFixture.swift
//  MetalToolBox
//
//  The local Marquee test-show clip the real-asset tests play (VP26 "Video
//  Slide 15s", 14.7 s). It lives in the Marquee projects folder, which has been
//  on more than one volume, so look in each; the tests skip when none has it.
//

import Foundation

enum RealAssetFixture {
    static let clip: URL = {
        let name = "MarqueeProjects/VP26/e0807ae4-b779-4e3d-8cf9-bab12ec5bbe0.mp4"
        let candidates = ["/Volumes/MVSCollective", "/Volumes/Satechi"].map {
            URL(fileURLWithPath: $0).appendingPathComponent(name)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }()
}
