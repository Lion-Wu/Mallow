#include <metal_stdlib>
using namespace metal;

struct VoiceMotionUniforms {
    float2 resolution;
    float time;
    float stateTime;
    float4 stateWeights;
    float4 stateData;
    float4 audio;
    float4 dynamics;
    float4 accent;
    float4 controls;
    float4 layout;
    float2 connectingInterval;
};

constant float TAU = 6.28318530717958647692;
constant int MORPH_CELL_COUNT = 5;
constant int SPEAKING_BAR_COUNT = 4;
constant float SPEAKING_LAYOUT_CODE_MAX = 1023.0;
constant float CONNECTING_ROTATION_SPEED = 1.35;
// Control width and total height independently while retaining round caps.
constant float SPEAKING_HEIGHT_RATIO = 0.90;
constant float SPEAKING_WIDTH_RATIO = 1.08;
constant float3 ERROR_ACCENT_LINEAR = float3(0.37626212, 0.39675523, 0.43415364);

float saturateValue(float value) { return clamp(value, 0.0, 1.0); }
float wrapPhase(float phase) { return fmod(fmod(phase, TAU) + TAU, TAU); }
float smoother(float value) {
    value = saturateValue(value);
    return value * value * value * (value * (value * 6.0 - 15.0) + 10.0);
}
float easedWeight(float value) {
    value = saturateValue(value);
    return value * value * (3.0 - 2.0 * value);
}
float smoothMin(float a, float b, float radius) {
    float h = clamp(0.5 + 0.5 * (b - a) / max(radius, 0.0001), 0.0, 1.0);
    return mix(b, a, h) - radius * h * (1.0 - h);
}
float dominantStateWeight(float4 weights, float errorWeight) {
    return max(max(max(weights.x, weights.y), max(weights.z, weights.w)), errorWeight);
}
float transitionAmount(float4 weights, float errorWeight) {
    return smoother((1.0 - dominantStateWeight(weights, errorWeight)) * 2.2);
}

float sharedOrbitPhase(float time, float seed) {
    // The controller integrates this clock; changing motion scale never rephases it.
    float clockwisePhase = time * 0.68
        + 0.16 * sin(time * 0.63 + 0.2)
        + 0.07 * sin(time * 1.17 + 1.1);
    return wrapPhase(seed * TAU - clockwisePhase);
}

float2 circularOrbitPosition(float phase, float radius) {
    return float2(cos(phase), sin(phase)) * radius;
}

float4 connectingCell(
    float time,
    float motion,
    float presence,
    float seed
) {
    float phase = sharedOrbitPhase(time * CONNECTING_ROTATION_SPEED, seed);
    float orbit = 0.141 + motion * presence * (
        0.007 * sin(time * 0.93 + 0.3)
        + 0.003 * sin(time * 1.77 + 1.4)
    );
    return float4(circularOrbitPosition(phase, orbit), 0.022, 0.0);
}

float4 listeningCell(float time, float4 audio, float motion) {
    float rms = saturateValue(audio.x);
    float response = pow(rms, 0.58);
    float radius = 0.116 + motion * (
        0.0010 * sin(time * 0.92 + 0.4)
        + 0.022 * response
    );
    return float4(0.0, 0.0, radius, 0.0);
}

int speakingBarIndex(int cellIndex, float packedLayout) {
    int code = int(floor(clamp(packedLayout, 0.0, SPEAKING_LAYOUT_CODE_MAX) + 0.5));
    int divisor = 1;
    if (cellIndex == 1) divisor = 4;
    else if (cellIndex == 2) divisor = 16;
    else if (cellIndex == 3) divisor = 64;
    else if (cellIndex >= 4) divisor = 256;
    return (code / divisor) % SPEAKING_BAR_COUNT;
}

