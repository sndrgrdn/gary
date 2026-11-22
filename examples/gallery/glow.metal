half4 glow(float2 position, float2 size, float time, constant float *args, uint count) {
    float2 center = size / 2 + float2(cos(time), sin(time * 1.3)) * size * 0.15;
    float d = distance(position, center) / (min(size.x, size.y) * 0.35);
    float pulse = 0.8 + 0.2 * sin(time * 2);
    half3 color = mix(half3(args[0], args[1], args[2]), half3(1, 1, 0.9), half(saturate(0.4 - d) * 2));
    return half4(color, smoothstep(1.0, 0.0, d) * pulse * args[3]);
}
