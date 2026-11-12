//
//  Shaders.metal
//  macOSMetal
//
//  Created by Zach Eriksen on 4/30/18.
//  Copyright © 2018 Zach Eriksen. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position;
    float4 color;
};


struct VertexOut {
    float4 position [[ position ]];
    float4 color;
};

vertex VertexOut basic_vertex_function(const device VertexIn *vertices [[ buffer(0) ]],
                                       uint vertexID [[ vertex_id  ]]) {
    VertexOut vOut;
    vOut.position = float4(vertices[vertexID].position,1);
    vOut.color = vertices[vertexID].color;
    return vOut;
}


fragment float4 basic_fragment_function(VertexOut vIn [[ stage_in ]]) {
    return vIn.color;
}

struct vxin
{
    packed_float3 pos;
    packed_float2 uv;
};

struct vxout
{
    float4 pos [[position]];
    float2 uv;
    float4 color [[flat]];
    uint32_t txIndex [[flat]];
};

struct vxout_brush
{
    float4 pos [[position]];
    float2 local_uv;
    float2 uv;
};
struct Uniforms
{
    float4x4 modelMatrix;
//  float4x4 projectionMatrix;
};

vertex vxout basic_vertex(const device vxin* vertex_array [[ buffer(0) ]],
                          //const device Uniforms& uniforms [[ buffer(1) ]],
                          unsigned int vid [[ vertex_id ]])
{
    vxin vi = vertex_array[vid];
    
    vxout vo;
    vo.uv = vi.uv;
    float4 p = float4(vi.pos, 1.0);
    //float4x4 m = uniforms.modelMatrix;
    //vo.pos = m * p;
    vo.pos = p;
    return vo;
}

fragment half4 clear_fragment(vxout fin [[ stage_in ]])
{
    //return half4(half3(fin.color), 1.0);
    discard_fragment();
    return half4(0,0,0,0);
}

fragment float4 basic_fragment(vxout fin [[ stage_in ]],
                              texture2d<float> tx [[ texture(0) ]],
                              texture2d<float> ui [[ texture(1) ]])
{
    constexpr sampler txsampler;
    float4 u = ui.sample(txsampler, fin.uv);
    float4 t = tx.sample(txsampler, fin.uv);
    float4 ret = u * u.a + t * (1 - u.a);
    ret.a = 1;
    return ret;
}

struct uniform2d
{
    float2 translate;
    float2 scale;
    float4 color;
    uint32_t txIndex;
};

//DEPRECATED
vertex vxout brush_vertex(const device vxin* vertex_array [[ buffer(0) ]],
                          const device uniform2d &uniforms [[ buffer(1) ]],
                          unsigned int vid [[ vertex_id ]])
{
    vxin vi = vertex_array[vid];
    
    vxout vo;
    vo.txIndex = uniforms.txIndex;
    vo.uv = vi.uv;
    vo.color = uniforms.color;
    float2 translate = uniforms.translate;
    float2 scale = uniforms.scale;
    float2 pos;
    pos.x = vi.pos[0];
    pos.y = vi.pos[1];
    pos = pos * scale + translate;
    float4 p = float4(pos, 0.0, 1.0);
    vo.pos = p;
    return vo;
}

vertex vxout stroke_vertex(const device vxin* vertex_array [[ buffer(0) ]],
                          const device uniform2d *uniforms [[ buffer(1) ]],
                          unsigned int vid [[ vertex_id ]],
                          uint16_t iid [[ instance_id ]])
{
    vxin vi = vertex_array[vid];
    uniform2d uni = uniforms[iid];
    
    vxout vo;
    vo.uv = vi.uv;
    vo.txIndex = uni.txIndex;
    vo.color = uni.color;
    float2 translate = uni.translate;
    float2 scale = uni.scale;
    float2 pos;
    pos.x = vi.pos[0];
    pos.y = vi.pos[1];
    pos = pos * scale + translate;
    float4 p = float4(pos, 0.0, 1.0);
    //vo.pos = m * p;
    vo.pos = p;
    return vo;
}