float4 thinkingCell(
    int index,
    float time,
    float motion,
    float presence,
    float seed
) {
    float slot = TAU * float(index) / float(MORPH_CELL_COUNT);
    float activity = min(motion, 1.4) * presence;
    float phase = sharedOrbitPhase(time, seed) + slot + activity * (
        0.16 * sin(time * 0.91 + slot)
        + 0.055 * sin(time * 1.37 - 2.0 * slot + 0.6)
    );
    float radial = 0.109 + activity * (
        0.014 * sin(time * 0.73 + slot + 0.35)
        + 0.006 * sin(time * 1.31 - 2.0 * slot + 0.8)
    );
    // The five volume terms sum to five: mass moves between the droplets.
    float volume = 1.0 + activity * (
        0.18 * sin(time * 0.93 + slot)
        + 0.06 * sin(time * 1.31 - 2.0 * slot + 0.4)
    );
    float radius = 0.0305 * sqrt(max(volume, 0.5));
    return float4(circularOrbitPosition(phase, radial), radius, 0.0);
}

float4 speakingBarCell(
    int index,
    float time,
    float4 audio,
    float motion,
    float presence
) {
    float item = float(index);
    float normalized = (item - 1.5) / 1.5;
    float rms = saturateValue(audio.x);
    float low = saturateValue(audio.y);
    float mid = saturateValue(audio.z);
    float high = saturateValue(audio.w);
    float energy = pow(rms, 0.74) * saturateValue(motion);
    float band = mix(mid, low, saturateValue(-normalized));
    band = mix(band, high, saturateValue(normalized));
    float cadence = 1.0 + 0.16 * sin(time * 2.35 + item * 1.47)
        + 0.07 * sin(time * 1.11 - item * 0.8);
    float profile = 1.0 - 0.08 * abs(normalized);
    float extension = energy * (0.028 + 0.026 * band) * cadence * profile;
    float radius = 0.0235 / sqrt(1.0 + 0.24 * energy * (0.4 + 0.6 * band));
    float stem = 0.014 + 0.003 * (1.0 - abs(normalized)) + extension;
    float halfHeight = (radius + stem) * SPEAKING_HEIGHT_RATIO;
    radius *= SPEAKING_WIDTH_RATIO;
    stem = max(halfHeight - radius, 0.0);
    float y = 0.0022 * sin(time * 1.21 + item * 1.6) * energy * presence;
    float x = normalized * (0.105 - 0.0018 * energy);
    return float4(x, y, radius, stem);
}

float4 speakingCell(
    int cellIndex,
    float time,
    float4 audio,
    float motion,
    float presence,
    float packedLayout
) {
    return speakingBarCell(
        speakingBarIndex(cellIndex, packedLayout),
        time,
        audio,
        motion,
        presence
    );
}

float4 errorCell() {
    return float4(0.0, 0.0, 0.116, 0.0);
}

