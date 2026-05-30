#include <metal_stdlib>
using namespace metal;

// MARK: - Structs

struct FragmentUniforms {
    float tileCount;
    float rotation;
    float offsetX;
    float offsetY;
};

// MARK: - Utility Functions

// Standard luminance formula for RGB to Grayscale conversion
float getLuminance(float4 color) {
    return dot(color.rgb, float3(0.299, 0.587, 0.114));
}

// MARK: - Compute Kernels

kernel void computeNoiseKernel(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float &frequency [[buffer(0)]],
    constant float &scale [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float4 color = inputTexture.read(gid);
    float noise = sin(gid.x * frequency) * cos(gid.y * frequency) * scale;
    color.rgb += noise;
    outputTexture.write(color, gid);
}

kernel void sobelNormalKernel(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float &strength [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);

    float tl = getLuminance(inputTexture.sample(s, float2(gid.x - 1, gid.y - 1)));
    float t  = getLuminance(inputTexture.sample(s, float2(gid.x,     gid.y - 1)));
    float tr = getLuminance(inputTexture.sample(s, float2(gid.x + 1, gid.y - 1)));
    float l  = getLuminance(inputTexture.sample(s, float2(gid.x - 1, gid.y)));
    float r  = getLuminance(inputTexture.sample(s, float2(gid.x + 1, gid.y)));
    float bl = getLuminance(inputTexture.sample(s, float2(gid.x - 1, gid.y + 1)));
    float b  = getLuminance(inputTexture.sample(s, float2(gid.x,     gid.y + 1)));
    float br = getLuminance(inputTexture.sample(s, float2(gid.x + 1, gid.y + 1)));

    float dx = (tr + 2.0 * r + br) - (tl + 2.0 * l + bl);
    float dy = (bl + 2.0 * b + br) - (tl + 2.0 * t + tr);
    
    float3 normal = normalize(float3(-dx * strength, -dy * strength, 1.0));
    outputTexture.write(float4(normal * 0.5 + 0.5, 1.0), gid);
}

/// Generates Roughness or Metallic maps based on the input luminance.
/// blendMin/Max allow for remapping the grayscale intensity to specific material properties.
kernel void pbrMapKernel(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float &blendMin [[buffer(0)]],
    constant float &blendMax [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float lum = getLuminance(inputTexture.read(gid));
    // Remap the luminance to a specific range (e.g., making a surface "mostly rough" or "highly metallic")
    float result = mix(blendMin, blendMax, lum);
    outputTexture.write(float4(result, result, result, 1.0), gid);
}

/// Generates a pseudo-Ambient Occlusion map by analyzing local contrast/edges.
kernel void aoKernel(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float &aoStrength [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float center = getLuminance(inputTexture.sample(s, float2(gid)));
    
    // Sample surrounding area to find "crevices" (where local luminance drops)
    float sum = 0.0;
    for(int x = -2; x <= 2; x++) {
        for(int y = -2; y <= 2; y++) {
            sum += getLuminance(inputTexture.sample(s, float2(gid.x + x, gid.y + y)));
        }
    }
    float avg = sum / 25.0;
    
    // Occlusion is higher where the center is significantly darker than the average neighborhood
    float occlusion = clamp(1.0 - (center / (avg + 0.001)) * aoStrength, 0.0, 1.0);
    outputTexture.write(float4(occlusion, occlusion, occlusion, 1.0), gid);
}

kernel void makeItTileKernel(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float &blendRange [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = outputTexture.get_width();
    uint height = outputTexture.get_height();
    
    if (gid.x >= width || gid.y >= height) return;

    float2 centerOffset = float2(0.5, 0.5);
    float2 uv = float2(gid) / float2(width, height);
    float2 offsetUV = fract(uv + centerOffset);
    
    constexpr sampler s(address::repeat, filter::linear);
    float4 offsetColor = inputTexture.sample(s, offsetUV);
    
    float maskX = smoothstep(0.5 - blendRange, 0.5, uv.x) * (1.0 - smoothstep(0.5, 0.5 + blendRange, uv.x));
    float maskY = smoothstep(0.5 - blendRange, 0.5, uv.y) * (1.0 - smoothstep(0.5, 0.5 + blendRange, uv.y));
    float mask = max(maskX, maskY);
    
    float4 originalColor = inputTexture.sample(s, uv);
    float4 finalColor = mix(offsetColor, originalColor, mask);
    
    outputTexture.write(finalColor, gid);
}

// MARK: - Rendering Shaders

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut tilingVertex(uint vid [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
        float2(-1.0, -1.0),
        float2( 1.0, -1.0)
    };
    
    float2 uvs[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };
    
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 tilingFragment(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant FragmentUniforms &uniforms [[buffer(0)]]) {
    sampler s(mag_filter::linear, min_filter::linear, address::repeat);
    
    float2 uv = in.uv - 0.5;
    float cosA = cos(uniforms.rotation);
    float sinA = sin(uniforms.rotation);
    float2 rotatedUV;
    rotatedUV.x = uv.x * cosA - uv.y * sinA;
    rotatedUV.y = uv.x * sinA + uv.y * cosA;
    
    float2 tiledUV = rotatedUV * uniforms.tileCount;
    tiledUV += float2(uniforms.offsetX, uniforms.offsetY);
    
    return tex.sample(s, tiledUV + 0.5);
}