typedef struct FragmentShaderArguments {
    array<texture2d<float>, 2> exampleTextures  [[ id(0)  ]];
} fsa;

//TODO figure out how to programmatically specify number of textures in array
fragment float4 brush_fragment(vxout fin [[ stage_in ]],
                              array<texture2d<float>, 3> tx [[ texture(0) ]])
                              //texture2d<half> tx2 [[ texture(1) ]])
{
    constexpr sampler txsampler;
    float4 brush;
    brush = tx[fin.txIndex].sample(txsampler, fin.uv);
    if (fin.txIndex == 0) {
        //brush = tx.sample(txsampler, fin.uv);
        brush.rgb = float3(fin.color.rgb);
    } else if (fin.txIndex == 1){
        //brush = tx2.sample(txsampler, fin.uv);
    }
    brush.a *= fin.color.a;
    return brush;
}

// Editor rendering uses document units and immutable per-stroke stamp buffers.
struct CanvasStamp { float2 position; float2 size; float4 color; };
struct CanvasViewUniforms { float4 viewport; float4 canvas; };
struct CanvasStampOut {
    float4 position [[position]];
    float2 local;
    float2 documentPosition;
    float4 color;
};
vertex CanvasStampOut canvas_stamp_vertex(const device CanvasStamp *stamps [[buffer(0)]],
                                         constant CanvasViewUniforms &u [[buffer(1)]],
                                         uint vertexID [[vertex_id]], uint instanceID [[instance_id]]) {
    constexpr float2 corners[] = {float2(-0.5,-0.5), float2(0.5,-0.5), float2(0.5,0.5),
                                  float2(-0.5,-0.5), float2(0.5,0.5), float2(-0.5,0.5)};
    CanvasStamp stamp = stamps[instanceID];
    float2 local = corners[vertexID];
    float2 p = stamp.position + local * stamp.size;
    float2 screen = (p - u.canvas.xy / 2) * u.viewport.z + u.viewport.xy / 2 + u.canvas.zw;
    CanvasStampOut result;
    result.position = float4(screen.x / u.viewport.x * 2 - 1, 1 - screen.y / u.viewport.y * 2, 0, 1);
    result.local = local;
    result.documentPosition = p;
    result.color = stamp.color;
    return result;
}
fragment float4 canvas_paper_fragment(CanvasStampOut in [[stage_in]]) { return in.color; }
fragment float4 canvas_ink_fragment(CanvasStampOut in [[stage_in]], constant CanvasViewUniforms &u [[buffer(1)]]) {
    if (any(in.documentPosition < float2(0)) || any(in.documentPosition > u.canvas.xy)) discard_fragment();
    float radius = length(in.local);
    float edge = max(fwidth(radius), 0.001);
    float alpha = in.color.a * (1 - smoothstep(0.5 - edge, 0.5, radius));
    return float4(in.color.rgb * alpha, alpha);
}

// Resolve overlapping stamps with max(alpha) before compositing the stroke once.
fragment float4 canvas_stroke_mask_fragment(CanvasStampOut in [[stage_in]], constant CanvasViewUniforms &u [[buffer(1)]]) {
    if (any(in.documentPosition < float2(0)) || any(in.documentPosition > u.canvas.xy)) discard_fragment();
    float radius = length(in.local);
    float edge = max(fwidth(radius), 0.001);
    float alpha = in.color.a * (1 - smoothstep(0.5 - edge, 0.5, radius));
    return float4(alpha, 0, 0, 1);
}
fragment float4 canvas_stroke_composite_fragment(CanvasStampOut in [[stage_in]], texture2d<float, access::read> mask [[texture(0)]]) {
    float alpha = mask.read(uint2(in.position.xy)).r;
    return float4(in.color.rgb * alpha, alpha);
}

fragment float4 canvas_cached_layer_fragment(CanvasStampOut in [[stage_in]], texture2d<float, access::read> layer [[texture(0)]]) {
    return layer.read(uint2(in.position.xy));
}
