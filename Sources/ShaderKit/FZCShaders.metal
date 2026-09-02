//
//  FZCShaders.metal
//  MetalToolBox
//
//  Canonical Metal shader source for the MetalToolBox rendering pipeline.
//  Components receive the compiled MTLLibrary via dependency injection,
//  or auto-resolve it from the package bundle.
//
//  Shader Functions:
//  - fzc_mapTexture:           Full-screen quad vertex shader
//  - fzc_mapTextureRotated:    Full-screen quad with rotation (uses rotation angle buffer)
//  - fzc_mapTexturePositioned: Positioned zone vertex shader (uses FZCZoneTransform)
//  - fzc_displayTexture:       Texture sampling fragment shader
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniform Structures

/// Transform data for positioning zones in render space
struct FZCZoneTransform {
    float2 position;      // Position in normalized device coordinates
    float2 size;          // Size in normalized device coordinates
};

// MARK: - Vertex Output Structure

struct TextureMappingVertex {
    float4 position [[position]];
    float2 textureCoordinate;
};

// MARK: - Vertex Shader (Full-Screen)

/// Vertex shader: Full-screen quad
/// Maps texture coordinates to screen space for rendering
vertex TextureMappingVertex fzc_mapTexture(unsigned int vertex_id [[vertex_id]]) {
    // Define quad vertices in clip space (-1 to 1)
    float4x4 positions = float4x4(
        float4(-1.0, -1.0, 0.0, 1.0),  // bottom-left
        float4( 1.0, -1.0, 0.0, 1.0),  // bottom-right
        float4(-1.0,  1.0, 0.0, 1.0),  // top-left
        float4( 1.0,  1.0, 0.0, 1.0)   // top-right
    );

    // Define texture coordinates (Y-flipped for Metal coordinate system)
    float4x2 texCoords = float4x2(
        float2(0.0, 1.0),  // bottom-left (flipped Y for Metal)
        float2(1.0, 1.0),  // bottom-right
        float2(0.0, 0.0),  // top-left
        float2(1.0, 0.0)   // top-right
    );

    TextureMappingVertex out;
    out.position = positions[vertex_id];
    out.textureCoordinate = texCoords[vertex_id];
    return out;
}

// MARK: - Vertex Shader (Rotated Full-Screen)

/// Vertex shader: Full-screen quad with 2D rotation
/// Same as fzc_mapTexture but applies a rotation matrix to clip-space positions.
/// Used by EnhancedMetalView when displayRotation != 0 (e.g., external display
/// showing landscape content on a portrait-mounted screen).
vertex TextureMappingVertex fzc_mapTextureRotated(
    unsigned int vertex_id [[vertex_id]],
    constant float& rotationAngle [[buffer(0)]]
) {
    // Same quad vertices as fzc_mapTexture
    float4x4 positions = float4x4(
        float4(-1.0, -1.0, 0.0, 1.0),  // bottom-left
        float4( 1.0, -1.0, 0.0, 1.0),  // bottom-right
        float4(-1.0,  1.0, 0.0, 1.0),  // top-left
        float4( 1.0,  1.0, 0.0, 1.0)   // top-right
    );

    // Same texture coordinates (Y-flipped for Metal)
    float4x2 texCoords = float4x2(
        float2(0.0, 1.0),  // bottom-left
        float2(1.0, 1.0),  // bottom-right
        float2(0.0, 0.0),  // top-left
        float2(1.0, 0.0)   // top-right
    );

    // Apply 2D rotation matrix to clip-space position
    float2 pos = positions[vertex_id].xy;
    float c = cos(rotationAngle);
    float s = sin(rotationAngle);
    float2 rotated = float2(
        pos.x * c - pos.y * s,
        pos.x * s + pos.y * c
    );

    TextureMappingVertex out;
    out.position = float4(rotated, 0.0, 1.0);
    out.textureCoordinate = texCoords[vertex_id];
    return out;
}

// MARK: - Vertex Shader (Positioned Zone)

