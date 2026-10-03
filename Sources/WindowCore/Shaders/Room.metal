// The room, the window, and the weather outside it.
//
// World space: the eye at the origin, x right, y up, z into the screen, in metres.
// Sky space: x east, y up, z north, used for everything outside the glass.
// Screen space: pixels from the top-left of the display.

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared parameters (mirrors FrameUniforms in Swift)

struct Frame {
    float4 screen;      // xy screen size px, z px per point, w time s
    float4 layer;       // xy layer origin px, zw layer size px
    float4 eye;         // xy vanishing point px, z room focal px, w outdoor focal px
    float4 opening;     // left, right, bottom, top (m)
    float4 depths;      // wall distance, reveal depth, sill projection, sill thickness
    float4 trim;        // sill horn, frame width, bottom rail, bar width
    float4 mullionsX;   // vertical bars (m), far away when unused
    float4 transomsY;   // horizontal bars (m), far away when unused
    float4 glass;       // glass rect px: x0 y0 x1 y1
    float4 camRight;    // outdoor camera basis in sky space
    float4 camUp;
    float4 camForward;
    float4 sun;         // xyz direction, w altitude (rad)
    float4 sunLight;    // rgb sunlight at the ground, w disc visibility
    float4 moon;        // xyz direction, w lit fraction
    float4 moonLight;   // rgb moonlight, w angular radius (rad)
    float4 clouds;      // low, mid, high cover, storm darkness
    float4 cloudShift0; // low xy, mid zw (km)
    float4 cloudShift1; // high xy (km), z morph time, w unused
    float4 weather;     // rain, snow, drizzle, thunder
    float4 weather2;    // visibility km, frost, snow cover, night
    float4 precip;      // xy fall direction on screen, z wetness of the glass, w wind speed m/s
    float4 exposure;    // outdoor exposure, room exposure, flash, lamp intensity
    float4 lampColor;   // rgb linear
    float4 lamp;        // xyz globe centre (m), w radius (m)
    float4 windowLight; // rgb mean radiance through the glass, w its luminance
    float4 sleeve;      // unused by shaders other than lighting: x centre x, y base z, z yaw, w pose
    float4 sleeve2;     // x size, y thickness, z cover crossfade, w has cover
    float4 misc;        // x landscape seed, y facing azimuth (rad), z label alpha, w star visibility
    float4 cloudLight[3];  // per layer (low, mid, high): xyz direction of the dominant light
    float4 cloudColour[3]; // per layer: rgb of that light where the cloud sits
    float4 timing;      // x blend, y sill left (m), z sill right (m), w opening scale (0 shut, 1 designed)
    float4 occupation;  // x growth, 0 bare to 1 established. The opening does not follow it.
    float4x4 stars;     // sky space to equatorial
};

constant float PI = 3.14159265;

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// MARK: - Hashing and noise

float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

float hash13(float3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

float3 hash33(float3 p3) {
    p3 = fract(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yxx) * p3.zyx);
}