float liquidCellDistance(
    float2 local,
    float4 cell,
    int cellIndex,
    int barIndex,
    float time,
    float4 audio,
    float motion,
    float4 weights,
    float seed
) {
    float connecting = smoother(weights.x);
    float listening = smoother(weights.y);
    float thinking = smoother(weights.z);
    float speaking = smoother(weights.w);
    float slot = TAU * float(cellIndex) / float(MORPH_CELL_COUNT);
    float item = float(barIndex);
    float energy = saturateValue(audio.x);
    float voiceResponse = pow(energy, 0.58);
    float2 mode2 = float2(0.0);
    float2 mode3 = float2(0.0);
    float2 mode4 = float2(0.0);

    // Independent standing and travelling modes change the contour itself.
    // Opposite phases and unequal rates prevent a rigidly rotating silhouette.
    if (listening > 0.00001) {
        mode2 += listening * float2(
            0.030 * sin(time * 0.83 + 0.2)
                + 0.019 * sin(time * 1.37 + 1.4)
                + 0.210 * audio.y - 0.090 * audio.z
                + 0.085 * voiceResponse * cos(time * 0.91),
            0.028 * sin(time * 0.61 + 1.9)
                + 0.015 * sin(time * 1.19 - 0.5)
                + 0.150 * audio.x - 0.070 * audio.w
                + 0.085 * voiceResponse * sin(time * 0.91)
        );
        mode3 += listening * float2(
            (0.022 + 0.090 * audio.z + 0.050 * voiceResponse) * sin(time * 1.13 + 0.7)
                + 0.016 * audio.w * sin(time * 2.31 + 1.2),
            (0.018 + 0.075 * audio.y + 0.050 * voiceResponse) * cos(time * 0.79 + 1.6)
                + 0.015 * audio.w * cos(time * 1.57 + 0.8)
        );
        mode4 += listening * float2(
            0.005 * sin(time * 0.97 + 2.0) + 0.009 * audio.w,
            0.004 * cos(time * 1.29 + 0.4) - 0.006 * audio.z
        );
    }

    if (connecting > 0.00001) {
        float tangent = sharedOrbitPhase(time * CONNECTING_ROTATION_SPEED, seed)
            - TAU * 0.25;
        // The contour changes independently of the orbit, passing through round,
        // stretched and softly asymmetric shapes instead of carrying a fixed drop.
        float stretch = 0.022 * sin(time * 1.83 + 0.6)
            + 0.012 * sin(time * 2.71 + 1.9);
        float axis = tangent + 0.42 * sin(time * 1.17);
        mode2 += connecting * stretch * float2(cos(2.0 * axis), sin(2.0 * axis));
        mode3 += connecting * float2(
            0.012 * sin(time * 2.13 + 0.4),
            0.010 * cos(time * 1.57 + 1.2)
        );
        mode4 += connecting * float2(
            0.003 * sin(time * 2.47),
            0.003 * cos(time * 1.91 + 0.8)
        );
    }

    if (thinking > 0.00001) {
        float axis = sharedOrbitPhase(time, seed) + slot + 0.55 * sin(time * 0.87 + slot);
        float stretch = 0.095 * sin(time * 1.17 + slot)
            + 0.040 * sin(time * 1.81 - 2.0 * slot + 0.4);
        mode2 += thinking * stretch * float2(cos(2.0 * axis), sin(2.0 * axis));
        mode3 += thinking * float2(
            0.024 * sin(time * 1.09 + slot + 0.3),
            0.020 * cos(time * 1.43 - slot)
        );
    }

    float bend = 0.0;
    if (speaking > 0.00001) {
        mode2 += speaking * float2(
            0.016 * energy * sin(time * 1.31 + item)
                + 0.026 * (audio.y - audio.z),
            0.018 * energy * sin(time * 1.07 + item * 1.3)
        );
        mode3 += speaking * float2(
            0.014 * energy * cos(time * 1.19 + item),
            0.024 * (audio.z - 0.6 * audio.w)
        );
        bend = speaking * (0.0016 * energy * sin(time * 0.91 + item * 1.13)
            + 0.0020 * (audio.z - audio.y)) * motion;
    }

    mode2 *= motion;
    mode3 *= motion;
    mode4 *= motion;
    float amplitude = length(mode2) + length(mode3) + length(mode4);
    float contourLimit = 0.18 + 0.08 * listening * voiceResponse;
    float limiter = min(1.0, contourLimit / max(amplitude, 0.0001));
    mode2 *= limiter;
    mode3 *= limiter;
    mode4 *= limiter;

    float radius = max(cell.z, 0.001);
    float stem = max(cell.w, 0.0);
    float span = max(radius + stem, 0.001);
    float height = local.y * rsqrt(span * span + local.y * local.y);
    local.x -= bend * height * height;
    float2 cap = float2(local.x, local.y - clamp(local.y, -stem, stem));
    float radial = length(cap);
    // Use a continuous direction across the capsule's straight/cap joins.
    float2 surface = float2(local.x, local.y * radius / span);
    float2 direction = surface / max(length(surface), 0.00001);
    float2 harmonic2 = float2(
        direction.x * direction.x - direction.y * direction.y,
        2.0 * direction.x * direction.y
    );
    float2 harmonic3 = float2(
        harmonic2.x * direction.x - harmonic2.y * direction.y,
        harmonic2.x * direction.y + harmonic2.y * direction.x
    );
    float2 harmonic4 = float2(
        harmonic2.x * harmonic2.x - harmonic2.y * harmonic2.y,
        2.0 * harmonic2.x * harmonic2.y
    );
    float contour = dot(mode2, harmonic2) + dot(mode3, harmonic3)
        + dot(mode4, harmonic4);
    float slope = 2.0 * dot(mode2, float2(-harmonic2.y, harmonic2.x))
        + 3.0 * dot(mode3, float2(-harmonic3.y, harmonic3.x))
        + 4.0 * dot(mode4, float2(-harmonic4.y, harmonic4.x));
    // Exact area normalization for circular cells, with a bounded contour slope.
    float areaScale = rsqrt(1.0 + 0.5 * (
        dot(mode2, mode2) + dot(mode3, mode3) + dot(mode4, mode4)
    ));
    float distance = radial - radius * areaScale * (1.0 + contour);
    float relativeSlope = slope / max(1.0 + contour, 0.5);
    return distance * rsqrt(1.0 + relativeSlope * relativeSlope);
}

