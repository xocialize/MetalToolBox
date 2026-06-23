//
//  EnhancedShaderLibrary.swift
//  MetalToolBox
//
//  Resolves and vends the Metal shader library used by MetalToolBox rendering components.
//  Supports two initialization paths:
//  1. Explicit injection — app passes its own MTLLibrary (preferred)
//  2. Auto-resolve — tries app default first, falls back to package bundle
//

import Foundation
import Metal
import OSLog

private let logger = Logger(subsystem: "com.xocialize.MetalToolBox", category: "EnhancedShaderLibrary")

/// Resolves the shared Metal shader library for MetalToolBox rendering components.
///
/// **Preferred usage:** The consuming app resolves the library once via
/// `device.makeDefaultLibrary()` and passes it to all components:
///
/// ```swift
/// let library = device.makeDefaultLibrary()!
/// let shaderLib = EnhancedShaderLibrary(library: library)
/// ```
///
/// **Fallback usage:** Components that don't receive an injected library
/// can auto-resolve:
///
/// ```swift
/// let shaderLib = EnhancedShaderLibrary(device: device)
/// ```
public class EnhancedShaderLibrary {

    /// The resolved Metal library containing all MetalToolBox shader functions.
    public let library: MTLLibrary

    // MARK: - Initialization

    /// Creates a shader library wrapper around an explicitly provided MTLLibrary.
    ///
    /// This is the **preferred** initializer. The app resolves the library once
    /// and passes it to all consuming packages via dependency injection.
    ///
    /// - Parameter library: A compiled Metal library containing the FZC shader functions.
    public init(library: MTLLibrary) {
        self.library = library
    }

    /// Auto-resolves the shader library using a fallback chain:
    /// 1. `device.makeDefaultLibrary()` — loads from the app's main bundle
    /// 2. `device.makeDefaultLibrary(bundle: Bundle.module)` — loads from the package bundle
    ///
    /// Returns `nil` if neither source contains the shader library.
    ///
    /// - Parameter device: The Metal device to load the library from.
    public init?(device: MTLDevice) {
        // Try 1: App's main bundle (works when FZCShaders.metal is in the app target)
        if let appLibrary = device.makeDefaultLibrary() {
            // Verify it actually has our shaders
            if appLibrary.makeFunction(name: EnhancedShaderFunction.vertexFullScreen) != nil {
                self.library = appLibrary
                logger.debug("Loaded from app main bundle")
                return
            }
        }

        // Try 2: Package bundle (works in standalone tests / SPM contexts)
        if let packageLibrary = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            self.library = packageLibrary
            logger.debug("Loaded from package bundle")
            return
        }

        logger.fault("Failed to load Metal library from any source")
        return nil
    }

    // MARK: - Shader Function Accessors

    /// Returns the full-screen quad vertex shader function.
    public func vertexFullScreen() -> MTLFunction? {
        library.makeFunction(name: EnhancedShaderFunction.vertexFullScreen)
    }

    /// Returns the rotated full-screen quad vertex shader function.
    public func vertexRotated() -> MTLFunction? {
        library.makeFunction(name: EnhancedShaderFunction.vertexRotated)
    }

    /// Returns the positioned zone vertex shader function.
    public func vertexPositioned() -> MTLFunction? {
        library.makeFunction(name: EnhancedShaderFunction.vertexPositioned)
    }

    /// Returns the texture display fragment shader function.
    public func fragmentDisplay() -> MTLFunction? {
        library.makeFunction(name: EnhancedShaderFunction.fragmentDisplay)
    }
}
