//
//  AspectFitTests.swift
//  MetalToolBox
//
//  The placement math behind EnhancedMetalView.maintainAspectRatio — which
//  was a documented flag that draw(in:) never read until 1.2.0.
//

import XCTest
@testable import MetalToolBox

final class AspectFitTests: XCTestCase {

    func testLandscapeContentInASquareLetterboxes() {
        let rect = EnhancedMetalView.aspectFitRect(content: CGSize(width: 1920, height: 1080),
                                                    in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(rect.width, 1000, accuracy: 0.001)
        XCTAssertEqual(rect.height, 562.5, accuracy: 0.001)
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 218.75, accuracy: 0.001, "centred vertically")
    }

    func testPortraitContentInASquarePillarboxes() {
        let rect = EnhancedMetalView.aspectFitRect(content: CGSize(width: 1080, height: 1920),
                                                    in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(rect.height, 1000, accuracy: 0.001)
        XCTAssertEqual(rect.width, 562.5, accuracy: 0.001)
        XCTAssertEqual(rect.origin.x, 218.75, accuracy: 0.001, "centred horizontally")
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.001)
    }

    func testMatchingAspectFillsTheBounds() {
        let rect = EnhancedMetalView.aspectFitRect(content: CGSize(width: 1920, height: 1080),
                                                    in: CGSize(width: 960, height: 540))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 960, height: 540))
    }

    func testDegenerateContentFallsBackToStretch() {
        let bounds = CGSize(width: 800, height: 600)
        XCTAssertEqual(EnhancedMetalView.aspectFitRect(content: .zero, in: bounds),
                       CGRect(origin: .zero, size: bounds))
    }

    func testAQuarterTurnSwapsTheContentAspect() {
        // A landscape texture shown rotated 90° is a portrait image on screen:
        // in a square it must pillarbox, not letterbox.
        let viewport = EnhancedMetalView.fittedViewport(contentSize: CGSize(width: 1920, height: 1080),
                                                         drawableSize: CGSize(width: 1000, height: 1000),
                                                         rotation: .pi / 2)
        XCTAssertEqual(viewport.height, 1000, accuracy: 0.001)
        XCTAssertEqual(viewport.width, 562.5, accuracy: 0.001)
    }

    func testAHalfTurnKeepsTheContentAspect() {
        let viewport = EnhancedMetalView.fittedViewport(contentSize: CGSize(width: 1920, height: 1080),
                                                         drawableSize: CGSize(width: 1000, height: 1000),
                                                         rotation: .pi)
        XCTAssertEqual(viewport.width, 1000, accuracy: 0.001)
        XCTAssertEqual(viewport.height, 562.5, accuracy: 0.001)
    }
}