float speakingBarDistance(
    int barIndex,
    float2 point,
    float time,
    float4 audio,
    float motion,
    float seed
) {
    float4 cell = speakingBarCell(barIndex, time, audio, motion, 1.0);
    return liquidCellDistance(
        point - cell.xy, cell, 0, barIndex, time, audio, motion,
        float4(0.0, 0.0, 0.0, 1.0), seed
    );
}

float4 morphCellDescriptor(
    int index,
    float time,
    float4 weights,
    float errorWeight,
    float4 audio,
    float motion,
    float speakingLayoutCode,
    float seed
) {
    float4 blendWeights = float4(
        easedWeight(weights.x),
        easedWeight(weights.y),
        easedWeight(weights.z),
        easedWeight(weights.w)
    );
    float errorBlend = easedWeight(errorWeight);
    float blendSum = dot(blendWeights, float4(1.0)) + errorBlend;
    blendWeights /= max(blendSum, 0.00001);
    errorBlend /= max(blendSum, 0.00001);

    float4 cell = float4(0.0);
    if (blendWeights.x > 0.00001) {
        cell += connectingCell(
            time,
            motion,
            smoother(weights.x),
            seed
        ) * blendWeights.x;
    }
    if (blendWeights.y > 0.00001) {
        cell += listeningCell(time, audio, motion) * blendWeights.y;
    }
    if (blendWeights.z > 0.00001) {
        cell += thinkingCell(
            index,
            time,
            motion,
            smoother(weights.z),
            seed
        ) * blendWeights.z;
    }
    if (blendWeights.w > 0.00001) {
        cell += speakingCell(
            index,
            time,
            audio,
            motion,
            smoother(weights.w),
            speakingLayoutCode
        ) * blendWeights.w;
    }
    if (errorBlend > 0.00001) {
        cell += errorCell() * errorBlend;
    }
    return cell;
}

float morphCellDistance(
    int index,
    float2 point,
    float time,
    float4 weights,
    float errorWeight,
    float4 audio,
    float motion,
    float speakingLayoutCode,
    float seed
) {
    float4 cell = morphCellDescriptor(
        index,
        time,
        weights,
        errorWeight,
        audio,
        motion,
        speakingLayoutCode,
        seed
    );
    return liquidCellDistance(
        point - cell.xy,
        cell,
        index,
        speakingBarIndex(index, speakingLayoutCode),
        time,
        audio,
        motion,
        weights,
        seed
    );
}

float combinedOuterDistance(
    float2 point,
    float time,
    float4 weights,
    float errorWeight,
    float4 audio,
    float motion,
    float speakingLayoutCode,
    float seed
) {
    if (weights.w > 0.9995) {
        float steady = speakingBarDistance(0, point, time, audio, motion, seed);
        for (int index = 1; index < SPEAKING_BAR_COUNT; ++index) {
            steady = min(
                steady,
                speakingBarDistance(index, point, time, audio, motion, seed)
            );
        }
        return steady;
    }

    if (weights.x > 0.9995 || weights.y > 0.9995 || errorWeight > 0.9995) {
        return morphCellDistance(
            0,
            point,
            time,
            weights,
            errorWeight,
            audio,
            motion,
            speakingLayoutCode,
            seed
        );
    }

    if (weights.z > 0.9995) {
        float steady = morphCellDistance(
            0,
            point,
            time,
            weights,
            errorWeight,
            audio,
            motion,
            speakingLayoutCode,
            seed
        );
        for (int index = 1; index < MORPH_CELL_COUNT; ++index) {
            steady = min(
                steady,
                morphCellDistance(
                    index,
                    point,
                    time,
                    weights,
                    errorWeight,
                    audio,
                    motion,
                    speakingLayoutCode,
                    seed
                )
            );
        }
        return steady;
    }

    float blend = transitionAmount(weights, errorWeight);
    float compactWeight = saturateValue(weights.x + weights.y + errorWeight);
    float compactInfluence = smoother(saturateValue(compactWeight * 1.50));
    float maximumFusion = mix(0.0105, 0.0420, compactInfluence);
    float fusion = mix(0.00015, maximumFusion, blend);
    float distance = morphCellDistance(
        0,
        point,
        time,
        weights,
        errorWeight,
        audio,
        motion,
        speakingLayoutCode,
        seed
    );
    for (int index = 1; index < MORPH_CELL_COUNT; ++index) {
        distance = smoothMin(
            distance,
            morphCellDistance(
                index,
                point,
                time,
                weights,
                errorWeight,
                audio,
                motion,
                speakingLayoutCode,
                seed
            ),
            fusion
        );
    }
    float fusionCompensation = mix(0.08, 0.010, compactInfluence);
    return distance + fusion * fusionCompensation * blend;
}

