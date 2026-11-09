#include <metal_stdlib>
using namespace metal;

// glimm 的 prism 调色板（由 #00C0E8 → #6155F5 → #CB30E0 拟合出的余弦调色板系数）
constant float kGlimmPI = 3.14159265359;
constant float3 kPalA = float3(0.3685, 0.4881, 0.9039);
constant float3 kPalB = float3(0.3855, 0.2703, 0.0802);
constant float3 kPalC = float3(0.5000, 0.5000, 0.5000);
constant float3 kPalD = float3(0.4942, 0.0695, 0.7768);

inline float3 glimmPalette(float t) {
    return kPalA + kPalB * cos(2.0 * kGlimmPI * (kPalC * t + kPalD));
}

/// 扫光光带：一条窄而亮的彩虹光脊横穿画面。
/// 与 glimm.dev 的生产着色器一致——高斯截面 + 斜率合成法线产生高光 + 短余光 + 中途辉光。
[[ stitchable ]] half4 glimmSweep(float2 position,
                                 half4 color,
                                 float width,
                                 float height,
                                 float progress,
                                 float time,
                                 float alpha,
                                 float hueShift) {
    float2 uv = position / max(float2(width, height), float2(1.0));
    float axis = uv.x;
    float crossAxis = uv.y;

    // 光脊从屏幕左侧外(-0.2)扫到右侧外(1.2)
    float pos = -0.2 + progress * 1.4;

    float d = axis - pos;
    float band = exp(-d * d * 40.0);

    // 用光脊的斜率合成假法线，让高光沿着光脊掠过
    float dhDaxis = -2.0 * d * 40.0 * band;
    float3 N = normalize(float3(-dhDaxis * 0.18, 0.0, 1.0));

    // 光脊后方很短的余光
    float behind = max(-d, 0.0);
    float trail = smoothstep(0.0, 0.08, behind)
                * (1.0 - smoothstep(0.12, 0.65, behind)) * 0.10;

    // 扫过中途时更宽更柔的辉光
    float midpointFocus = 4.0 * progress * (1.0 - progress);
    float halo = exp(-d * d * 2.5) * 0.05 * midpointFocus;

    float intensity = max(band, trail);
    intensity = clamp(intensity + halo * (1.0 - band), 0.0, 1.0);

    // 彩虹色随坐标、法线与时间缓慢流动
    float ripple = sin(crossAxis * 12.0 + axis * 3.0 + time * 0.40) * 0.015;
    float t = N.x * 0.12 + N.y * 0.08
            + axis * 0.90 + crossAxis * 0.16
            + ripple + hueShift + time * 0.04;

    // 三个相邻采样做低通，避免出现硬色带
    float3 col = glimmPalette(t) * 0.50
               + glimmPalette(t - 0.18) * 0.25
               + glimmPalette(t + 0.18) * 0.25;

    // 固定主光 + 正面视线，得到稳定掠过光脊的镜面高光与边缘菲涅尔
    float3 V = float3(0.0, 0.0, 1.0);
    float3 L = normalize(float3(0.35, 0.55, 0.9));
    float3 H = normalize(L + V);
    float NdotH = clamp(dot(N, H), 0.0, 1.0);
    float NdotV = clamp(dot(N, V), 0.0, 1.0);
    float fresnel = pow(1.0 - NdotV, 3.0);
    float spec = pow(NdotH, 80.0);

    // 进出屏幕时降低强度，避免光带突然出现
    float entryFade = mix(0.2, 1.0, 4.0 * progress * (1.0 - progress));

    float bodyA = intensity * alpha * entryFade;
    float3 bodyPM = col * bodyA;

    float highMask = band * alpha * entryFade * 0.55;
    float3 highEmit = (col * fresnel * 0.55 + float3(spec) * 1.1) * highMask;
    float highA = (fresnel * 0.4 + spec * 0.9) * highMask;

    // colorEffect 需要返回预乘颜色
    return half4(half3(bodyPM + highEmit), half(min(bodyA + highA, 1.0)));
}
