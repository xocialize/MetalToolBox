//
//  ShaderConstants.swift
//  MetalToolBox
//
//  Canonical shader function name constants.
//  Eliminates hardcoded string references across all consuming packages.
//

import Foundation

/// Constants for Metal shader function names used across the MetalToolBox rendering pipeline.
///
/// Use these constants instead of hardcoded strings when creating pipeline states:
/// ```swift
/// let vertexFn = library.makeFunction(name: EnhancedShaderFunction.vertexFullScreen)
/// let fragmentFn = library.makeFunction(name: EnhancedShaderFunction.fragmentDisplay)
/// ```
public enum EnhancedShaderFunction {

    /// Full-screen quad vertex shader.
    /// Maps vertex positions to fill the entire NDC space (-1 to 1).
    /// Used by: `EnhancedMetalView`, single-texture display contexts.
    public static let vertexFullScreen = "fzc_mapTexture"

    /// Rotated full-screen quad vertex shader.
    /// Same as `vertexFullScreen` but applies a 2D rotation matrix using a
    /// rotation angle (radians) passed via buffer(0).
    /// Used by: `EnhancedMetalView` when `displayRotation != 0`.
    public static let vertexRotated = "fzc_mapTextureRotated"

    /// Positioned zone vertex shader.
    /// Takes an `FZCZoneTransform` via buffer(0) to position and scale zones in NDC.
    /// Used by: `ExpoCompositor`, `FlexibleZoneCompositeEngine`, multi-zone compositing.
    public static let vertexPositioned = "fzc_mapTexturePositioned"

    /// Texture sampling fragment shader.
    /// Samples from texture(0) with linear filtering and clamp-to-edge addressing.
    /// Shared by all vertex shaders.
    public static let fragmentDisplay = "fzc_displayTexture"
}