float3 errorApertureLayout(
    float time,
    float4 weights,
    float errorWeight,
    float4 audio,
    float motion,
    float speakingLayoutCode,
    float seed
) {
    if (errorWeight > 0.9995) return float3(0.0, 0.0, 1.0);

    float2 centerSum = float2(0.0);
    float squaredCenterSum = 0.0;
    for (int index = 0; index < MORPH_CELL_COUNT; ++index) {
        float2 center = morphCellDescriptor(
            index,
            time,
            weights,
            errorWeight,
            audio,
            motion,
            speakingLayoutCode,
            seed
        ).xy;
        centerSum += center;
        squaredCenterSum += dot(center, center);
    }

    float2 center = centerSum / float(MORPH_CELL_COUNT);
    float meanSquaredRadius = squaredCenterSum / float(MORPH_CELL_COUNT);
    float spread = sqrt(max(meanSquaredRadius - dot(center, center), 0.0));
    float consolidation = 1.0 - smoother(saturateValue((spread - 0.010) / 0.030));
    return float3(center, consolidation);
}

float combinedDistance(
    float2 point,
    float time,
    float4 weights,
    float errorWeight,
    float errorApertureProgress,
    float4 audio,
    float motion,
    float speakingLayoutCode,
    float seed,
    thread float &opticalRadius
) {
    float apertureProgress = saturateValue(errorApertureProgress);
    float errorPresence = smoother(errorWeight);
    float settling = 0.022 * sin(TAU * apertureProgress)
        * sin(TAU * 0.5 * apertureProgress) * errorPresence * motion;
    float stretch = exp(settling);
    point = float2(point.x * stretch, point.y / stretch);
    float outer = combinedOuterDistance(
        point,
        time,
        weights,
        errorWeight,
        audio,
        motion,
        speakingLayoutCode,
        seed
    );

    if (errorPresence <= 0.0001 || apertureProgress <= 0.0001) return outer;

    float3 apertureLayout = errorApertureLayout(
        time,
        weights,
        errorWeight,
        audio,
        motion,
        speakingLayoutCode,
        seed
    );
    // The same aperture path is used in both directions. Retargeting a
    // transition changes its acceleration, never the currently visible hole.
    float aperture = easedWeight(saturateValue((apertureProgress - 0.10) / 0.90));
    float holeProgress = aperture * errorPresence * apertureLayout.z;
    if (holeProgress <= 0.0001) return outer;
    float innerRadius = 0.086 * holeProgress;
    opticalRadius = max(opticalRadius - innerRadius, 0.001);
    float outsideInnerCircle = innerRadius - length(point - apertureLayout.xy);
    return max(outer, outsideInnerCircle);
}


// Sweep the actual deformed head along its orbit. The root retains the head's
// full cross-section, then contracts continuously into a single comet contour.
struct ConnectingWake {
    float distance;
    float age;
    float pathAge;
    float headRadius;
    float radius;
    float traveledDistance;
};

