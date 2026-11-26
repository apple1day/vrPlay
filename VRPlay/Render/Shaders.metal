#include <metal_stdlib>
using namespace metal;

// ───────────── 场景 pass：YUV 视频 → 球面 / 平面，按眼采样左右半幅 ─────────────

struct Vertex {
    packed_float3 pos;
    packed_float2 uv;
};

// 必须与 VRRenderer.swift 里的 EyeUniforms 内存布局一致（128 字节）
struct EyeUniforms {
    float4x4 mvp;
    float2   uvScale;    // 本眼在整张视频纹理里的缩放：SBS=(0.5,1)  TB=(1,0.5)  单眼=(1,1)
    float2   uvOffset;   // 本眼偏移：右眼 SBS=(0.5,0)  TB=(0,0.5)
    float2   uvInset;    // 半个纹素，防止两眼接缝处互相渗色
    float2   pad;
    float4   yuvParams;  // x: yOffset  y: yScale  z: cOffset  w: cScale
    float4   yuvCoeffs;  // x: Cr→R  y: Cb→G  z: Cr→G  w: Cb→B
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut vr_vertex(uint vid [[vertex_id]],
                      const device Vertex *verts [[buffer(0)]],
                      constant EyeUniforms &u [[buffer(1)]]) {
    Vertex v = verts[vid];
    VOut o;
    o.position = u.mvp * float4(float3(v.pos), 1.0);
    o.uv = float2(v.uv);
    return o;
}

fragment float4 vr_fragment(VOut in [[stage_in]],
                            texture2d<float> yTex [[texture(0)]],
                            texture2d<float> cTex [[texture(1)]],
                            constant EyeUniforms &u [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = clamp(in.uv, u.uvInset, float2(1.0) - u.uvInset) * u.uvScale + u.uvOffset;

    float  y  = (yTex.sample(s, uv).r  - u.yuvParams.x) * u.yuvParams.y;
    float2 c  = (cTex.sample(s, uv).rg - u.yuvParams.z) * u.yuvParams.w;
    float  cb = c.x;
    float  cr = c.y;

    float3 rgb = float3(y + u.yuvCoeffs.x * cr,
                        y - u.yuvCoeffs.y * cb - u.yuvCoeffs.z * cr,
                        y + u.yuvCoeffs.w * cb);
    return float4(saturate(rgb), 1.0);
}

// ───────────── 后处理 pass：Cardboard 镜片桶形预畸变 ─────────────
// 输入是已经并排画好左右眼的离屏纹理，逐像素判断属于哪只眼，再做径向畸变。

struct DistortUniforms {
    float4 p0;   // x: k1  y: k2  z: lensOffset  w: 单眼宽高比
    float4 p1;   // x: zoom
};

struct PostOut {
    float4 position [[position]];
    float2 uv;
};

vertex PostOut post_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));   // (0,0) (2,0) (0,2)
    PostOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 post_fragment(PostOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant DistortUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float k1 = u.p0.x, k2 = u.p0.y, lens = u.p0.z, aspect = u.p0.w, zoom = max(u.p1.x, 0.1);

    int eye = in.uv.x < 0.5 ? 0 : 1;
    float2 local = float2(eye == 0 ? in.uv.x * 2.0 : (in.uv.x - 0.5) * 2.0, in.uv.y);
    float2 c = local * 2.0 - 1.0;                               // 本眼坐标 -1…1

    // 正值 = 镜片中心向鼻梁靠近（左眼向右、右眼向左）
    float2 center = float2(eye == 0 ? lens : -lens, 0.0);
    float2 d = c - center;
    float2 dn = float2(d.x * aspect, d.y);
    float r2 = dot(dn, dn);
    float k = (1.0 + k1 * r2 + k2 * r2 * r2) / zoom;

    float2 sc = center + d * k;
    float2 l = sc * 0.5 + 0.5;
    if (l.x < 0.0 || l.x > 1.0 || l.y < 0.0 || l.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    float2 suv = float2(eye == 0 ? l.x * 0.5 : 0.5 + l.x * 0.5, l.y);
    return src.sample(s, suv);
}