/// Vertex shader: Positioned quad for zone rendering
/// Uses transform uniform to position zone correctly in render space
vertex TextureMappingVertex fzc_mapTexturePositioned(
    unsigned int vertex_id [[vertex_id]],
    constant FZCZoneTransform& transform [[buffer(0)]]
) {
    // Define unit quad vertices (0 to 1)
    float4x2 unitPositions = float4x2(
        float2(0.0, 0.0),  // bottom-left
        float2(1.0, 0.0),  // bottom-right
        float2(0.0, 1.0),  // top-left
        float2(1.0, 1.0)   // top-right
    );

    // Define texture coordinates (Y-flipped for Metal coordinate system)
    float4x2 texCoords = float4x2(
        float2(0.0, 1.0),  // bottom-left (flipped Y for Metal)
        float2(1.0, 1.0),  // bottom-right
        float2(0.0, 0.0),  // top-left
        float2(1.0, 0.0)   // top-right
    );

    // Transform unit quad to zone position and size
    float2 localPos = unitPositions[vertex_id];
    float2 worldPos = transform.position + (localPos * transform.size);

    // Convert from pixel coordinates to normalized device coordinates (-1 to 1)
    // Note: worldPos is already in NDC from Swift side

    TextureMappingVertex out;
    out.position = float4(worldPos.x, worldPos.y, 0.0, 1.0);
    out.textureCoordinate = texCoords[vertex_id];
    return out;
}

// MARK: - Fragment Shader

/// Fragment shader: Simple texture sampling with alpha blending support
/// Samples the input texture and outputs the color
fragment half4 fzc_displayTexture(
    TextureMappingVertex in [[stage_in]],
    texture2d<half> texture [[texture(0)]]
) {
    // Linear filtering with clamp-to-edge addressing
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return texture.sample(s, in.textureCoordinate);
}

// MARK: - Compute: biplanar YCbCr → BGRA

/// How to interpret a biplanar YCbCr (420v / 420f) frame.
struct FZCYCbCrConversion {
    uint isFullRange;   // 1: 420f (Y 0…255, CbCr centred on 128); 0: 420v (Y 16…235, CbCr 16…240)
    uint matrix;        // 0: BT.709, 1: BT.601, 2: BT.2020 (non-constant luminance)
};

/// Converts a camera's native biplanar 4:2:0 YCbCr frame to BGRA. Plane 0 is
/// bound as r8Unorm (luma), plane 1 as rg8Unorm (interleaved Cb, Cr at half
/// resolution); one thread per output pixel, nearest chroma sample.
kernel void fzc_ycbcrBiPlanarToBGRA(
    texture2d<float, access::read>  lumaTexture   [[texture(0)]],
    texture2d<float, access::read>  chromaTexture [[texture(1)]],
    texture2d<half,  access::write> outTexture    [[texture(2)]],
    constant FZCYCbCrConversion&    conversion    [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }

    float  y    = lumaTexture.read(gid).r;
    float2 cbcr = chromaTexture.read(gid / 2).rg;

    float Y, Cb, Cr;
    if (conversion.isFullRange != 0) {
        Y  = y;
        Cb = cbcr.x - 0.5;
        Cr = cbcr.y - 0.5;
    } else {
        Y  = (y      - 16.0  / 255.0) * (255.0 / 219.0);
        Cb = (cbcr.x - 128.0 / 255.0) * (255.0 / 224.0);
        Cr = (cbcr.y - 128.0 / 255.0) * (255.0 / 224.0);
    }

    float3 rgb;
    switch (conversion.matrix) {
        case 1:  // BT.601
            rgb = float3(Y + 1.402000 * Cr,
                         Y - 0.344136 * Cb - 0.714136 * Cr,
                         Y + 1.772000 * Cb);
            break;
        case 2:  // BT.2020
            rgb = float3(Y + 1.474600 * Cr,
                         Y - 0.164553 * Cb - 0.571353 * Cr,
                         Y + 1.881400 * Cb);
            break;
        default: // BT.709
            rgb = float3(Y + 1.574800 * Cr,
                         Y - 0.187324 * Cb - 0.468124 * Cr,
                         Y + 1.855600 * Cb);
            break;
    }

    outTexture.write(half4(half3(saturate(rgb)), 1.0h), gid);
}