ConnectingWake connectingWake(float2 point, float2 interval, float motion, float seed) {
    float time = interval.y;
    float headPhase = sharedOrbitPhase(time * CONNECTING_ROTATION_SPEED, seed);
    float angle = atan2(point.y, point.x) - headPhase;
    float lag = atan2(sin(angle), cos(angle));
    float lifetime = min(2.45 * motion, 2.6);
    float duration = min(lifetime, max(time - interval.x, 0.0));
    float tailPhase = sharedOrbitPhase((time - duration) * CONNECTING_ROTATION_SPEED, seed);
    float arc = max(wrapPhase(tailPhase - headPhase), 0.001);
    float targetPhase = headPhase + clamp(lag, 0.0, arc);
    float sampleTime = time - duration * saturateValue(lag / arc);

    // Invert the actual nonuniform orbit, so shape and position share one time.
    for (int step = 0; step < 3; ++step) {
        float clock = sampleTime * CONNECTING_ROTATION_SPEED;
        float phase = sharedOrbitPhase(clock, seed);
        float difference = atan2(sin(phase - targetPhase), cos(phase - targetPhase));
        float velocity = -CONNECTING_ROTATION_SPEED * (0.68
            + 0.16 * 0.63 * cos(clock * 0.63 + 0.2)
            + 0.07 * 1.17 * cos(clock * 1.17 + 1.1));
        sampleTime = clamp(sampleTime - difference / velocity, time - duration, time);
    }

    // Light decays by elapsed motion time. The contour tapers over the path
    // already travelled, so its initial endpoint cannot become a second head.
    float age = saturateValue((time - sampleTime) / max(lifetime, 0.001));
    float pathAge = saturateValue((time - sampleTime) / max(duration, 0.001));
    float4 cell = connectingCell(sampleTime, motion, 1.0, seed);
    float headRadius = cell.z;
    float taper = max(pow(1.0 - pathAge, 1.25), 0.001);
    // Scale the whole silhouette, including its contour deformation. This also
    // avoids the cell's minimum radius leaving a bright bead at the tail tip.
    float distance = liquidCellDistance(
        (point - cell.xy) / taper, cell, 0, 0, sampleTime, float4(0.0), motion,
        float4(1.0, 0.0, 0.0, 0.0), seed
    ) * taper;
    return { distance, age, pathAge, headRadius, headRadius * taper, arc * length(cell.xy) };
}

// Keep the interior fully opaque. A narrow shoulder at the contour continues
// into a single fading tail, with no separate bloom layers or inner shading.
float motionDensity(float distance, float edgeWidth, float antialias) {
    float width = max(0.65 * antialias, edgeWidth);
    float shoulder = max((distance + width) / width, 0.0);
    return 1.0 / (1.0 + shoulder * shoulder * shoulder);
}

vertex float4 voiceMotionVertex(uint vertexID [[vertex_id]]) {
    float2 position;
    if (vertexID == 0) position = float2(-1.0, -1.0);
    else if (vertexID == 1) position = float2(3.0, -1.0);
    else position = float2(-1.0, 3.0);
    return float4(position, 0.0, 1.0);
}