// Value noise that repeats every 1024 cells, so drifting offsets can wrap without a seam.
float noise2(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = hash12(fmod(i, 1024.0));
    float b = hash12(fmod(i + float2(1, 0), 1024.0));
    float c = hash12(fmod(i + float2(0, 1), 1024.0));
    float d = hash12(fmod(i + float2(1, 1), 1024.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float noise3(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n000 = hash13(i);
    float n100 = hash13(i + float3(1, 0, 0));
    float n010 = hash13(i + float3(0, 1, 0));
    float n110 = hash13(i + float3(1, 1, 0));
    float n001 = hash13(i + float3(0, 0, 1));
    float n101 = hash13(i + float3(1, 0, 1));
    float n011 = hash13(i + float3(0, 1, 1));
    float n111 = hash13(i + float3(1, 1, 1));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

float fbm2(float2 p, int octaves) {
    float sum = 0.0, amp = 0.5, norm = 0.0;
    const float2x2 rot = float2x2(0.8, -0.6, 0.6, 0.8);
    for (int i = 0; i < octaves; i++) {
        sum += amp * noise2(p);
        norm += amp;
        p = rot * p * 2.03 + float2(17.1, 9.2);
        amp *= 0.5;
    }
    return sum / norm;
}

// fbm that drops octaves finer than the pixel it lands in, replacing them with their mean.
float fbmBand(float2 p, int octaves, float footprint) {
    float sum = 0.0, amp = 0.5, norm = 0.0, freq = 1.0;
    const float2x2 rot = float2x2(0.8, -0.6, 0.6, 0.8);
    for (int i = 0; i < octaves; i++) {
        float keep = saturate(2.0 - 4.0 * footprint * freq);
        sum += amp * mix(0.5, noise2(p), keep);
        norm += amp;
        p = rot * p * 2.03 + float2(17.1, 9.2);
        freq *= 2.03;
        amp *= 0.5;
    }
    return sum / norm;
}

// MARK: - Colour

float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

float acesCurve(float x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

// The film response applied to brightness alone, so an orange sky stays orange instead of turning yellow.
// Very bright light washes toward white, the way it does on film and in the eye.
float3 filmic(float3 x) {
    x = max(x, 0.0);
    float l = luminance(x);
    if (l < 1e-7) return float3(0.0);
    float lt = acesCurve(l);
    float3 c = x * (lt / l);
    c = mix(c, float3(lt), smoothstep(0.55, 1.0, lt) * 0.5);
    float peak = max(c.r, max(c.g, c.b));
    if (peak > 1.0) {
        c = mix(c, float3(lt), saturate((peak - 1.0) / max(peak - lt, 1e-4)));
    }
    return saturate(c);
}

// Dim light loses its colour, as the eye's rods take over. Only the dimmest parts of the scene are affected.
float3 nightVision(float3 c, float night) {
    float l = luminance(c);
    float rods = night * (1.0 - smoothstep(0.004, 0.06, l));
    float3 grey = float3(0.78, 0.9, 1.22) * l;
    return mix(c, grey, rods * 0.65);
}

float3 encodeSRGB(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

float3 dither(float3 c, float2 px) {
    float n = hash12(px) + hash12(px + 0.5) - 1.0;
    return c + n / 255.0;
}

float3 present(float3 radiance, float exposure, float night, float2 px) {
    float3 c = nightVision(radiance * exposure, night);
    return dither(encodeSRGB(filmic(c)), px);
}

// MARK: - Geometry helpers

float3 balancedWindowLight(constant Frame& f) {
    float3 w = f.windowLight.rgb + float3(0.7, 0.75, 0.9) * f.exposure.z * 0.01;
    return mix(float3(luminance(w)), w, 0.38);
}

float3 roomRay(float2 px, constant Frame& f) {
    return float3((px.x - f.eye.x) / f.eye.z, -(px.y - f.eye.y) / f.eye.z, 1.0);
}

float3 outdoorDirection(float2 px, constant Frame& f) {
    float2 c = float2(px.x - f.eye.x, f.eye.y - px.y) / f.eye.w;
    return normalize(c.x * f.camRight.xyz + c.y * f.camUp.xyz + f.camForward.xyz);
}

// Fraction of a Lambertian surface's view that a quad of light covers, signed by facing.
float quadIrradiance(float3 p, float3 n, float3 a, float3 b, float3 c, float3 d) {
    float3 v[4] = { normalize(a - p), normalize(b - p), normalize(c - p), normalize(d - p) };
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        float3 v0 = v[i];
        float3 v1 = v[(i + 1) & 3];
        float cosTheta = clamp(dot(v0, v1), -0.9999, 0.9999);
        float theta = acos(cosTheta);
        float3 cr = cross(v0, v1);
        sum += theta * dot(n, cr / max(length(cr), 1e-5));
    }
    return max(sum, 0.0) / (2.0 * PI);
}

// MARK: - Atmosphere

constant float earthRadius = 6360.0;
constant float atmosphereRadius = 6460.0;
constant float3 rayleighScattering = float3(5.802, 13.558, 33.1) * 1e-3;
constant float mieScattering = 3.996e-3;
constant float mieExtinction = 4.44e-3;
constant float3 ozoneAbsorption = float3(0.650, 1.881, 0.085) * 1e-3;

float2 raySphere(float3 o, float3 d, float r) {
    float b = dot(o, d);
    float c = dot(o, o) - r * r;
    float h = b * b - c;
    if (h < 0.0) return float2(-1.0);
    h = sqrt(h);
    return float2(-b - h, -b + h);
}

float3 densities(float h) {
    float ozone = max(0.0, 1.0 - abs(h - 25.0) / 15.0);
    return float3(exp(-h / 8.0), exp(-h / 1.2), ozone);
}

float3 extinctionFor(float3 depth) {
    return rayleighScattering * depth.x + mieExtinction * depth.y + ozoneAbsorption * depth.z;
}

// Single scattering for a light of unit intensity, integrated from an eye near the ground.
float3 scatter(float3 dir, float3 light) {
    float3 origin = float3(0.0, earthRadius + 0.2, 0.0);
    float2 top = raySphere(origin, dir, atmosphereRadius);
    float2 ground = raySphere(origin, dir, earthRadius);
    float rayLength = top.y;
    if (ground.x > 0.0) rayLength = min(rayLength, ground.x);
    rayLength = min(rayLength, 300.0);
    const int steps = 24;
    float dt = rayLength / steps;
    float3 depth = 0.0;
    float3 sumR = 0.0, sumM = 0.0, multiple = 0.0;
    for (int i = 0; i < steps; i++) {
        float3 p = origin + dir * ((float(i) + 0.5) * dt);
        float h = max(length(p) - earthRadius, 0.0);
        float3 local = densities(h) * dt;
        depth += local;
        multiple += exp(-extinctionFor(depth)) * (local.x + local.y * 0.3);
        float2 earth = raySphere(p, light, earthRadius);
        if (earth.x > 0.0) continue;
        float2 out = raySphere(p, light, atmosphereRadius);
        const int lightSteps = 6;
        float dl = out.y / lightSteps;
        float3 lightDepth = 0.0;
        for (int j = 0; j < lightSteps; j++) {
            float3 q = p + light * ((float(j) + 0.5) * dl);
            lightDepth += densities(max(length(q) - earthRadius, 0.0)) * dl;
        }
        float3 transmittance = exp(-extinctionFor(depth + lightDepth));
        sumR += transmittance * local.x;
        sumM += transmittance * local.y;
    }
    float mu = dot(dir, light);
    float phaseR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    const float g = 0.76;
    float phaseM = (1.0 - g * g) / (4.0 * PI * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
    // Light scattered more than once, as an even glow whose colour follows the light's height.
    // Single scattering alone leaves the horizon green and twilight far too dark.
    float up = light.y;
    float3 tint = mix(float3(0.42, 0.45, 0.85), float3(1.0, 0.78, 0.55), smoothstep(-0.06, 0.04, up));
    tint = mix(tint, float3(0.78, 0.88, 1.0), smoothstep(0.05, 0.3, up));
    float strength = (0.03 + 0.97 * smoothstep(-0.02, 0.25, up)) * smoothstep(-0.16, -0.02, up);
    float3 glow = multiple * rayleighScattering * tint * strength / (4.0 * PI);
    return sumR * rayleighScattering * phaseR + sumM * mieScattering * phaseM + glow;
}

// The lookup table: azimuth from the light across, elevation down, sun in the top half and moon below.
fragment float4 skyTableFragment(FullscreenOut in [[stage_in]], constant Frame& f [[buffer(0)]]) {
    bool lunar = in.uv.y > 0.5;
    float v = lunar ? (in.uv.y - 0.5) * 2.0 : in.uv.y * 2.0;
    float t = v * 2.0 - 1.0;
    float elevation = sign(t) * t * t * (PI / 2.0);
    float azimuth = in.uv.x * PI;
    float3 dir = float3(cos(elevation) * sin(azimuth), sin(elevation), cos(elevation) * cos(azimuth));
    float altitude = lunar ? asin(clamp(f.moon.y, -1.0, 1.0)) : f.sun.w;
    float3 light = float3(0.0, sin(altitude), cos(altitude));
    return float4(scatter(dir, light), 1.0);
}

float3 sampleTable(texture2d<float> table, sampler s, float3 dir, float3 light, bool lunar) {
    float2 lh = light.xz;
    float2 dh = dir.xz;
    float relative = 0.0;
    if (length(lh) > 1e-4 && length(dh) > 1e-4) {
        relative = acos(clamp(dot(normalize(dh), normalize(lh)), -1.0, 1.0));
    }
    float elevation = asin(clamp(dir.y, -1.0, 1.0));
    float v = 0.5 + 0.5 * sign(elevation) * sqrt(abs(elevation) / (PI / 2.0));
    v = clamp(v, 1.0 / 128.0, 1.0 - 1.0 / 128.0);
    float2 uv = float2(relative / PI, lunar ? 0.5 + v * 0.5 : v * 0.5);
    return table.sample(s, uv).rgb;
}

constant float sunIntensity = 22.0;

float3 skyRadiance(texture2d<float> table, sampler s, float3 dir, constant Frame& f) {
    float3 sky = sampleTable(table, s, dir, f.sun.xyz, false) * sunIntensity;
    float moonGain = f.moon.w * smoothstep(-0.05, 0.1, f.moon.y) * sunIntensity * 0.0018;
    sky += sampleTable(table, s, dir, f.moon.xyz, true) * moonGain;
    // Airglow and the glow of towns below the horizon keep the night from going flat black.
    float el = max(dir.y, 0.0);
    float3 night = float3(0.0003, 0.00052, 0.00125) * (0.6 + 0.8 * exp(-el * 6.0));
    night += float3(0.0009, 0.0007, 0.0005) * exp(-el * 16.0);
    return sky + night;
}

// MARK: - Clouds

struct CloudSample {
    float3 color;
    float alpha;
};

float cloudDistance(float elevationSin, float height) {
    float r = earthRadius;
    float b = r * elevationSin;
    return -b + sqrt(b * b + 2.0 * r * height + height * height);
}

// One cloud deck, projected onto a shell around the Earth so it meets the horizon at a finite distance.
// kind 0: heaped cloud; 1: a layer of small cloudlets; 2: cirrus combed out by the wind.
CloudSample cloudLayer(float3 dir, float height, float cover, float2 shift, float featureKm, float2 wind, float stretch,
                       float softness, float opacity, float morph, float3 lightDir, float3 lightColour, float3 ambient,
                       float darkness, float flash, int kind, float texelAngle, float3 cityGlow) {
    CloudSample result;
    result.color = 0.0;
    result.alpha = 0.0;
    if (cover < 0.01 || dir.y < -0.01) return result;
    float distance = cloudDistance(max(dir.y, 0.0), height);
    // How much of the deck one texel covers, in units of the cloud features.
    float graze = height / distance + distance / (2.0 * earthRadius);
    float footprint = distance * texelAngle / max(graze, 0.012) / featureKm;
    float2 world = dir.xz * distance + shift;
    float2 across = float2(-wind.y, wind.x);
    // Combing along the wind fades toward the horizon, where perspective would squeeze it into streaks.
    stretch = mix(1.0, stretch, smoothstep(0.03, 0.25, dir.y));
    float2 p = float2(dot(world, wind) / stretch, dot(world, across)) / featureKm;
    float2 warp = float2(noise2(p * 0.3 + morph), noise2(p * 0.3 - morph + 5.2)) - 0.5;
    float n = fbmBand(p + warp * 0.5, 6, footprint);
    if (kind == 1) n = mix(n, mix(0.5, noise2(p * 3.1 + 2.0), saturate(2.0 - 12.0 * footprint)), 0.35);
    // fbm sits mostly between 0.3 and 0.7, so map cover onto that range. Edges soften as detail blurs out.
    float threshold = mix(0.72, 0.3, cover);
    float soft = softness + footprint * 0.3;
    float density = smoothstep(threshold - soft * 0.3, threshold + soft, n);
    if (cover > 0.93) density = max(density, smoothstep(0.93, 1.0, cover) * (0.85 + 0.15 * n));
    // Far off, many clouds overlap in each texel and the deck tends to its average cover.
    float detail = 1.0 - smoothstep(0.12, 0.6, footprint);
    density = mix(saturate(cover * 1.02), density, detail);
    if (density <= 0.002) return result;

    // Thickness grows as the field climbs above the threshold; light comes from its slope toward the light.
    float thick = saturate((n - threshold) / 0.2) * (kind == 2 ? 0.25 : 1.0);
    float2 lightWorld = lightDir.xz / max(length(lightDir.xz), 1e-4);
    float2 toLight = float2(dot(lightWorld, wind) / stretch, dot(lightWorld, across)) * (0.3 / featureKm);
    float ahead = fbmBand(p + toLight + warp * 0.5, 5, footprint);
    float facing = saturate(0.5 + (n - ahead) * 5.0 * detail);
    float thin = 1.0 - smoothstep(0.0, 0.6, density);
    float mu = dot(dir, lightDir);
    // We see clouds from below. A low sun lights those undersides; a high one leaves them grey.
    float underLit = smoothstep(0.45, 0.0, lightDir.y);
    float sideOn = smoothstep(0.45, 0.04, dir.y);
    float exposed = mix(mix(0.45, 1.0, underLit), 1.0, sideOn * 0.5);
    float silver = pow(saturate(mu), 40.0) * thin * 1.6;
    float sunTerm = (0.2 + 0.8 * facing) * exposed * (1.0 - 0.6 * thick) * 0.62 + silver + 0.1 * pow(saturate(mu), 3.0);
    float3 colour = lightColour * sunTerm + ambient * (1.0 - 0.25 * thick);
    // Towns light the undersides of low cloud at night.
    colour += cityGlow * (0.6 + 0.4 * thick) * (kind == 0 ? 1.0 : 0.4);
    colour *= 1.0 - darkness * (0.3 + 0.45 * thick);
    colour += float3(0.75, 0.8, 1.0) * flash * 0.05 * (0.5 + density);
    result.color = colour;
    result.alpha = saturate(density * opacity);
    return result;
}

// Heaped cloud as a heightfield slab: flat bases at one height, tops that rise with the noise field.
// A short march through the slab gives real depth: dark bases overhead, lit sides toward the horizon.
struct CloudVolume {
    float3 colour;
    float transmittance;
};

CloudVolume cumulus(float3 dir, float cover, float2 shift, float featureKm, float2 wind, float morph,
                    float3 lightDir, float3 lightColour, float3 ambient, float3 horizon, float darkness, float flash,
                    float texelAngle, float3 cityGlow, float jitter) {
    CloudVolume v;
    v.colour = 0.0;
    v.transmittance = 1.0;
    if (cover < 0.01 || dir.y < -0.005) return v;
    const float base = 1.25;
    float thickness = mix(0.4, 1.05, saturate(cover * 1.2)) * (1.0 + darkness * 0.6);
    float el = max(dir.y, 0.0);
    float d0 = cloudDistance(el, base);
    float d1 = min(cloudDistance(el, base + thickness), d0 + 28.0);
    const int steps = 12;
    float dt = (d1 - d0) / float(steps);
    float threshold = mix(0.66, 0.31, cover);
    float2 across = float2(-wind.y, wind.x);
    float2 lightFlat = lightDir.xz / max(length(lightDir.xz), 1e-4);
    float mu = dot(dir, lightDir);
    float phase = 0.65 + 0.9 * pow(saturate(mu), 6.0) + 0.25 * mu;
    float flatCover = saturate(cover * 1.02);
    for (int i = 0; i < steps; i++) {
        float d = d0 + (float(i) + jitter) * dt;
        float3 p = dir * d;
        float h = length(float3(p.x, p.y + earthRadius, p.z)) - earthRadius;
        float2 world = p.xz + shift;
        float2 q = float2(dot(world, wind) / 1.1, dot(world, across)) / featureKm;
        float footprint = d * texelAngle / featureKm * 2.0;
        float detail = 1.0 - smoothstep(0.15, 0.7, footprint);
        float2 warp = float2(noise2(q * 0.3 + morph), noise2(q * 0.3 - morph + 5.2)) - 0.5;
        float n = fbmBand(q + warp * 0.45, 5, footprint);
        // Far away the field blurs toward its mean, so let the cover itself decide.
        n = mix(threshold + (flatCover - 0.5) * 0.3, n, detail);
        float rise = saturate((n - threshold) / 0.24);
        float top = base + rise * thickness;
        if (rise <= 0.0 || h > top) continue;
        float density = smoothstep(0.0, 0.16, top - h) * smoothstep(0.0, 0.4, rise);
        float sigma = density * mix(1.6, 3.2, darkness);
        // Light from above reaches through to the depth below the local top; a low sun lights the sides that face it.
        float overhead = exp(-(top - h) / max(lightDir.y, 0.12) * 1.6);
        float lowSun = smoothstep(0.35, 0.02, lightDir.y);
        float lit = overhead;
        if (lowSun > 0.01) {
            // Only a low light reaches in from the side, so only then is it worth looking that way.
            float2 qs = float2(dot(world + lightFlat * 0.35, wind) / 1.1, dot(world + lightFlat * 0.35, across)) / featureKm;
            float nSide = fbmBand(qs + warp * 0.45, 4, footprint);
            float sideways = smoothstep(threshold + 0.04, threshold - 0.04, nSide) * 0.85 + 0.15;
            lit = mix(overhead, max(overhead, sideways), lowSun);
        }
        float height01 = saturate((h - base) / thickness);
        float3 shade = lightColour * lit * phase * 0.62 + ambient * (0.3 + 0.7 * height01);
        shade += cityGlow * (1.2 - height01);
        shade *= 1.0 - darkness * 0.55;
        shade += float3(0.75, 0.8, 1.0) * flash * 0.06;
        // Distant cloud sinks into the haze of the horizon.
        shade = mix(horizon, shade, exp(-d / 70.0));
        float stepT = exp(-sigma * dt);
        v.colour += v.transmittance * (1.0 - stepT) * shade;
        v.transmittance *= stepT;
        if (v.transmittance < 0.02) break;
    }
    return v;
}

// MARK: - Land

float ridge(float azimuth, float frequency, float seed, int octaves) {
    float2 q = float2(cos(azimuth), sin(azimuth)) * frequency + seed;
    return fbm2(q, octaves);
}

struct LandLayer {
    float coverage;
    float distance;
    float3 albedo;
    float shade;
};

// A row of overlapping rounded crowns along the treeline, in degrees above its base.
float crownRow(float x, float seed) {
    float cell = floor(x);
    float h = 0.0;
    for (int k = -1; k <= 1; k++) {
        float c = cell + float(k);
        float centre = c + 0.2 + 0.6 * hash12(float2(c, seed));
        float width = 0.6 + 0.7 * hash12(float2(c, seed + 1.7));
        float height = 0.35 + 0.65 * hash12(float2(c, seed + 3.1));
        float d = (x - centre) / width;
        if (abs(d) < 1.0) h = max(h, height * sqrt(1.0 - d * d));
    }
    return h;
}

// A broadleaf tree in angular space: a short trunk under a broad crown of overlapping lobes with a leafy edge.
// Returns coverage, softened over about one texel (aa, in degrees).
float treeShape(float2 a, float2 foot, float height, float spread, float seed, float aa) {
    float2 q = a - foot;
    float lean = (hash12(float2(seed, 1.3)) - 0.5) * 0.12;
    float trunkHalf = height * 0.03;
    float trunk = smoothstep(trunkHalf + aa, trunkHalf - aa, abs(q.x - lean * q.y))
                * smoothstep(-aa, aa, q.y) * smoothstep(height * 0.45 + aa, height * 0.45 - aa, q.y);
    float crown = -10.0;
    float lobeRadius = spread * 0.42;
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        float2 h = hash22(float2(seed, fi * 3.7));
        // Lobes fill a broad ellipse; those near the top are a little smaller.
        float2 centre = float2((h.x - 0.5) * spread * 1.25, height * (0.5 + 0.34 * h.y));
        float r = spread * (0.36 + 0.2 * hash12(float2(seed + fi, 9.1))) * (1.05 - 0.25 * h.y);
        float d = length((q - centre) * float2(1.0, 1.1)) / r;
        crown = max(crown, 1.0 - d);
    }
    float leaves = fbm2(a * 16.0 + seed, 3) - 0.5;
    float k = aa / lobeRadius;
    float edge = smoothstep(0.01 - k, 0.01 + k, crown + leaves * 0.32);
    return max(trunk, edge);
}

// The land in four layers, far to near, each with its own coverage so edges blend instead of stepping.
void landLayers(float3 dir, float seed, float snowCover, float facing, float aa, thread LandLayer* layers) {
    float azimuth = atan2(dir.x, dir.z);
    float el = asin(clamp(dir.y, -1.0, 1.0)) * (180.0 / PI);
    float3 snow = float3(0.8, 0.82, 0.86);
    for (int i = 0; i < 4; i++) { layers[i].coverage = 0.0; layers[i].distance = 1.0; layers[i].albedo = 0.0; layers[i].shade = 1.0; }

    // Far: a faint range on the horizon.
    float far = 0.25 + 2.6 * pow(ridge(azimuth, 2.2, seed + 2.0, 5), 2.0);
    layers[0].coverage = smoothstep(-aa, aa, far - el);
    layers[0].distance = 26.0;
    layers[0].albedo = mix(float3(0.07, 0.08, 0.085), snow, snowCover);

    // Middle: low hills.
    float mid = 0.5 + 1.25 * ridge(azimuth, 4.0, seed + 5.0, 5);
    layers[1].coverage = smoothstep(-aa, aa, mid - el);
    layers[1].distance = 7.0;
    layers[1].albedo = mix(float3(0.05, 0.06, 0.055), snow * 0.8, snowCover * 0.8);
    layers[1].shade = 0.9;

    // Near: rounded crowns about a kilometre off, over dark ground. Measured from straight ahead so the row never seams in view.
    float ahead = atan2(dir.x * cos(facing) - dir.z * sin(facing), dir.x * sin(facing) + dir.z * cos(facing));
    float base = 0.25 + 0.6 * ridge(azimuth, 9.0, seed + 11.0, 4);
    float crowns = crownRow(ahead * 75.0, seed + 31.0) * 0.55 + crownRow(ahead * 160.0 + 7.0, seed + 47.0) * 0.25;
    float near = base + crowns;
    layers[2].coverage = smoothstep(-aa, aa, near - el);
    float below = saturate((base - el) / 3.0);
    layers[2].distance = mix(1.4, 0.4, below);
    layers[2].albedo = mix(float3(0.026, 0.037, 0.028), float3(0.036, 0.044, 0.03), smoothstep(0.15, 1.0, below));
    layers[2].albedo = mix(layers[2].albedo, snow * 0.7, snowCover * (0.25 + 0.5 * below));
    // Crowns catch the sky at their tops.
    layers[2].shade = 0.85 + 0.3 * saturate((el - base) / max(crowns, 0.05));

    // Nearest: a few trees a little over a hundred metres off, clear of where the sleeve and the lamp stand.
    float aheadDeg = ahead * (180.0 / PI);
    float2 a = float2(aheadDeg, el);
    float tree = 0.0;
    if (abs(aheadDeg - 9.0) < 8.0 || aheadDeg < -22.0) {
        tree = max(treeShape(a, float2(6.8, -1.1), 6.2, 4.6, seed + 1.0, aa), treeShape(a, float2(11.6, -1.0), 4.0, 3.2, seed + 2.0, aa));
        tree = max(tree, treeShape(a, float2(-27.5, -1.2), 7.4, 5.2, seed + 3.0, aa));
    }
    layers[3].coverage = tree;
    layers[3].distance = 0.12;
    layers[3].albedo = mix(float3(0.022, 0.03, 0.022), snow * 0.5, snowCover * 0.4);
    layers[3].shade = 0.8 + 0.2 * saturate((el + 1.0) / 8.0);
}

// MARK: - Outdoor pass (low resolution, glass-sized)

fragment float4 outdoorFragment(FullscreenOut in [[stage_in]],
                                constant Frame& f [[buffer(0)]],
                                texture2d<float> table [[texture(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float2 px = mix(f.glass.xy, f.glass.zw, in.uv);
    float3 dir = outdoorDirection(px, f);
    float3 sunDir = f.sun.xyz;

    float3 sky = skyRadiance(table, linear, dir, f);
    float3 zenith = skyRadiance(table, linear, float3(0.0, 1.0, 0.0), f);
    float3 horizonDir = normalize(float3(dir.x, 0.02, dir.z));
    float3 horizon = skyRadiance(table, linear, horizonDir, f);
    float3 ambient = mix(zenith, horizon, 0.5) * 1.6;
    // Under a deck of cloud the air holds far less light, and what it holds is grey.
    float underCloud = 1.0 - f.clouds.x * (0.45 + 0.4 * f.clouds.w);
    float3 neutralAmbient = mix(float3(luminance(ambient)), ambient, 0.45);
    float3 sunColour = f.sunLight.rgb;
    float flash = f.exposure.z;

    float moonUp = smoothstep(-0.02, 0.08, f.moon.y);
    float3 colour = sky;
    float transmittance = 1.0;
    float darkness = f.clouds.w;
    float morph = f.cloudShift1.z;

    // Sun glow is part of the sky, so clouds and land can cover it.
    float mu = dot(dir, sunDir);
    float disc = smoothstep(-0.03, 0.02, sunDir.y);
    colour += sunColour * disc * (0.6 * exp((mu - 1.0) * 900.0) + 0.06 * exp((mu - 1.0) * 60.0));

    if (dir.y > -0.02) {
        float windAngle = f.cloudShift1.w;
        float2 wind = float2(cos(windAngle), sin(windAngle));
        float texelAngle = 2.0 / f.eye.w;
        float3 cityGlow = float3(0.0016, 0.00125, 0.0009) * f.weather2.w;
        CloudSample high = cloudLayer(dir, 8.5, f.clouds.z, f.cloudShift1.xy, 2.2, wind, 2.2, 0.42, 0.55, morph * 0.5,
                                      f.cloudLight[2].xyz, f.cloudColour[2].rgb, ambient, 0.0, flash * 0.4, 2, texelAngle, cityGlow);
        colour = mix(colour, high.color, high.alpha);
        transmittance *= 1.0 - high.alpha * 0.8;
        CloudSample mid = cloudLayer(dir, 3.8, f.clouds.y, f.cloudShift0.zw, 0.75, wind, 1.2, 0.2, 0.85, morph * 0.8,
                                     f.cloudLight[1].xyz, f.cloudColour[1].rgb, neutralAmbient, darkness * 0.6, flash * 0.8, 1, texelAngle, cityGlow);
        colour = mix(colour, mid.color, mid.alpha);
        transmittance *= 1.0 - mid.alpha;
        // Interleaved gradient noise staggers the march start without visible grain.
        float2 texel = in.position.xy;
        float jitter = fract(52.9829189 * fract(dot(texel, float2(0.06711056, 0.00583715))));
        CloudVolume low = cumulus(dir, f.clouds.x, f.cloudShift0.xy, 1.7, wind, morph, f.cloudLight[0].xyz,
                                  f.cloudColour[0].rgb, neutralAmbient, horizon * underCloud, darkness, flash, texelAngle, cityGlow, jitter);
        colour = colour * low.transmittance + low.colour;
        transmittance *= low.transmittance;
    }

    // Fog and haze: distance through the air turns everything toward the light of the air itself.
    float visibility = max(f.weather2.x, 0.05);
    float sigma = 3.912 / visibility;
    float3 fogColour = mix(float3(luminance(ambient)), ambient, 0.25) * 0.95 * underCloud + float3(0.6, 0.65, 0.75) * flash * 0.02;
    // Looking up, the path through a ground fog layer shortens.
    float path = 0.35 / max(dir.y, 0.035);
    float skyFog = exp(-path * sigma);
    colour = mix(fogColour, colour, skyFog);
    transmittance *= skyFog;

    // The land, far to near, each layer seen through its own depth of air.
    LandLayer layers[4];
    float aa = 0.85 * (2.0 / f.eye.w) * (180.0 / PI);
    landLayers(dir, f.misc.x, f.weather2.z, f.misc.y, aa, layers);
    float3 lightOnLand = (sunColour * max(sunDir.y, 0.0) * 0.5 + neutralAmbient * 0.9) * underCloud + f.moonLight.rgb * moonUp * 0.3;
    for (int i = 0; i < 4; i++) {
        float coverage = layers[i].coverage;
        if (coverage <= 0.0) continue;
        float3 lit = layers[i].albedo * layers[i].shade * lightOnLand;
        float3 seen = mix(horizon, lit, exp(-layers[i].distance / 38.0));
        seen = mix(fogColour, seen, exp(-layers[i].distance * sigma));
        colour = mix(colour, seen, coverage);
        transmittance *= 1.0 - coverage;
    }
    return float4(colour, transmittance);
}

// MARK: - Glass pass (full resolution)

struct Drops {
    float2 offset;
    float mask;
    float trail;
};

// Drops on the outside of the glass: beads that sit, and runnels that slide.
Drops glassDrops(float2 q, float time, float wet) {
    Drops d;
    d.offset = 0.0;
    d.mask = 0.0;
    d.trail = 0.0;
    if (wet < 0.01) return d;
    // Beads, in a jittered grid about a centimetre apart.
    for (int layer = 0; layer < 1; layer++) {
        float cell = 0.013;
        float2 g = q / cell + float(layer) * 13.7;
        float2 id = floor(g);
        float2 local = fract(g) - 0.5;
        float2 h = hash22(id);
        float life = fract(time * (0.015 + h.y * 0.02) + h.x);
        float present = step(h.x, wet * 0.38) * smoothstep(0.0, 0.1, life) * smoothstep(1.0, 0.7, life);
        float2 centre = (h - 0.5) * 0.6;
        float radius = mix(0.12, 0.3, hash12(id + 3.1));
        float2 v = (local - centre) / radius;
        float r2 = dot(v, v);
        float inside = present * (1.0 - smoothstep(0.7, 1.0, r2));
        d.offset += -v * inside * radius * cell * 1.6;
        d.mask = max(d.mask, inside);
    }
    // Runnels: one per column, sliding in fits and starts, leaving a clear trail.
    float column = 0.035;
    float2 g = q / float2(column, 1.0);
    float id = floor(g.x);
    float h = hash12(float2(id, 4.2));
    if (h < wet * 0.8) {
        float speed = 0.03 + 0.05 * h;
        float t = time * speed + h * 10.0;
        float jerk = t + 0.12 * sin(t * 6.0 + h * 20.0);
        float y = 1.6 - fract(jerk) * 2.4;
        float x = (h - 0.5) * 0.5 + 0.08 * sin(q.y * 9.0 + h * 30.0);
        float2 local = float2((fract(g.x) - 0.5 - x) * column, q.y - y);
        float radius = 0.0035 + 0.002 * h;
        float2 v = local / float2(radius, radius * 1.3);
        float r2 = dot(v, v);
        float inside = 1.0 - smoothstep(0.6, 1.0, r2);
        d.offset += -v * inside * radius * 1.8;
        d.mask = max(d.mask, inside);
        float above = q.y - y;
        float trail = smoothstep(0.004, 0.0, abs(local.x)) * step(0.0, above) * exp(-above * 3.0);
        d.trail = max(d.trail, trail);
    }
    return d;
}

float rainStreaks(float2 px, float time, float amount, float2 fall, float pixelScale) {
    if (amount < 0.01) return 0.0;
    float sum = 0.0;
    float2 dir = normalize(float2(fall.x, 1.0));
    float2 side = float2(dir.y, -dir.x);
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float width = (3.0 + fi * 2.6) * pixelScale;
        float streak = (22.0 + fi * 16.0) * pixelScale;
        float speed = (900.0 + fi * 420.0) * pixelScale;
        float2 p = float2(dot(px, side), dot(px, dir));
        p.y -= time * speed;
        p.x += fi * 37.0;
        float2 cell = floor(p / float2(width, streak));
        float h = hash12(cell + fi * 19.0);
        if (h > amount * (0.22 + fi * 0.05)) continue;
        float2 local = fract(p / float2(width, streak));
        float x = 0.2 + 0.6 * hash12(cell + 2.7);
        float thin = (0.5 + fi * 0.16) * pixelScale;
        float line = smoothstep(thin * 1.6, 0.0, abs(local.x - x) * width);
        float body = smoothstep(0.0, 0.3, local.y) * smoothstep(1.0, 0.5, local.y);
        sum += line * body * (0.12 + fi * 0.07) * (0.6 + 0.4 * hash12(cell + 8.1));
    }
    return sum;
}

float snowFlakes(float2 px, float time, float amount, float2 fall, float pixelScale, thread float& near) {
    near = 0.0;
    if (amount < 0.01) return 0.0;
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float cell = (26.0 + fi * 22.0) * pixelScale;
        float speed = (24.0 + fi * 22.0) * pixelScale;
        float2 p = px;
        p.y -= time * speed;
        p.x -= time * speed * fall.y;
        p.x += sin(time * (0.6 + fi * 0.2) + p.y / (90.0 * pixelScale)) * 9.0 * pixelScale * (1.0 + fi * 0.4);
        float2 id = floor(p / cell);
        float2 h = hash22(id + fi * 7.1);
        if (h.x > amount * (0.5 + fi * 0.12)) continue;
        float2 local = fract(p / cell) - 0.5 - (h - 0.5) * 0.6;
        float radius = (0.7 + fi * 0.75 + h.y * 0.9) * pixelScale;
        float flake = smoothstep(radius, radius * 0.25, length(local) * cell);
        float weight = 0.45 + fi * 0.2;
        sum += flake * weight;
        if (i == 3) near = flake;
    }
    return sum;
}

float3 celestial(float3 dir, constant Frame& f, float pixelAngle, float clear) {
    float3 colour = 0.0;
    // The sun's disc, with a darker limb.
    float3 sunDir = f.sun.xyz;
    float sunRadius = 0.00465;
    float sunCos = dot(dir, sunDir);
    if (sunCos > 0.9995 && f.sunLight.w > 0.0) {
        float sunAngle = acos(clamp(sunCos, -1.0, 1.0));
        float sunDisc = smoothstep(sunRadius + pixelAngle, sunRadius - pixelAngle, sunAngle);
        float limb = sqrt(max(1.0 - pow(sunAngle / sunRadius, 2.0), 0.0));
        // The disc is so bright that even a sliver of thick cloud would let it through; square the clearing so a storm hides it.
        colour += f.sunLight.rgb * sunDisc * (0.6 + 0.4 * limb) * 260.0 * f.sunLight.w * clear;
    }
    // The moon, lit from the sun's true direction so the phase and its tilt are right.
    float3 moonDir = f.moon.xyz;
    float moonRadius = f.moonLight.w;
    float moonCos = dot(dir, moonDir);
    if (moonCos > cos(moonRadius * 4.0)) {
        float3 e1 = normalize(cross(moonDir, float3(0.0, 1.0, 0.0)) + float3(1e-5, 0.0, 0.0));
        float3 e2 = cross(e1, moonDir);
        float2 uv = float2(dot(dir - moonDir, e1), dot(dir - moonDir, e2)) / moonRadius;
        float r = length(uv);
        float edge = smoothstep(1.0 + pixelAngle / moonRadius, 1.0 - pixelAngle / moonRadius, r);
        float3 normal = normalize(uv.x * e1 + uv.y * e2 - sqrt(max(1.0 - r * r, 0.0)) * moonDir);
        float lit = saturate(dot(normal, sunDir) * 1.4 + 0.02);
        float maria = 0.78 + 0.22 * fbm2(uv * 2.2 + 3.0, 3);
        float earthshine = 0.012;
        float3 surface = float3(1.0, 0.97, 0.92) * (lit * maria + earthshine);
        colour += surface * edge * 1.4;
        // A faint aureole where the moon sits behind thin haze.
        colour += float3(0.8, 0.85, 1.0) * f.moon.w * 0.012 * exp(-max(r - 1.0, 0.0) * 2.5) * (1.0 - edge);
        colour *= smoothstep(-0.02, 0.01, moonDir.y);
    }
    // Stars, fixed to the celestial sphere so they wheel with the night.
    float visibility = f.misc.w;
    if (visibility > 0.001 && dir.y > -0.02) {
        float3 q = (f.stars * float4(dir, 0.0)).xyz;
        float3 a = abs(q);
        float face;
        float2 uv;
        if (a.x >= a.y && a.x >= a.z) { face = q.x > 0.0 ? 0.0 : 1.0; uv = q.yz / a.x; }
        else if (a.y >= a.z) { face = q.y > 0.0 ? 2.0 : 3.0; uv = q.xz / a.y; }
        else { face = q.z > 0.0 ? 4.0 : 5.0; uv = q.xy / a.z; }
        const float cells = 128.0;
        float2 id = floor((uv * 0.5 + 0.5) * cells);
        float3 h = hash33(float3(id, face * 131.0));
        float cluster = 0.35 + 1.3 * smoothstep(0.35, 0.75, noise3(q * 3.0 + 11.0));
        if (h.x < 0.045 * cluster) {
            float2 starUV = (id + 0.25 + 0.5 * hash22(id + face * 17.0)) / cells * 2.0 - 1.0;
            float3 s3;
            if (face < 1.5) s3 = float3(face < 0.5 ? 1.0 : -1.0, starUV.x, starUV.y);
            else if (face < 3.5) s3 = float3(starUV.x, face < 2.5 ? 1.0 : -1.0, starUV.y);
            else s3 = float3(starUV.x, starUV.y, face < 4.5 ? 1.0 : -1.0);
            float angle = acos(clamp(dot(q, normalize(s3)), -1.0, 1.0));
            float magnitude = pow(h.y, 9.0);
            float size = pixelAngle * (0.8 + 1.0 * magnitude);
            float twinkle = 0.8 + 0.2 * sin(f.screen.w * (2.0 + h.z * 5.0) + h.z * 40.0);
            float star = exp(-pow(angle / size, 2.0) * 2.0) * (0.006 + 0.16 * magnitude) * twinkle;
            float3 tint = mix(float3(0.8, 0.88, 1.0), float3(1.0, 0.9, 0.78), h.z);
            colour += tint * star * visibility * smoothstep(0.0, 0.08, dir.y);
        }
    }
    return colour;
}

struct BarShade {
    float coverage;
    float lip;
};

// The glazing bars, and a thin light along each edge. The line sits just inside the
// silhouette so the bar reads as a dark metal edge rather than a flat strip.
BarShade glazingBar(float3 p, float pixel, constant Frame& f) {
    float halfWidth = f.trim.w * 0.5;
    BarShade b;
    b.coverage = 0.0;
    b.lip = 0.0;
    for (int i = 0; i < 4; i++) {
        float adx = abs(p.x - f.mullionsX[i]);
        float ady = abs(p.y - f.transomsY[i]);
        float cx = saturate(0.5 - (adx - halfWidth) / pixel);
        float cy = saturate(0.5 - (ady - halfWidth) / pixel);
        float cov = max(cx, cy);
        if (cov > b.coverage) {
            b.coverage = cov;
            bool vertical = cx >= cy;
            float across = (vertical ? adx : ady) / max(halfWidth, 1e-4);
            // A hairline just inside the silhouette. Wide enough to survive the edge, not wide enough to chrome the bar.
            float lip = exp(-pow((across - 0.86) / 0.07, 2.0));
            // Sky light skims the upper edge of a transom more than the lower one.
            if (!vertical) {
                float above = step(f.transomsY[i], p.y);
                lip *= mix(0.45, 1.0, above);
            }
            b.lip = lip;
        }
    }
    return b;
}

// The glass that is open right now. When it fills the allocated pane, it is f.glass,
// so a full window keeps the edge it was drawn with. A smaller opening sits inside that pane.
struct OpenPane {
    float4 rect;
    bool inset;
};

OpenPane openPane(constant Frame& f) {
    float depth = f.depths.x + f.depths.y;
    float k = f.eye.z / max(depth, 1e-4);
    float l = f.opening.x + f.trim.y;
    float r = f.opening.y - f.trim.y;
    float b = f.opening.z + f.trim.z;
    float t = f.opening.w - f.trim.y;
    float x0 = f.eye.x + l * k;
    float x1 = f.eye.x + r * k;
    float y0 = f.eye.y - t * k;
    float y1 = f.eye.y - b * k;
    float4 pane = float4(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1));
    float mismatch = max(max(abs(pane.x - f.glass.x), abs(pane.y - f.glass.y)),
                         max(abs(pane.z - f.glass.z), abs(pane.w - f.glass.w)));
    OpenPane o;
    // A couple of pixels of rounding still counts as the allocated pane, so a full window is not cropped.
    o.inset = mismatch >= 4.0;
    o.rect = o.inset ? pane : f.glass;
    return o;
}

// The sill stays at its designed width, and widens only when the opening grows past it.
float2 sillSpan(constant Frame& f) {
    return float2(min(f.timing.y, f.opening.x), max(f.timing.z, f.opening.y));
}

// Metres from a screen point to the near edge of the glass. Zero on the edge, positive outside it.
float sashInset(float2 px, constant Frame& f) {
    float4 pane = openPane(f).rect;
    float ox = max(pane.x - px.x, px.x - pane.z);
    float oy = max(pane.y - px.y, px.y - pane.w);
    float pxDist = (ox > 0.0 && oy > 0.0) ? length(float2(max(ox, 0.0), max(oy, 0.0))) : max(max(ox, oy), 0.0);
    return pxDist * (f.depths.x + f.depths.y) / f.eye.z;
}

fragment float4 glassFragment(FullscreenOut in [[stage_in]],
                              constant Frame& f [[buffer(0)]],
                              texture2d<float> latest [[texture(0)]],
                              texture2d<float> previous [[texture(1)]]) {
    constexpr sampler linear(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 px = in.position.xy + f.layer.xy;
    OpenPane open = openPane(f);
    float4 pane = open.rect;
    float2 paneInset = min(px - pane.xy, pane.zw - px);
    // Outside a smaller opening the allocated pane is clear, and the wall shows through.
    if (open.inset && min(paneInset.x, paneInset.y) < -1.0) {
        return float4(0.0);
    }
    float time = f.screen.w;
    float pixelScale = f.screen.z;
    float glassDepth = f.depths.x + f.depths.y;
    float3 ray = roomRay(px, f);
    float3 onGlass = ray * glassDepth;
    float metresPerPixel = glassDepth / f.eye.z;
    float2 glassSize = f.glass.zw - f.glass.xy;

    // Water on the glass refracts the view behind it.
    float wet = f.precip.z;
    Drops drops = glassDrops(onGlass.xy, time, wet);
    float2 refracted = px + drops.offset / metresPerPixel;
    float2 uv = (refracted - f.glass.xy) / glassSize;
    float film = wet * (1.0 - drops.trail) * (1.0 - drops.mask) * 1.6;
    // The view outside is rendered a few times a second; crossfading the last two keeps the drift smooth.
    float blend = f.timing.x;
    float4 outside = mix(previous.sample(linear, uv, level(film)), latest.sample(linear, uv, level(film)), blend);
    float3 dir = outdoorDirection(refracted, f);
    float pixelAngle = 1.0 / f.eye.w;

    // The pane quiets in a narrow band inside the sash. The middle of the glass stays sharp.
    float edgePx = min(paneInset.x, paneInset.y);
    float edgeM = max(edgePx, 0.0) * metresPerPixel;
    float onPane = step(0.0, edgePx);
    float diffuse = smoothstep(0.018, 0.0, edgeM) * onPane;
    if (diffuse > 0.001) {
        float4 soft = mix(previous.sample(linear, uv, level(2.0)), latest.sample(linear, uv, level(2.0)), blend);
        outside.rgb = mix(outside.rgb, soft.rgb, diffuse * 0.5);
    }

    float3 colour = outside.rgb;
    colour += celestial(dir, f, pixelAngle * 1.2, outside.a) * outside.a * (1.0 - drops.mask * 0.6);

    // Rain and snow fall between the glass and the hills, lit by the air.
    float3 airLight = f.windowLight.rgb * 0.9;
    float rain = rainStreaks(px, time, f.weather.x, f.precip.xy, pixelScale);
    colour += airLight * 0.45 * rain;
    float nearFlake = 0.0;
    float snow = snowFlakes(px, time, f.weather.y, f.precip.xy, pixelScale, nearFlake);
    colour += airLight * 1.1 * snow;

    // Beads darken at the rim and catch the sky.
    colour *= 1.0 - drops.mask * 0.18;
    colour += f.windowLight.rgb * 0.25 * drops.mask * 0.35;

    // Frost creeps in from the corners on the coldest days.
    float frost = f.weather2.y;
    if (frost > 0.01) {
        float2 paneSize = max(pane.zw - pane.xy, float2(1e-3));
        float2 g = (px - pane.xy) / paneSize;
        float edge = min(min(g.x, 1.0 - g.x), min(g.y, 1.0 - g.y) * 1.3);
        float pattern = fbm2(onGlass.xy * 60.0, 5);
        float crystals = smoothstep(0.0, 0.28 * frost, 0.12 * frost - edge + pattern * 0.12);
        float3 blurred = latest.sample(linear, uv, level(3.0)).rgb;
        colour = mix(colour, blurred * 1.15 + f.windowLight.rgb * 0.2, crystals * 0.8);
    }

    // A short dark rim where the pane meets the sash. The bright line lives on the sash itself.
    float rim = smoothstep(0.009, 0.0, edgeM) * onPane;
    colour *= 1.0 - rim * 0.26;

    // Glazing bars, at the glass plane. Dark in the middle, with a thin light along each edge.
    BarShade bar = glazingBar(onGlass, metresPerPixel, f);
    float bars = bar.coverage;
    float night = f.weather2.w;
    float3 barLight = balancedWindowLight(f) * 0.06;
    float3 barColour = float3(0.03, 0.031, 0.033) * barLight;
    float3 barLip = balancedWindowLight(f) * (0.06 * (1.0 - night));
    barColour += barLip * bar.lip;

    float3 outsideOut = colour * f.exposure.x;
    float3 finalColour = nightVision(outsideOut, night);
    finalColour = mix(finalColour, nightVision(barColour * f.exposure.y, night), bars);
    float alpha = open.inset ? saturate(min(paneInset.x, paneInset.y) + 0.5) : 1.0;
    float3 encoded = dither(encodeSRGB(filmic(finalColour)), px);
    return float4(encoded * alpha, alpha);
}

// MARK: - Room pass (full screen, redrawn on demand)

struct Surface {
    float3 p;
    float3 n;
    float3 albedo;
    int kind;   // 0 wall, 1 sill top, 2 sill front, 3 jamb or head, 4 frame, 5 glass
    float occlusion;
};

Surface findSurface(float2 px, constant Frame& f) {
    float3 ray = roomRay(px, f);
    float left = f.opening.x, right = f.opening.y, bottom = f.opening.z, top = f.opening.w;
    float wall = f.depths.x, reveal = f.depths.y, projection = f.depths.z, thick = f.depths.w;
    float horn = f.trim.x, frame = f.trim.y, rail = f.trim.z;
    float glass = wall + reveal;
    float front = wall - projection;

    float3 plaster = float3(0.6, 0.6, 0.585);
    // A quiet day leans the plaster toward bare concrete. The opening stays where it is.
    float bare = 1.0 - smoothstep(0.05, 0.42, saturate(f.occupation.x));
    float3 wallColour = mix(plaster, float3(0.50, 0.505, 0.515), bare);
    float3 stone = float3(0.56, 0.545, 0.515);
    float3 steel = float3(0.032, 0.033, 0.035);
    float2 sill = sillSpan(f);
    bool shut = (right - left) < 1e-3 || (top - bottom) < 1e-3;

    Surface s;
    s.occlusion = 1.0;

    // The sill's front edge.
    float3 p = ray * front;
    if (p.x > sill.x - horn && p.x < sill.y + horn && p.y < bottom && p.y > bottom - thick) {
        s.p = p; s.n = float3(0, 0, -1); s.albedo = stone * 0.92; s.kind = 2;
        float lip = saturate((bottom - p.y) / thick);
        s.occlusion = 0.85 + 0.15 * lip;
        return s;
    }
    // The sill's top.
    if (ray.y < 0.0) {
        float t = bottom / ray.y;
        p = ray * t;
        if (p.z >= front && p.z <= glass) {
            bool proud = p.z < wall;
            float l = proud ? sill.x - horn : sill.x;
            float r = proud ? sill.y + horn : sill.y;
            if (p.x > l && p.x < r) {
                s.p = p; s.n = float3(0, 1, 0); s.albedo = stone; s.kind = 1;
                float toGlass = glass - p.z;
                float toJamb = proud ? 1.0 : min(p.x - left, right - p.x);
                s.occlusion = (1.0 - 0.35 * exp(-toGlass / 0.03)) * (1.0 - 0.3 * exp(-toJamb / 0.04));
                return s;
            }
        }
    }
    // The wall, except where the opening is. Shut, the wall is unbroken.
    p = ray * wall;
    if (shut || !(p.x > left && p.x < right && p.y > bottom && p.y < top)) {
        s.p = p; s.n = float3(0, 0, -1); s.albedo = wallColour; s.kind = 0;
        // Under the sill's lip.
        float under = bottom - thick - p.y;
        if (under > 0.0 && p.x > sill.x - horn && p.x < sill.y + horn) {
            s.occlusion = 1.0 - 0.45 * exp(-under / 0.035);
        }
        return s;
    }
    // Inside the opening: the reveals.
    if (ray.x < 0.0) {
        float t = left / ray.x;
        p = ray * t;
        if (p.z >= wall && p.z <= glass && p.y >= bottom && p.y <= top) {
            s.p = p; s.n = float3(1, 0, 0); s.albedo = wallColour; s.kind = 3;
            s.occlusion = 1.0 - 0.3 * exp(-(glass - p.z) / 0.04);
            return s;
        }
    }
    if (ray.x > 0.0) {
        float t = right / ray.x;
        p = ray * t;
        if (p.z >= wall && p.z <= glass && p.y >= bottom && p.y <= top) {
            s.p = p; s.n = float3(-1, 0, 0); s.albedo = wallColour; s.kind = 3;
            s.occlusion = 1.0 - 0.3 * exp(-(glass - p.z) / 0.04);
            return s;
        }
    }
    if (ray.y > 0.0) {
        float t = top / ray.y;
        p = ray * t;
        if (p.z >= wall && p.z <= glass && p.x >= left && p.x <= right) {
            s.p = p; s.n = float3(0, -1, 0); s.albedo = wallColour * 0.97; s.kind = 3;
            s.occlusion = 1.0 - 0.3 * exp(-(glass - p.z) / 0.04);
            return s;
        }
    }
    // The frame and the glass, at the back of the opening.
    p = ray * glass;
    bool inGlass = p.x > left + frame && p.x < right - frame && p.y > bottom + rail && p.y < top - frame;
    s.p = p; s.n = float3(0, 0, -1);
    s.albedo = steel;
    s.kind = inGlass ? 5 : 4;
    return s;
}

// Coverage of the weeds around one edge. p.x runs across the edge, p.y up from the sill.
struct WeedCover {
    float stem;
    float leaf;
    float warm;
    float cool;
};

WeedCover weedPatch(float2 p, float root, float sign, float bottom, float seed, float salt,
                    float aa, float amount, int count, float spread, float height, float blooms) {
    WeedCover w;
    w.stem = 0.0;
    w.leaf = 0.0;
    w.warm = 0.0;
    w.cool = 0.0;
    float width = max(aa * 1.7, 0.0045);
    float rise = p.y - bottom;
    for (int i = 0; i < 5; i++) {
        if (i >= count) break;
        float fi = float(i);
        float on = saturate(amount * float(count) - fi);
        if (on <= 0.0) continue;
        float2 h = hash22(float2(fi * 2.7 + salt, seed + 1.7));
        float hgt = height * (0.22 + 0.78 * h.y);
        float x0 = root + sign * spread * (0.04 + 0.55 * h.x);
        float lean = (h.x - 0.35) * spread * 0.85;
        float t = saturate(rise / max(hgt, 1e-3));
        float sway = sin(t * 2.4 + h.y * 5.1) * spread * 0.12 * t * t;
        float x = x0 + sign * sway + lean * t;
        float d = abs(p.x - x);
        float tip = 1.0 - smoothstep(0.78, 1.0, t);
        float stem = (1.0 - smoothstep(width * 0.3, width, d)) * tip * step(-0.005, rise) * step(rise, hgt + width);
        w.stem = max(w.stem, stem * on);
        // A leaf or two, turned, and only on some of the stems. The rest stay dry.
        if (h.x > 0.38) {
            float lt = 0.46 + 0.28 * h.y;
            float swayL = sin(lt * 2.4 + h.y * 5.1) * spread * 0.12 * lt * lt;
            float lx = x0 + sign * swayL + lean * lt + sign * 0.008;
            float ang = (h.y - 0.5) * 2.2 + sign * 0.6;
            float2 q = float2(p.x - lx, rise - hgt * lt);
            float2 r = float2(q.x * cos(ang) - q.y * sin(ang), q.x * sin(ang) + q.y * cos(ang));
            w.leaf = max(w.leaf, (1.0 - smoothstep(0.62, 1.0, length(r / float2(0.016, 0.008)))) * on);
        }
        // One dull bloom on the tallest stem. It stays darker than the plaster, so night does not light it.
        if (blooms > 0.5 && i == 0 && h.y > 0.45) {
            float swayT = sin(0.9 * 2.4 + h.y * 5.1) * spread * 0.12 * 0.81;
            float tx = x0 + sign * swayT + lean * 0.9;
            float rad = 0.010 + 0.006 * h.x;
            float2 b = float2(p.x - tx, rise - hgt * 0.9);
            float disc = 1.0 - smoothstep(rad * 0.35, rad, length(b));
            float which = step(0.5, h.x);
            w.warm = max(w.warm, disc * which * on);
            w.cool = max(w.cool, disc * (1.0 - which) * on);
        }
    }
    return w;
}

void paintWeeds(thread float3& albedo, WeedCover w, float vine) {
    albedo = mix(albedo, float3(0.26, 0.23, 0.16), w.stem);
    albedo = mix(albedo, float3(0.17, 0.22, 0.13), w.leaf * vine);
    albedo = mix(albedo, float3(0.42, 0.38, 0.30), w.warm * vine);
    albedo = mix(albedo, float3(0.36, 0.36, 0.42), w.cool * vine);
}

// Moss in the joints, then dry stems, then a few leaves and small flowers. The top of the frame stays clear.
float3 withGrowth(Surface s, constant Frame& f) {
    float3 albedo = s.albedo;
    float g = saturate(f.occupation.x);
    float openW = f.opening.y - f.opening.x;
    float openH = f.opening.w - f.opening.z;
    if (g < 0.02 || openW < 0.05 || openH < 0.05) return albedo;

    float moss = smoothstep(0.10, 0.32, g);
    float stems = smoothstep(0.40, 0.64, g);
    float vine = smoothstep(0.72, 0.94, g);
    float seed = f.misc.x;
    float aa = max(s.p.z, 0.2) / max(f.eye.z, 1.0);
    float left = f.opening.x, right = f.opening.y, bottom = f.opening.z;

    if (s.kind == 0) {
        float lived = smoothstep(0.28, 0.75, g);
        if (lived > 0.001) {
            float mottling = (fbm2(s.p.xy * 1.35 + seed, 3) - 0.5) * 0.045 * lived;
            albedo *= 1.0 + mottling;
        }
        float side = 0.0;
        float outward = 0.0;
        if (s.p.x < left) { side = -1.0; outward = left - s.p.x; }
        else if (s.p.x > right) { side = 1.0; outward = s.p.x - right; }
        float rise = s.p.y - bottom;
        if (side != 0.0 && outward < 0.22 && rise > -0.04 && rise < 0.48) {
            if (moss > 0.001 && outward < 0.14 && rise < 0.12) {
                float patch = fbm2(s.p.xy * 11.0 + seed, 3);
                float m = exp(-outward / 0.07) * exp(-max(rise, 0.0) / 0.06) * smoothstep(0.28, 0.58, patch);
                albedo = mix(albedo, float3(0.13, 0.17, 0.11), m * moss);
            }
            if (stems > 0.001) {
                float root = side < 0.0 ? left : right;
                WeedCover w = weedPatch(s.p.xy, root, side, bottom, seed, side * 2.0, aa, stems, 4, 0.13, 0.32, 1.0);
                paintWeeds(albedo, w, vine);
            }
        }
    } else if (s.kind == 1 && moss > 0.001) {
        // Only the crack where the sill meets the glass, heavier toward the jambs. The stone stays stone.
        float glass = f.depths.x + f.depths.y;
        float rear = 1.0 - smoothstep(0.006, 0.028, glass - s.p.z);
        float along = abs(s.p.x) / max(abs(right), 0.2);
        float end = smoothstep(0.45, 0.9, along);
        float patch = 0.55 + 0.45 * fbm2(s.p.xz * 26.0 + seed, 3);
        float m = rear * patch * mix(0.2, 1.0, end);
        albedo = mix(albedo, float3(0.24, 0.28, 0.20), m * moss * 0.8);
    } else if (s.kind == 3 && abs(s.n.x) > 0.5) {
        float rise = s.p.y - bottom;
        if (moss > 0.001 && rise < 0.22) {
            float patch = fbm2(s.p.yz * 12.0 + seed, 3);
            float m = exp(-max(rise, 0.0) / 0.07) * smoothstep(0.30, 0.58, patch);
            albedo = mix(albedo, float3(0.20, 0.24, 0.16), m * moss * 0.85);
        }
        if (stems > 0.001 && rise > -0.02 && rise < 0.40) {
            float salt = s.n.x > 0.0 ? -5.0 : 5.0;
            WeedCover w = weedPatch(float2(s.p.z, s.p.y), f.depths.x + 0.02, 1.0, bottom, seed, salt, aa, stems, 3, 0.09, 0.20, 0.0);
            paintWeeds(albedo, w, vine);
        }
    }
    return albedo;
}

// Even light in the room, with no bulb and no colour from the cover.
// The 0.18 sits on Lighting.lampIntensity (f.exposure.w) so a night wall stays readable.
float3 roomFill(constant Frame& f) {
    return float3(1.0, 0.96, 0.90) * f.exposure.w * 0.18;
}

float3 shadeRoomSurface(Surface s, constant Frame& f, float2 px) {
    float3 light = roomFill(f);

    // The window as an area light, glowing with whatever is outside. The wall and the sill's edge face away from it.
    float3 windowLight = balancedWindowLight(f);
    if (s.kind == 1 || s.kind == 3) {
        float glass = f.depths.x + f.depths.y;
        float l = f.opening.x + f.trim.y, r = f.opening.y - f.trim.y;
        float b = f.opening.z + f.trim.z, t = f.opening.w - f.trim.y;
        // A shut or tiny opening is not a light. A zero-area quad would break the form factor.
        if ((r - l) > 0.02 && (t - b) > 0.02) {
            float formFactor = quadIrradiance(s.p, s.n, float3(l, b, glass), float3(r, b, glass), float3(r, t, glass), float3(l, t, glass));
            light += windowLight * formFactor * 2.4;
        }
    }

    // Light that has bounced around the room behind the viewer.
    // Bounce from the floor lifts the lower wall a little; the ceiling side stays darker.
    float height = saturate((s.p.y + 1.2) / 2.6);
    // Daylight fill fades with the opening, down to Opening.lightFloor.
    // Below that the hole can still close, and the wall stays readable.
    float openness = max(saturate(f.timing.w), 0.22);
    light += windowLight * 0.16 * (1.12 - 0.3 * height) * openness;

    // Plaster is never perfectly flat. A bare wall is a little flatter.
    float3 albedo = withGrowth(s, f);
    float lived = smoothstep(0.0, 0.5, saturate(f.occupation.x));
    float grain = 0.985 + mix(0.012, 0.03, lived) * noise2(s.p.xy * 3.0 + s.p.z);
    float3 colour = albedo * light * s.occlusion * grain;

    // The sash is a dark edge with one bright line on the side that meets the glass.
    // Added after the albedo, or the metal would swallow it.
    if (s.kind == 4) {
        float inset = sashInset(px, f);
        float pixelM = (f.depths.x + f.depths.y) / f.eye.z;
        float sigma = max(pixelM * 0.75, 0.0012);
        float lip = exp(-pow(inset / sigma, 2.0));
        float bevel = exp(-inset / max(pixelM * 5.0, 0.01));
        float night = f.weather2.w;
        float3 window = balancedWindowLight(f);
        // By day the sky draws the line. At night the sash stays a dark edge.
        colour += window * (0.05 * bevel + 0.22 * lip) * (1.0 - night);
    }
    return colour;
}

fragment float4 roomFragment(FullscreenOut in [[stage_in]], constant Frame& f [[buffer(0)]]) {
    float2 base = in.position.xy + f.layer.xy;
    const float2 offsets[4] = { float2(-0.125, -0.375), float2(0.375, -0.125), float2(0.125, 0.375), float2(-0.375, 0.125) };
    float3 sum = 0.0;
    float night = f.weather2.w;
    // A soft falloff toward the corners of the room.
    float2 centred = (base - f.screen.xy * 0.5) / f.screen.xy;
    float vignette = 1.0 - 0.32 * smoothstep(0.15, 0.75, length(centred * float2(1.0, 1.25)));
    Surface samples[4];
    bool uniform = true;
    for (int i = 0; i < 4; i++) {
        samples[i] = findSurface(base + offsets[i], f);
        if (samples[i].kind != samples[0].kind) uniform = false;
    }
    if (uniform) {
        // Inside one surface the shading is smooth, so one sample stands for all four.
        Surface s = findSurface(base, f);
        float3 radiance = s.kind == 5 ? float3(0.0) : shadeRoomSurface(s, f, base) * vignette;
        sum = filmic(nightVision(radiance * f.exposure.y, night)) * 4.0;
    } else {
        for (int i = 0; i < 4; i++) {
            float3 radiance = samples[i].kind == 5 ? float3(0.0) : shadeRoomSurface(samples[i], f, base + offsets[i]) * vignette;
            sum += filmic(nightVision(radiance * f.exposure.y, night));
        }
    }
    return float4(dither(encodeSRGB(sum * 0.25), base), 1.0);
}

// MARK: - Objects on the sill (redrawn on demand)

struct ObjectVertex {
    float4 position;  // xyz world (m) or screen px, w: 0 world, 1 screen
    float4 normal;    // xyz normal, w face: 0 cover, 1 back, 2 edge
    float4 uv;        // xy texture, zw extra
};

struct ObjectOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
    float4 extra;
    float face;
};

vertex ObjectOut objectVertex(uint vid [[vertex_id]],
                              const device ObjectVertex* vertices [[buffer(0)]],
                              constant Frame& f [[buffer(1)]]) {
    ObjectVertex v = vertices[vid];
    ObjectOut out;
    float2 px;
    float w = 1.0;
    if (v.position.w < 0.5) {
        float3 p = v.position.xyz;
        px = f.eye.xy + float2(p.x, -p.y) * (f.eye.z / p.z);
        w = p.z;
    } else {
        px = v.position.xy;
    }
    float2 local = px - f.layer.xy;
    float2 ndc = float2(local.x / f.layer.z * 2.0 - 1.0, 1.0 - local.y / f.layer.w * 2.0);
    out.position = float4(ndc * w, 0.5 * w, w);
    out.world = v.position.xyz;
    out.normal = v.normal.xyz;
    out.uv = v.uv.xy;
    out.extra = float4(v.uv.zw, 0.0, 0.0);
    out.face = v.normal.w;
    return out;
}

// 1 while the sleeve stands, 0 once it has laid down. Matches SillGeometry.sleevePresence.
float sleevePresence(float pose) {
    // Gone before the card lies flat, so the plain back never rests on the sill.
    float t = saturate(pose / 0.40);
    return 1.0 - t * t * (3.0 - 2.0 * t);
}

float3 objectLight(float3 n, constant Frame& f) {
    float3 windowLight = balancedWindowLight(f);
    // The cover faces the room, so the window is fill. A little shaping keeps the card from looking flat.
    float wrap = saturate(dot(n, normalize(float3(0.0, 0.15, -1.0))) * 0.35 + 0.75);
    return (windowLight * 0.2 + roomFill(f)) * wrap;
}

fragment float4 sleeveFragment(ObjectOut in [[stage_in]],
                               constant Frame& f [[buffer(0)]],
                               texture2d<float> cover [[texture(0)]],
                               texture2d<float> previous [[texture(1)]]) {
    constexpr sampler linear(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 n = normalize(in.normal);
    float3 albedo;
    if (in.face < 0.5) {
        float3 now = cover.sample(linear, in.uv).rgb;
        float3 before = previous.sample(linear, in.uv).rgb;
        albedo = mix(before, now, f.sleeve2.z) * 0.92;
    } else if (in.face < 1.5) {
        // The plain back: card, with the faint ring the record has pressed into it.
        float2 c = in.uv - 0.5;
        float ring = smoothstep(0.012, 0.0, abs(length(c) - 0.46)) * 0.03;
        float paper = 0.97 + 0.03 * fbm2(in.uv * 40.0, 3);
        albedo = float3(0.74, 0.72, 0.67) * paper * (1.0 - ring);
    } else {
        albedo = float3(0.62, 0.6, 0.56);
    }
    float3 light = objectLight(n, f);
    float3 colour = albedo * light;
    float presence = sleevePresence(f.sleeve.w);
    float3 c = nightVision(colour * f.exposure.y, f.weather2.w);
    float3 encoded = dither(encodeSRGB(filmic(c)), in.position.xy);
    return float4(encoded * presence, presence);
}

fragment float4 shadowFragment(ObjectOut in [[stage_in]], constant Frame& f [[buffer(0)]]) {
    // uv runs from -1 to 1 across the soft box; extra holds the solid fraction on each axis.
    float2 q = abs(in.uv);
    float2 solid = in.extra.xy;
    float2 e = saturate((q - solid) / max(1.0 - solid, 1e-3));
    float falloff = 1.0 - saturate(length(e));
    float a = falloff * falloff * in.normal.x;
    return float4(0.0, 0.0, 0.0, a);
}

fragment float4 labelFragment(ObjectOut in [[stage_in]],
                              constant Frame& f [[buffer(0)]],
                              texture2d<float> text [[texture(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float coverage = text.sample(linear, in.uv).r;
    float3 ink = in.extra.xxx;
    float a = coverage * f.misc.z * in.extra.y;
    return float4(ink * a, a);
}

// MARK: - Composite (lab only): place a finished layer over another with premultiplied alpha

struct CompositeOut {
    float4 position [[position]];
    float2 uv;
};

vertex CompositeOut compositeVertex(uint vid [[vertex_id]], constant float4& rect [[buffer(0)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    CompositeOut out;
    out.position = float4(mix(rect.xy, rect.zw, corner), 0.0, 1.0);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

fragment float4 compositeFragment(CompositeOut in [[stage_in]], texture2d<float> layer [[texture(0)]]) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    return layer.sample(nearest, in.uv);
}