fragment float4 voiceMotionFragment(
    float4 position [[position]],
    constant VoiceMotionUniforms &uniforms [[buffer(0)]]
) {
    float2 resolution = max(uniforms.resolution, float2(1.0));
    float minimumDimension = min(resolution.x, resolution.y);
    float2 center = uniforms.layout.xy * resolution;
    float controlDiameter = max(
        uniforms.layout.z * minimumDimension,
        1.0
    );
    float2 point = (position.xy - center)
        / (controlDiameter * max(uniforms.layout.w, 0.0001));
    point.y = -point.y;

    float4 weights = max(uniforms.stateWeights, float4(0.0));
    float errorWeight = max(uniforms.stateData.x, 0.0);
    float weightSum = dot(weights, float4(1.0)) + errorWeight;
    if (weightSum <= 0.00001) {
        weights = float4(1.0, 0.0, 0.0, 0.0);
        errorWeight = 0.0;
    } else {
        weights /= weightSum;
        errorWeight /= weightSum;
    }

    // A small feed-forward component keeps speech prompt; signed spring
    // displacement preserves the gentle release instead of clipping it away.
    float4 audio = clamp(mix(uniforms.audio, uniforms.dynamics, 0.72), -0.12, 1.12);
    float motion = clamp(uniforms.controls.x, 0.0, 2.0);
    float errorAppearance = smoother(errorWeight);
    float3 stateAccent = mix(
        max(uniforms.accent.rgb, float3(0.0)),
        ERROR_ACCENT_LINEAR,
        errorAppearance
    );
    float glowStrength = max(uniforms.controls.y, 0.0) * mix(1.0, 0.86, errorAppearance);
    float4 cell = morphCellDescriptor(
        0, uniforms.time, weights, errorWeight, audio, motion,
        uniforms.stateData.z, uniforms.controls.z
    );
    float opticalRadius = cell.z;
    float distance = combinedDistance(
        point,
        uniforms.time,
        weights,
        errorWeight,
        uniforms.stateData.w,
        audio,
        motion,
        uniforms.stateData.z,
        uniforms.controls.z,
        opticalRadius
    );

    // Pixel size stays continuous where the wake's nearest endpoint changes.
    // Differentiating that clamped distance would turn its seam into a streak.
    float antialias = max(length(fwidth(point)), 0.00075);
    float lightAppearance = 1.0 - smoothstep(0.10, 0.60,
        dot(uniforms.accent.rgb, float3(0.2126, 0.7152, 0.0722)));
    float edgeWidth = opticalRadius * (0.04 + 0.02 * glowStrength);
    float bodyDensity = motionDensity(distance, edgeWidth, antialias);
    float3 haloColor = mix(float3(0.82, 0.88, 1.0), float3(0.38, 0.46, 0.56), lightAppearance);
    float wakeDensity = 0.0;
    if (weights.x > 0.0005 && motion > 0.0
        && uniforms.connectingInterval.y > uniforms.connectingInterval.x) {
        ConnectingWake wake = connectingWake(point, uniforms.connectingInterval, motion, uniforms.controls.z);
        float persistence = exp(-mix(3.8, 2.8, lightAppearance) * wake.age)
            * (1.0 - smoother(wake.pathAge));
        float accumulation = smoother(saturateValue(wake.traveledDistance / (2.0 * wake.headRadius)));
        float energy = 0.88 * persistence * accumulation * smoother(weights.x) * saturateValue(motion);
        // The newly emitted wake shares the head's edge; older light disperses
        // gradually while its energy decays along the actual travelled path.
        float dispersion = 0.04 + 0.02 * glowStrength + 0.40 * smoother(wake.age / 0.10);
        float wakeEdgeWidth = max(wake.radius, wake.headRadius * 0.35) * dispersion;
        wakeDensity = motionDensity(wake.distance, wakeEdgeWidth, antialias) * energy;
    }
    // Unite the optical material before shading, so the head/wake junction has
    // neither an independently shaded edge nor overlapping halo layers.
    float opacity = 1.0 - (1.0 - bodyDensity) * (1.0 - wakeDensity);
    float3 color = mix(haloColor, stateAccent, opacity) * opacity;

    // Outside connecting, coverage belongs to the silhouette, not its glow.
    // A one-pixel edge stays sharp at every radius and presentation size.
    float coverage = 1.0 - smoothstep(-0.5 * antialias, 0.5 * antialias, distance);
    // One outward Gaussian carries the glow. Scale its reach with the shape,
    // but keep it translucent so it cannot soften or shade the solid interior.
    float glowWidth = max(opticalRadius * 0.14, antialias);
    float outside = max(distance, 0.0) / glowWidth;
    float glowOpacity = mix(0.16, 0.10, lightAppearance) * glowStrength
        * (1.0 - errorAppearance) * exp(-0.5 * outside * outside);
    float visibleGlow = saturateValue(glowOpacity) * (1.0 - coverage);
    float sharpOpacity = coverage + visibleGlow;
    float3 sharpColor = stateAccent * coverage + haloColor * visibleGlow;
    // Preserve the connecting head and wake exactly, including during startup.
    float connectingAppearance = smoother(weights.x);
    opacity = mix(sharpOpacity, opacity, connectingAppearance);
    color = mix(sharpColor, color, connectingAppearance);
    float alpha = saturateValue(uniforms.accent.a);
    float outputAlpha = opacity * alpha;
    if (outputAlpha <= 0.00001) {
        return float4(0.0);
    }

    return float4(
        color * alpha,
        outputAlpha
    );
}
