// Frame generation for the overlay shim. Included textually by overlay_shim.m
// so the Makefile keeps building one translation unit.
//
// Enabled only by NOTPROTON_FRAMEGEN. Off, nothing in here runs: no hook is
// installed and no object is created, so the per-frame cost is the shim's own.
//
// Environment (users set BRIDGEPLAY_FRAMEGEN*; the run script and np-native pass
// each on under the NOTPROTON_ name read here)
//   NOTPROTON_FRAMEGEN          0|off: disabled. 1|2: 2x, one generated frame at
//                               t=1/2. 3: 3x, two generated frames at t=1/3 and
//                               2/3. adaptive: as many generated frames as fit
//                               before the next real frame, one per refresh
//                               interval and paced to it (up to three).
//   NOTPROTON_FRAMEGEN_QUALITY  performance|balanced|quality (default balanced):
//                               motion is estimated at 1/8, 1/4 or 1/2 of the
//                               frame, with a 5x5 window at the finest level on
//                               quality and 3x3 otherwise.
//   NOTPROTON_FRAMEGEN_UI       1 (default): pixels identical in both real frames
//                               are taken from the newer one unwarped, and pixels
//                               whose forward and backward flows disagree or whose
//                               warped samples differ fall back to the nearer real
//                               frame. 0: plain bidirectional warp.
//   NOTPROTON_FRAMEGEN_FALLBACK 1 (default): a pair whose motion saturates the
//                               search range or whose flow is inconsistent over a
//                               quarter of the textured area shows the nearer real
//                               frame in place of each generated frame, counted as
//                               the "fast-motion" skip. 0: always interpolate.
//   NOTPROTON_FRAMEGEN_ENGINE   own (default) | metalfx. MetalFX generates one
//                               frame per pair whatever the mode; UI protection and
//                               the fallback run as a pass over its output.
//   NOTPROTON_FRAMEGEN_REFRESH_HZ  overrides the detected display refresh (tests).
//
// How it works
//   Real frame N is the drawable the game presents. Its present is diverted:
//   the command buffer that carries the frame (the one calling presentDrawable:,
//   or the Metal 4 bridge buffer, or the last buffer that rendered into the
//   drawable) gets a blit of the drawable into a history texture and a signal
//   on an MTLEvent, and the drawable itself is never presented. A worker
//   thread then, on its own queue and ordered by that event, synthesises the
//   frame between N-1 and N and presents it on a second CAMetalLayer laid over
//   the game's layer, followed by a copy of real frame N half an interval
//   later. The game's layer stops presenting while framegen is active; the
//   overlay layer covers it exactly and inherits format, colorspace and EDR.
//
//   Two engines: MetalFX's MTLFXFrameInterpolator (macOS 26+, fed with the two
//   colour frames, a constant depth and zero motion; it estimates motion
//   itself) and an in-house compute path (luma pyramid, coarse to fine block
//   matching in both directions, bidirectional warp with a mismatch fallback).
//   MetalFX is preferred when the device supports it; NOTPROTON_FRAMEGEN_ENGINE
//   = own|metalfx overrides.
//
//   Pacing: with n generated frames per pair, frame k (1..n) is presented at
//   t_N + lead + (k-1)*step and the real frame at t_N + lead + n*step through
//   presentDrawable:atTime:, where step is interval/(n+1) for the fixed modes
//   and the refresh interval for adaptive. The real frame therefore reaches the
//   glass lead + n*step later than today; lead is the measured generation
//   latency, clamped to [3 ms, step]. Flow is estimated once per pair; each
//   generated frame costs one synthesis pass on top.
//
//   Pass-through (the game's own present goes ahead, overlay layer hidden) on:
//   a second layer, a size or format change (until the worker has rebuilt),
//   game fps at or above the display refresh (refresh/2 for 3x), the worker
//   falling behind, no drawable within the timeout, or any Metal failure.

#import <QuartzCore/CATransaction.h>
#import <dispatch/dispatch.h>
#import <mach/mach_time.h>
#import <math.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <strings.h>

enum fg_multiplier {
	fg_mult_off = 0,
	fg_mult_2x = 2,
	fg_mult_3x = 3,
	fg_mult_adaptive = 4,
};

enum fg_quality {
	fg_quality_performance = 0,
	fg_quality_balanced,
	fg_quality_quality,
};

#define fg_adaptive_max 3 // generated frames per pair at most

static int framegen_enabled;
static int framegen_multiplier; // enum fg_multiplier
static int framegen_quality; // enum fg_quality
static int framegen_ui = 1;
static int framegen_fallback = 1;
static double framegen_refresh_override; // Hz, 0 = detect
static int framegen_engine_pref; // 0 auto, 1 own, 2 metalfx
static int framegen_stats_log;

static const char *fg_multiplier_name(int multiplier)
{
	switch (multiplier) {
	case fg_mult_2x:
		return "2x";
	case fg_mult_3x:
		return "3x";
	case fg_mult_adaptive:
		return "adaptive";
	default:
		return "off";
	}
}

static const char *const fg_quality_names[] = { "performance", "balanced", "quality" };

enum fg_mode {
	fg_mode_idle = 0,
	fg_mode_configuring,
	fg_mode_active,
	fg_mode_passthrough,
};

enum fg_skip {
	fg_skip_other_layer = 0,
	fg_skip_mismatch,
	fg_skip_fast,
	fg_skip_lag,
	fg_skip_no_drawable,
	fg_skip_error,
	fg_skip_unordered,
	fg_skip_warmup,
	fg_skip_settling,
	fg_skip_fast_motion,
	fg_skip_display_dropped,
	fg_skip_double_present,
	fg_skip_count,
};

static const char *const fg_skip_names[fg_skip_count] = {
	"other-layer", "mismatch", "fps>=refresh", "worker-lag", "no-drawable", "error", "unordered",
	"metalfx-warmup", "settling", "fast-motion", "display-dropped", "double-present",
};


// Shared between the game thread and the worker; fg_lock guards everything
// below except the atomics.
static os_unfair_lock fg_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic int fg_mode;
static _Atomic int fg_inflight;
static _Atomic unsigned fg_generation;
static _Atomic int fg_hooks_installed;

static id fg_game_layer; // unretained, identity only
static id<MTLDevice> fg_device;
static id<MTLCommandQueue> fg_queue;
static id<MTLEvent> fg_event;
static uint64_t fg_event_value;
static CAMetalLayer *fg_layer;
static dispatch_queue_t fg_worker;

static NSUInteger fg_width, fg_height, fg_format;
static id<MTLTexture> fg_hist[2];
static int fg_hist_next;
static int fg_hist_valid; // frames in history, caps at 2
static double fg_last_present_time;
static double fg_interval; // EMA of real present spacing, seconds
static double fg_lead; // EMA of generation latency, seconds
static double fg_refresh_interval;
// Engage/disengage runs on a smoothed rate: frames counted over half-second
// windows, and the state held until the condition has lasted a second.
static double fg_rate_start, fg_rate_interval; // window start; mean interval of the last full window
static int fg_rate_frames;
static double fg_slow_since, fg_fast_since; // when the rate crossed the threshold, 0 = not crossed
static double fg_retry_not_before; // after a forced pass-through, no engagement until then
static _Atomic int fg_total_state_changes; // active <-> pass-through transitions
static int fg_hud_suppressed; // the game's layer has its HUD hidden under the covering layer

// Mode changes between active and pass-through are what the user sees as the
// picture jumping between layers; count them for the stats and the tests.
static void fg_mode_store(int mode)
{
	int was = atomic_exchange(&fg_mode, mode);
	if ((was == fg_mode_active) != (mode == fg_mode_active) &&
	    (was == fg_mode_active || was == fg_mode_passthrough) &&
	    (mode == fg_mode_active || mode == fg_mode_passthrough))
		atomic_fetch_add(&fg_total_state_changes, 1);
}

// Stats, once per second when OVERLAY_SHIM_LOG is set
static double fg_stat_start;
static int fg_stat_real, fg_stat_generated, fg_stat_skips[fg_skip_count];
static double fg_stat_gpu_ms, fg_stat_gpu_max_ms;
static int fg_stat_gpu_n;
static _Atomic int fg_total_generated, fg_total_real_copies;

// Display diagnostics: what the compositor did with the overlay layer's drawables
// (presentedTime 0 in the presented handler means dropped), and the mean luma of
// the last real copy and generated frame, measured once a second on the GPU.
static _Atomic int fg_total_presented, fg_total_dropped;
static int fg_stat_presented, fg_stat_dropped;
static double fg_diag_luma[2]; // 0 real copy, 1 generated
static double fg_diag_time; // last luma measurement
static id<MTLTexture> fg_diag_texture; // 1/64 luma of a frame
static id<MTLBuffer> fg_diag_buffer[2];
// Safety net: active with presents issued but none reaching the glass
static double fg_display_check_time;
static int fg_display_check_presented, fg_display_check_issued;
static _Atomic int fg_game_presented; // the game's own presents that reached the display

// Which engine the worker ended up with
static int fg_engine_kind; // 0 none, 1 own, 2 metalfx
static const char *fg_engine_name(int kind)
{
	return kind == 2 ? "metalfx" : kind == 1 ? "own" : "none";
}

// Per command buffer: the drawable it presents or the drawable texture it
// rendered into, until commit.
#define fg_max_pending 8

struct fg_pending {
	id buffer; // unretained key
	id drawable; // retained when present was diverted
	id<MTLTexture> texture; // unretained, identity only
	int divert;
	double min_duration; // presentDrawable:afterMinimumDuration: request, else 0
};

static struct fg_pending fg_pending[fg_max_pending];

// The last blit encoded for a drawable texture that has not been presented yet
static id<MTLTexture> fg_blit_texture; // unretained
static uint64_t fg_blit_value;
static int fg_blit_slot;
static double fg_blit_time;

static id fg_last_vended_texture; // unretained, from nextDrawable
static id fg_passthrough_drawable; // unretained; its buffer-level present went ahead
static int fg_unhide_pending; // the next real copy presented unhides the overlay layer
static __thread int fg_internal; // set while the worker drives Metal itself

static double fg_now(void)
{
	return CACurrentMediaTime();
}

static void fg_stat_skip(enum fg_skip reason)
{
	os_unfair_lock_lock(&fg_lock);
	fg_stat_skips[reason]++;
	os_unfair_lock_unlock(&fg_lock);
}

// ---------------------------------------------------------------------------
// Engines

static const char *const fg_shader_source =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"constant sampler fg_lin(coord::normalized, address::clamp_to_edge, filter::linear);\n"
"constant sampler fg_px(coord::pixel, address::clamp_to_edge, filter::nearest);\n"
"struct fg_const_params { float value; };\n"
"kernel void np_fg_const(texture2d<float, access::write> dst [[texture(0)]],\n"
"                        constant fg_const_params &p [[buffer(0)]],\n"
"                        uint2 gid [[thread_position_in_grid]]) {\n"
"    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
"    dst.write(float4(p.value), gid);\n"
"}\n"
// Luma at 1/scale of the resolution, each output pixel a scale x scale box of the input
"struct fg_luma_params { uint scale; };\n"
"kernel void np_fg_luma(texture2d<float, access::sample> src [[texture(0)]],\n"
"                       texture2d<float, access::write> dst [[texture(1)]],\n"
"                       constant fg_luma_params &p [[buffer(0)]],\n"
"                       uint2 gid [[thread_position_in_grid]]) {\n"
"    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
"    float2 inv = 1.0 / float2(src.get_width(), src.get_height());\n"
"    float2 base = (float2(gid) * float(p.scale) + 1.0) * inv;\n"
"    int n = max(int(p.scale / 2), 1);\n"
"    float l = 0.0;\n"
"    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {\n"
"        float3 c = src.sample(fg_lin, base + float2(x, y) * 2.0 * inv).rgb;\n"
"        l += dot(c, float3(0.299, 0.587, 0.114));\n"
"    }\n"
"    dst.write(float4(l / float(n * n)), gid);\n"
"}\n"
// One pyramid level of block matching: a -> b. Flow is in this level's pixels.
// The radius is a template parameter so the cost window stays in registers. A
// tiny penalty on the displacement breaks ties towards the coarser estimate, so
// flat areas carry their neighbourhood's motion instead of the first candidate.
"template <int R, int HALF>\n"
"static inline float2 fg_flow_search(texture2d<float, access::sample> a,\n"
"                                    texture2d<float, access::sample> b,\n"
"                                    float2 pos, float2 base) {\n"
"    float cost[2 * R + 1][2 * R + 1];\n"
"    float best = 1e30; int bi = R, bj = R;\n"
"    for (int dy = -R; dy <= R; dy++) for (int dx = -R; dx <= R; dx++) {\n"
"        float2 v = base + float2(dx, dy);\n"
"        float s = 1e-4 * float(dx * dx + dy * dy);\n"
"        for (int j = -HALF; j <= HALF; j++) for (int i = -HALF; i <= HALF; i++) {\n"
"            float2 q = pos + float2(i, j);\n"
"            s += abs(a.sample(fg_px, q).r - b.sample(fg_px, q + v).r);\n"
"        }\n"
"        cost[dy + R][dx + R] = s;\n"
"        if (s < best) { best = s; bi = dx + R; bj = dy + R; }\n"
"    }\n"
"    float2 sub = 0.0;\n"
"    if (bi > 0 && bi < 2 * R) {\n"
"        float l = cost[bj][bi - 1], rr = cost[bj][bi + 1];\n"
"        float d = l + rr - 2.0 * best;\n"
"        if (d > 1e-5) sub.x = clamp(0.5 * (l - rr) / d, -0.5, 0.5);\n"
"    }\n"
"    if (bj > 0 && bj < 2 * R) {\n"
"        float u = cost[bj - 1][bi], dn = cost[bj + 1][bi];\n"
"        float d = u + dn - 2.0 * best;\n"
"        if (d > 1e-5) sub.y = clamp(0.5 * (u - dn) / d, -0.5, 0.5);\n"
"    }\n"
"    return base + float2(bi - R, bj - R) + sub;\n"
"}\n"
"kernel void np_fg_flow3(texture2d<float, access::sample> a [[texture(0)]],\n"
"                        texture2d<float, access::sample> b [[texture(1)]],\n"
"                        texture2d<float, access::write> out [[texture(3)]],\n"
"                        uint2 gid [[thread_position_in_grid]]) {\n"
"    uint w = out.get_width(), h = out.get_height();\n"
"    if (gid.x >= w || gid.y >= h) return;\n"
"    float2 pos = float2(gid) + 0.5;\n"
"    out.write(float4(fg_flow_search<3, 2>(a, b, pos, float2(0.0)), 0.0, 0.0), gid);\n"
"}\n"
"kernel void np_fg_flow1(texture2d<float, access::sample> a [[texture(0)]],\n"
"                        texture2d<float, access::sample> b [[texture(1)]],\n"
"                        texture2d<float, access::sample> prev [[texture(2)]],\n"
"                        texture2d<float, access::write> out [[texture(3)]],\n"
"                        uint2 gid [[thread_position_in_grid]]) {\n"
"    uint w = out.get_width(), h = out.get_height();\n"
"    if (gid.x >= w || gid.y >= h) return;\n"
"    float2 pos = float2(gid) + 0.5;\n"
"    float2 base = round(2.0 * prev.sample(fg_lin, pos / float2(w, h)).xy);\n"
"    out.write(float4(fg_flow_search<1, 2>(a, b, pos, base), 0.0, 0.0), gid);\n"
"}\n"
// The finest level with a 3x3 window: it carries most of the cost
"kernel void np_fg_flow1f(texture2d<float, access::sample> a [[texture(0)]],\n"
"                         texture2d<float, access::sample> b [[texture(1)]],\n"
"                         texture2d<float, access::sample> prev [[texture(2)]],\n"
"                         texture2d<float, access::write> out [[texture(3)]],\n"
"                         uint2 gid [[thread_position_in_grid]]) {\n"
"    uint w = out.get_width(), h = out.get_height();\n"
"    if (gid.x >= w || gid.y >= h) return;\n"
"    float2 pos = float2(gid) + 0.5;\n"
"    float2 base = round(2.0 * prev.sample(fg_lin, pos / float2(w, h)).xy);\n"
"    out.write(float4(fg_flow_search<1, 1>(a, b, pos, base), 0.0, 0.0), gid);\n"
"}\n"
// Per pair, over the finest flow level: how much of the textured area has a flow
// that disagrees with its reverse or sits at the edge of the search range, and the
// mean motion. counts[0] textured pixels, [1] bad ones, [2] sum of |flow| in 1/4 px.
"struct fg_stats_params { float range; float grad; };\n"
"kernel void np_fg_stats(texture2d<float, access::sample> la [[texture(0)]],\n"
"                        texture2d<float, access::sample> fab [[texture(1)]],\n"
"                        texture2d<float, access::sample> fba [[texture(2)]],\n"
"                        constant fg_stats_params &p [[buffer(0)]],\n"
"                        device atomic_uint *counts [[buffer(1)]],\n"
"                        uint2 gid [[thread_position_in_grid]],\n"
"                        uint tid [[thread_index_in_threadgroup]],\n"
"                        uint lane [[thread_index_in_simdgroup]]) {\n"
"    threadgroup atomic_uint local[3];\n"
"    if (tid == 0) for (int i = 0; i < 3; i++) atomic_store_explicit(&local[i], 0u, memory_order_relaxed);\n"
"    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"    uint w = fab.get_width(), h = fab.get_height();\n"
"    uint tex = 0, bad = 0, mag = 0;\n"
"    if (gid.x < w && gid.y < h) {\n"
"        float2 pos = float2(gid) + 0.5;\n"
"        float gx = la.sample(fg_px, pos + float2(1.0, 0.0)).r - la.sample(fg_px, pos - float2(1.0, 0.0)).r;\n"
"        float gy = la.sample(fg_px, pos + float2(0.0, 1.0)).r - la.sample(fg_px, pos - float2(0.0, 1.0)).r;\n"
"        if (max(abs(gx), abs(gy)) > p.grad) {\n"
"            tex = 1;\n"
"            float2 f = fab.sample(fg_px, pos).xy;\n"
"            float2 g = fba.sample(fg_lin, (pos + f) / float2(w, h)).xy;\n"
"            if (length(f + g) > 2.0 || max(abs(f.x), abs(f.y)) > p.range) bad = 1;\n"
"            mag = uint(min(length(f), 255.0) * 4.0);\n"
"        }\n"
"    }\n"
"    tex = simd_sum(tex); bad = simd_sum(bad); mag = simd_sum(mag);\n"
"    if (lane == 0) {\n"
"        atomic_fetch_add_explicit(&local[0], tex, memory_order_relaxed);\n"
"        atomic_fetch_add_explicit(&local[1], bad, memory_order_relaxed);\n"
"        atomic_fetch_add_explicit(&local[2], mag, memory_order_relaxed);\n"
"    }\n"
"    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"    if (tid == 0) for (int i = 0; i < 3; i++)\n"
"        atomic_fetch_add_explicit(&counts[i], atomic_load_explicit(&local[i], memory_order_relaxed), memory_order_relaxed);\n"
"}\n"
// The fallback verdict from those counts; fg_verdict on the CPU side must agree.
"static inline bool fg_fallback(device const uint *counts, uint total, float range) {\n"
"    uint tex = counts[0];\n"
"    if (tex * 100u < total) return false;\n"
"    if (counts[1] * 4u > tex) return true;\n"
"    return float(counts[2]) > 0.6 * range * 4.0 * float(tex);\n"
"}\n"
"struct fg_synth_params { float t; float scale; float range; uint ui; uint fallback; uint total; };\n"
// Flow-resolution flow to full-resolution motion vectors in pixels, the layout
// MetalFX wants: each pixel of the new frame points to where it was.
"kernel void np_fg_motion(texture2d<float, access::sample> flow [[texture(0)]],\n"
"                         texture2d<float, access::write> out [[texture(1)]],\n"
"                         constant fg_synth_params &p [[buffer(0)]],\n"
"                         uint2 gid [[thread_position_in_grid]]) {\n"
"    uint w = out.get_width(), h = out.get_height();\n"
"    if (gid.x >= w || gid.y >= h) return;\n"
"    float2 uv = (float2(gid) + 0.5) / float2(w, h);\n"
"    out.write(float4(flow.sample(fg_lin, uv).xy * p.scale, 0.0, 0.0), gid);\n"
"}\n"
// Pixels the two real frames agree on exactly: HUD, menus, text, letterbox
"static inline bool fg_static(float4 a0, float4 b0) {\n"
"    float3 d = abs(a0.rgb - b0.rgb);\n"
"    float peak = max(max(a0.r, a0.g), max(a0.b, 1.0));\n"
"    return max(max(d.r, d.g), d.b) < 0.006 * peak;\n"
"}\n"
// The frame at t between a and b, from the forward and backward flows. Where
// neither flow explains a pixel, or the flows contradict each other, lean on the
// nearer real frame.
"kernel void np_fg_synth(texture2d<float, access::sample> a [[texture(0)]],\n"
"                        texture2d<float, access::sample> b [[texture(1)]],\n"
"                        texture2d<float, access::sample> fab [[texture(2)]],\n"
"                        texture2d<float, access::sample> fba [[texture(3)]],\n"
"                        texture2d<float, access::write> out [[texture(4)]],\n"
"                        constant fg_synth_params &p [[buffer(0)]],\n"
"                        device const uint *counts [[buffer(1)]],\n"
"                        uint2 gid [[thread_position_in_grid]]) {\n"
"    uint w = out.get_width(), h = out.get_height();\n"
"    if (gid.x >= w || gid.y >= h) return;\n"
"    float4 a0 = a.read(gid), b0 = b.read(gid);\n"
"    float t = p.t;\n"
"    if (p.fallback != 0 && fg_fallback(counts, p.total, p.range)) {\n"
"        out.write(t < 0.5 ? a0 : b0, gid);\n"
"        return;\n"
"    }\n"
"    if (p.ui != 0 && fg_static(a0, b0)) {\n"
"        out.write(b0, gid);\n"
"        return;\n"
"    }\n"
"    float2 size = float2(w, h);\n"
"    float2 uv = (float2(gid) + 0.5) / size;\n"
"    float2 fpx = fab.sample(fg_lin, uv).xy * p.scale;\n"
"    float2 gpx = fba.sample(fg_lin, uv).xy * p.scale;\n"
"    float2 f = fpx / size, g = gpx / size;\n"
"    float4 a1 = a.sample(fg_lin, uv - t * f), b1 = b.sample(fg_lin, uv + (1.0 - t) * f);\n"
"    float4 b2 = b.sample(fg_lin, uv - (1.0 - t) * g), a2 = a.sample(fg_lin, uv + t * g);\n"
"    float e1 = dot(abs(a1.rgb - b1.rgb), float3(1.0 / 3.0));\n"
"    float e2 = dot(abs(a2.rgb - b2.rgb), float3(1.0 / 3.0));\n"
"    float4 c, nearer; float e, inconsistent;\n"
"    if (e1 <= e2) {\n"
"        c = mix(a1, b1, t); nearer = t < 0.5 ? a1 : b1; e = e1;\n"
"        inconsistent = length(fpx + fba.sample(fg_lin, uv + f).xy * p.scale);\n"
"    } else {\n"
"        c = mix(a2, b2, t); nearer = t < 0.5 ? a2 : b2; e = e2;\n"
"        inconsistent = length(gpx + fab.sample(fg_lin, uv + g).xy * p.scale);\n"
"    }\n"
"    float k = smoothstep(0.08, 0.25, e);\n"
"    if (p.ui != 0) k = max(k, smoothstep(2.0 * p.scale, 6.0 * p.scale, inconsistent));\n"
"    out.write(mix(c, nearer, k), gid);\n"
"}\n"
// UI protection and the fallback over MetalFX's output
"kernel void np_fg_post(texture2d<float, access::sample> a [[texture(0)]],\n"
"                       texture2d<float, access::sample> b [[texture(1)]],\n"
"                       texture2d<float, access::sample> fx [[texture(2)]],\n"
"                       texture2d<float, access::write> out [[texture(3)]],\n"
"                       constant fg_synth_params &p [[buffer(0)]],\n"
"                       device const uint *counts [[buffer(1)]],\n"
"                       uint2 gid [[thread_position_in_grid]]) {\n"
"    uint w = out.get_width(), h = out.get_height();\n"
"    if (gid.x >= w || gid.y >= h) return;\n"
"    float4 a0 = a.read(gid), b0 = b.read(gid);\n"
"    if (p.fallback != 0 && fg_fallback(counts, p.total, p.range)) out.write(p.t < 0.5 ? a0 : b0, gid);\n"
"    else if (p.ui != 0 && fg_static(a0, b0)) out.write(b0, gid);\n"
"    else out.write(fx.read(gid), gid);\n"
"}\n";

#define fg_levels_max 6
#define fg_stats_ring 4

struct fg_synth_params {
	float t, scale, range;
	unsigned ui, fallback, total;
};

struct fg_engine {
	id<MTLDevice> device;
	NSUInteger width, height, format;
	int kind;
	int quality, ui, fallback;
	// own
	unsigned scale; // luma at 1/scale
	int levels; // pyramid levels
	int fine_half2; // 5x5 window at the finest level instead of 3x3
	float range; // reach of the search at the finest level, flow pixels
	id<MTLComputePipelineState> ps_const, ps_luma, ps_flow1, ps_flow1f, ps_flow3, ps_stats, ps_motion,
	        ps_synth, ps_post;
	id<MTLTexture> luma[2];
	id<MTLTexture> luma_view[2][fg_levels_max];
	id<MTLTexture> flow_ab[fg_levels_max], flow_ba[fg_levels_max];
	id<MTLBuffer> stats[fg_stats_ring];
	int stats_next;
	id<MTLBuffer> stats_cur; // unretained; the pair's counts, from fg_engine_prepare on
	id<MTLTexture> out;
	// metalfx
	id interpolator;
	id<MTLTexture> depth, motion, fx_out;
	int reset_pending;
	int warm; // MetalFX encodes since the last reset; the first two echo the new frame
	int luma_valid[2];
};

// MetalFX output is a real interpolation only from this many encodes after a reset
#define fg_metalfx_warmup 2

@protocol np_fx_descriptor <NSObject>
- (void)setColorTextureFormat:(NSUInteger)format;
- (void)setOutputTextureFormat:(NSUInteger)format;
- (void)setDepthTextureFormat:(NSUInteger)format;
- (void)setMotionTextureFormat:(NSUInteger)format;
- (void)setUITextureFormat:(NSUInteger)format;
- (void)setInputWidth:(NSUInteger)value;
- (void)setInputHeight:(NSUInteger)value;
- (void)setOutputWidth:(NSUInteger)value;
- (void)setOutputHeight:(NSUInteger)value;
- (id)newFrameInterpolatorWithDevice:(id)device;
@end

@protocol np_fx_interpolator <NSObject>
- (NSUInteger)colorTextureUsage;
- (NSUInteger)depthTextureUsage;
- (NSUInteger)motionTextureUsage;
- (NSUInteger)outputTextureUsage;
- (void)setColorTexture:(id)texture;
- (void)setPrevColorTexture:(id)texture;
- (void)setDepthTexture:(id)texture;
- (void)setMotionTexture:(id)texture;
- (void)setOutputTexture:(id)texture;
- (void)setMotionVectorScaleX:(float)value;
- (void)setMotionVectorScaleY:(float)value;
- (void)setDeltaTime:(float)value;
- (void)setNearPlane:(float)value;
- (void)setFarPlane:(float)value;
- (void)setFieldOfView:(float)value;
- (void)setAspectRatio:(float)value;
- (void)setJitterOffsetX:(float)value;
- (void)setJitterOffsetY:(float)value;
- (void)setShouldResetHistory:(BOOL)value;
- (void)setDepthReversed:(BOOL)value;
- (void)encodeToCommandBuffer:(id)buffer;
@end

// Foundation is not linked; NSString comes through the runtime
static id fg_nsstring(const char *text)
{
	typedef id (*from_utf8_fn)(id, SEL, const char *);

	return ((from_utf8_fn)objc_msgSend)((id)objc_getClass("NSString"),
	                                     sel_registerName("stringWithUTF8String:"), text);
}

static id<MTLTexture> fg_make_texture(id<MTLDevice> device, NSUInteger format, NSUInteger width,
                                      NSUInteger height, MTLTextureUsage usage, int mipmapped)
{
	MTLTextureDescriptor *descriptor =
	        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)format
	                                                           width:width
	                                                          height:height
	                                                       mipmapped:mipmapped ? YES : NO];
	descriptor.usage = usage;
	descriptor.storageMode = MTLStorageModePrivate;
	return [device newTextureWithDescriptor:descriptor];
}

static void fg_release(id *slot)
{
	if (*slot != nil) {
		[*slot release];
		*slot = nil;
	}
}

static void fg_engine_destroy(struct fg_engine *engine)
{
	fg_release((id *)&engine->ps_const);
	fg_release((id *)&engine->ps_luma);
	fg_release((id *)&engine->ps_flow1);
	fg_release((id *)&engine->ps_flow1f);
	fg_release((id *)&engine->ps_flow3);
	fg_release((id *)&engine->ps_stats);
	fg_release((id *)&engine->ps_motion);
	fg_release((id *)&engine->ps_synth);
	fg_release((id *)&engine->ps_post);
	for (int i = 0; i < 2; i++) {
		fg_release((id *)&engine->luma[i]);
		for (int l = 0; l < fg_levels_max; l++)
			fg_release((id *)&engine->luma_view[i][l]);
	}
	for (int l = 0; l < fg_levels_max; l++) {
		fg_release((id *)&engine->flow_ab[l]);
		fg_release((id *)&engine->flow_ba[l]);
	}
	for (int i = 0; i < fg_stats_ring; i++)
		fg_release((id *)&engine->stats[i]);
	fg_release((id *)&engine->out);
	fg_release(&engine->interpolator);
	fg_release((id *)&engine->depth);
	fg_release((id *)&engine->motion);
	fg_release((id *)&engine->fx_out);
	fg_release((id *)&engine->device);
	memset(engine, 0, sizeof(*engine));
}

static id<MTLComputePipelineState> fg_pipeline(id<MTLDevice> device, id<MTLLibrary> library,
                                               const char *name)
{
	id<MTLFunction> function = [library newFunctionWithName:fg_nsstring(name)];
	if (function == nil)
		return nil;

	NSError *error = nil;
	id<MTLComputePipelineState> state = [device newComputePipelineStateWithFunction:function
	                                                                          error:&error];
	[function release];
	if (state == nil)
		shim_log("overlay_shim framegen: pipeline %s failed: %s\n", name,
		        error != nil ? [[error localizedDescription] UTF8String] : "no reason given");
	return state;
}

// Quality presets: where motion is estimated and how hard the finest level looks
static void fg_engine_apply_quality(struct fg_engine *engine)
{
	switch (engine->quality) {
	case fg_quality_performance:
		engine->scale = 8;
		engine->levels = 5;
		engine->fine_half2 = 0;
		break;
	case fg_quality_quality:
		engine->scale = 2;
		engine->levels = 6;
		engine->fine_half2 = 0; // 5x5 here doubles the cost again (measured 4 ms vs 2 ms)
		break;
	default:
		engine->scale = 4;
		engine->levels = 5;
		engine->fine_half2 = 0;
		break;
	}
	// Coarsest level searches +-3, each finer one +-1 around the doubled estimate
	engine->range = (float)(4 * (1 << (engine->levels - 1)) - 1);
}

static int fg_engine_build_own(struct fg_engine *engine)
{
	id<MTLDevice> device = engine->device;
	NSError *error = nil;
	MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
	id<MTLLibrary> library =
	        [device newLibraryWithSource:fg_nsstring(fg_shader_source)
	                             options:options
	                               error:&error];
	[options release];
	if (library == nil) {
		shim_log("overlay_shim framegen: shader compile failed: %s\n",
		        error != nil ? [[error localizedDescription] UTF8String] : "no reason given");
		return 0;
	}

	engine->ps_const = fg_pipeline(device, library, "np_fg_const");
	engine->ps_luma = fg_pipeline(device, library, "np_fg_luma");
	engine->ps_flow1 = fg_pipeline(device, library, "np_fg_flow1");
	engine->ps_flow1f = fg_pipeline(device, library, "np_fg_flow1f");
	engine->ps_flow3 = fg_pipeline(device, library, "np_fg_flow3");
	engine->ps_stats = fg_pipeline(device, library, "np_fg_stats");
	engine->ps_motion = fg_pipeline(device, library, "np_fg_motion");
	engine->ps_synth = fg_pipeline(device, library, "np_fg_synth");
	engine->ps_post = fg_pipeline(device, library, "np_fg_post");
	[library release];
	if (engine->ps_const == nil || engine->ps_luma == nil || engine->ps_flow1 == nil ||
	    engine->ps_flow1f == nil || engine->ps_flow3 == nil || engine->ps_stats == nil ||
	    engine->ps_motion == nil || engine->ps_synth == nil || engine->ps_post == nil)
		return 0;

	fg_engine_apply_quality(engine);
	NSUInteger s = engine->scale;
	NSUInteger lw = (engine->width + s - 1) / s, lh = (engine->height + s - 1) / s;
	int levels = engine->levels;
	while (levels > 1 && ((lw >> (levels - 1)) < 4 || (lh >> (levels - 1)) < 4))
		levels--; // tiny frames: keep the coarsest level at least 4x4
	engine->levels = levels;
	engine->range = (float)(4 * (1 << (levels - 1)) - 1);
	for (int i = 0; i < 2; i++) {
		MTLTextureDescriptor *descriptor =
		        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float
		                                                           width:lw
		                                                          height:lh
		                                                       mipmapped:YES];
		descriptor.mipmapLevelCount = levels;
		descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
		descriptor.storageMode = MTLStorageModePrivate;
		engine->luma[i] = [device newTextureWithDescriptor:descriptor];
		if (engine->luma[i] == nil)
			return 0;
		for (int l = 0; l < levels; l++) {
			engine->luma_view[i][l] =
			        [engine->luma[i] newTextureViewWithPixelFormat:MTLPixelFormatR16Float
			                                           textureType:MTLTextureType2D
			                                                levels:NSMakeRange(l, 1)
			                                                slices:NSMakeRange(0, 1)];
			if (engine->luma_view[i][l] == nil)
				return 0;
		}
	}
	for (int l = 0; l < levels; l++) {
		NSUInteger w = lw >> l, h = lh >> l;
		if (w == 0)
			w = 1;
		if (h == 0)
			h = 1;
		engine->flow_ab[l] = fg_make_texture(device, MTLPixelFormatRG16Float, w, h,
		                                     MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, 0);
		engine->flow_ba[l] = fg_make_texture(device, MTLPixelFormatRG16Float, w, h,
		                                     MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, 0);
		if (engine->flow_ab[l] == nil || engine->flow_ba[l] == nil)
			return 0;
	}
	for (int i = 0; i < fg_stats_ring; i++) {
		engine->stats[i] = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
		if (engine->stats[i] == nil)
			return 0;
		memset(engine->stats[i].contents, 0, 16);
	}
	engine->out = fg_make_texture(device, engine->format, engine->width, engine->height,
	                              MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, 0);
	return engine->out != nil;
}

static void fg_dispatch(id<MTLComputeCommandEncoder> encoder, id<MTLComputePipelineState> state,
                        NSUInteger width, NSUInteger height)
{
	NSUInteger tw = state.threadExecutionWidth;
	NSUInteger th = state.maxTotalThreadsPerThreadgroup / tw;
	if (th > 16)
		th = 16;
	[encoder setComputePipelineState:state];
	[encoder dispatchThreads:MTLSizeMake(width, height, 1)
	        threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
}

static void fg_fill_constant(struct fg_engine *engine, id<MTLCommandBuffer> buffer,
                             id<MTLTexture> texture, float value)
{
	id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
	struct { float value; } params = { value };
	[encoder setTexture:texture atIndex:0];
	[encoder setBytes:&params length:sizeof(params) atIndex:0];
	fg_dispatch(encoder, engine->ps_const, texture.width, texture.height);
	[encoder endEncoding];
}

static Class fg_metalfx_descriptor_class(void)
{
	static Class descriptor_class;
	static int looked;

	if (!looked) {
		looked = 1;
		dlopen("/System/Library/Frameworks/MetalFX.framework/MetalFX", RTLD_NOW | RTLD_GLOBAL);
		descriptor_class = objc_getClass("MTLFXFrameInterpolatorDescriptor");
	}
	return descriptor_class;
}

static int fg_metalfx_supported(id<MTLDevice> device)
{
	Class descriptor_class = fg_metalfx_descriptor_class();
	SEL supports = sel_registerName("supportsDevice:");

	if (descriptor_class == Nil || !class_respondsToSelector(object_getClass(descriptor_class), supports))
		return 0;
	return ((BOOL (*)(Class, SEL, id))objc_msgSend)(descriptor_class, supports, device) ? 1 : 0;
}

static int fg_engine_build_metalfx(struct fg_engine *engine)
{
	Class descriptor_class = fg_metalfx_descriptor_class();
	if (descriptor_class == Nil || !fg_metalfx_supported(engine->device))
		return 0;

	id<np_fx_descriptor> descriptor = [[descriptor_class alloc] init];
	if (descriptor == nil)
		return 0;
	[descriptor setColorTextureFormat:engine->format];
	[descriptor setOutputTextureFormat:engine->format];
	[descriptor setDepthTextureFormat:MTLPixelFormatR32Float];
	[descriptor setMotionTextureFormat:MTLPixelFormatRG16Float];
	[descriptor setUITextureFormat:MTLPixelFormatInvalid];
	[descriptor setInputWidth:engine->width];
	[descriptor setInputHeight:engine->height];
	[descriptor setOutputWidth:engine->width];
	[descriptor setOutputHeight:engine->height];
	// macOS 27 defaults to managing the previous colour itself, which would
	// pair the new frame with a stale copy; we hand it the real previous frame
	SEL requires_prev = sel_registerName("setRequiresPrevColorTexture:");
	if ([descriptor respondsToSelector:requires_prev])
		((void (*)(id, SEL, BOOL))objc_msgSend)(descriptor, requires_prev, YES);
	id<np_fx_interpolator> interpolator = [descriptor newFrameInterpolatorWithDevice:engine->device];
	[descriptor release];
	if (interpolator == nil) {
		shim_log("overlay_shim framegen: MetalFX interpolator refused %lux%lu %s\n",
		        (unsigned long)engine->width, (unsigned long)engine->height,
		        format_name(engine->format));
		return 0;
	}
	engine->interpolator = interpolator;

	engine->depth = fg_make_texture(engine->device, MTLPixelFormatR32Float, engine->width,
	                                engine->height,
	                                [interpolator depthTextureUsage] | MTLTextureUsageShaderWrite, 0);
	engine->motion = fg_make_texture(engine->device, MTLPixelFormatRG16Float, engine->width,
	                                 engine->height,
	                                 [interpolator motionTextureUsage] | MTLTextureUsageShaderWrite, 0);
	engine->fx_out = fg_make_texture(engine->device, engine->format, engine->width, engine->height,
	                                 [interpolator outputTextureUsage] | MTLTextureUsageShaderRead, 0);
	if (engine->depth == nil || engine->motion == nil || engine->fx_out == nil)
		return 0;

	id<MTLCommandQueue> queue = [engine->device newCommandQueue];
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	fg_fill_constant(engine, buffer, engine->depth, 0.5f);
	fg_fill_constant(engine, buffer, engine->motion, 0.0f);
	[buffer commit];
	[buffer waitUntilCompleted];
	int ok = buffer.error == nil;
	[queue release];
	engine->reset_pending = 1;
	return ok;
}

// History textures need the usage both engines ask for
static MTLTextureUsage fg_history_usage(void)
{
	return MTLTextureUsageShaderRead;
}

static int fg_engine_create(struct fg_engine *engine, id<MTLDevice> device, NSUInteger width,
                            NSUInteger height, NSUInteger format, int pref, int quality, int ui,
                            int fallback)
{
	memset(engine, 0, sizeof(*engine));
	engine->device = [device retain];
	engine->width = width;
	engine->height = height;
	engine->format = format;
	engine->quality = quality;
	engine->ui = ui ? 1 : 0;
	engine->fallback = fallback ? 1 : 0;

	// The own path's kernels are needed for MetalFX's motion vectors and post pass too
	if (!fg_engine_build_own(engine)) {
		fg_engine_destroy(engine);
		return 0;
	}
	engine->kind = 1;

	// MetalFX only on request: it needs our motion vectors anyway and costs
	// 2-3x the in-house path (measured 2.6-4.5 ms against 1.4 ms at 3024x1964)
	if (pref == 2 && fg_engine_build_metalfx(engine)) {
		engine->kind = 2;
	} else {
		fg_release(&engine->interpolator);
		fg_release((id *)&engine->depth);
		fg_release((id *)&engine->motion);
		fg_release((id *)&engine->fx_out);
		if (pref == 2)
			shim_log("overlay_shim framegen: metalfx requested but unavailable, using own\n");
	}
	return 1;
}

// Call once per real frame before interpolating against it (own engine)
static void fg_engine_ingest(struct fg_engine *engine, id<MTLCommandBuffer> buffer,
                             id<MTLTexture> frame, int slot)
{
	id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
	struct { unsigned scale; } params = { engine->scale };
	[encoder setTexture:frame atIndex:0];
	[encoder setTexture:engine->luma_view[slot][0] atIndex:1];
	[encoder setBytes:&params length:sizeof(params) atIndex:0];
	fg_dispatch(encoder, engine->ps_luma, engine->luma[slot].width, engine->luma[slot].height);
	[encoder endEncoding];

	if (engine->levels > 1) {
		id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
		[blit generateMipmapsForTexture:engine->luma[slot]];
		[blit endEncoding];
	}
	engine->luma_valid[slot] = 1;
}

static void fg_flow_pass(struct fg_engine *engine, id<MTLComputeCommandEncoder> encoder,
                         int from, int to, id<MTLTexture> *flows)
{
	int top = engine->levels - 1;
	for (int l = top; l >= 0; l--) {
		id<MTLComputePipelineState> state;
		if (l == top)
			state = engine->ps_flow3;
		else if (l == 0 && !engine->fine_half2)
			state = engine->ps_flow1f;
		else
			state = engine->ps_flow1;
		[encoder setTexture:engine->luma_view[from][l] atIndex:0];
		[encoder setTexture:engine->luma_view[to][l] atIndex:1];
		[encoder setTexture:l == top ? nil : flows[l + 1] atIndex:2];
		[encoder setTexture:flows[l] atIndex:3];
		fg_dispatch(encoder, state, flows[l].width, flows[l].height);
	}
}

static struct fg_synth_params fg_engine_params(struct fg_engine *engine, float t)
{
	struct fg_synth_params params;
	params.t = t;
	params.scale = (float)engine->scale;
	params.range = engine->range;
	params.ui = (unsigned)engine->ui;
	params.fallback = (unsigned)engine->fallback;
	params.total = (unsigned)(engine->flow_ab[0].width * engine->flow_ab[0].height);
	return params;
}

// CPU twin of the shader's fg_fallback, over a stats buffer the GPU has finished with
// What the verdict needs from the engine, taken when the work is encoded: the completed
// handler runs on Metal's thread and must not read engine objects a reconfigure may free.
struct fg_verdict_args {
	int fallback;
	unsigned total;
	float range;
};

static struct fg_verdict_args fg_verdict_args(struct fg_engine *engine)
{
	struct fg_verdict_args args = { engine->fallback, 0, engine->range };
	if (engine->flow_ab[0] != nil)
		args.total = (unsigned)(engine->flow_ab[0].width * engine->flow_ab[0].height);
	return args;
}

static int fg_verdict(struct fg_verdict_args args, id<MTLBuffer> stats)
{
	if (!args.fallback || stats == nil || args.total == 0)
		return 0;
	const unsigned *counts = stats.contents;
	unsigned tex = counts[0];
	if (tex * 100u < args.total)
		return 0;
	if (counts[1] * 4u > tex)
		return 1;
	return (float)counts[2] > 0.6f * args.range * 4.0f * (float)tex;
}

// Once per pair: luma for new frames, the flows, their statistics and, for
// MetalFX, the motion vectors. Returns the stats buffer the pair uses.
static id<MTLBuffer> fg_engine_prepare(struct fg_engine *engine, id<MTLCommandBuffer> buffer,
                                       id<MTLTexture> prev, int prev_slot, id<MTLTexture> cur,
                                       int cur_slot)
{
	if (!engine->luma_valid[prev_slot])
		fg_engine_ingest(engine, buffer, prev, prev_slot);
	if (!engine->luma_valid[cur_slot])
		fg_engine_ingest(engine, buffer, cur, cur_slot);

	id<MTLBuffer> stats = engine->stats[engine->stats_next];
	engine->stats_next = (engine->stats_next + 1) % fg_stats_ring;
	engine->stats_cur = stats;
	id<MTLBlitCommandEncoder> clear = [buffer blitCommandEncoder];
	[clear fillBuffer:stats range:NSMakeRange(0, 16) value:0];
	[clear endEncoding];

	id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
	fg_flow_pass(engine, encoder, prev_slot, cur_slot, engine->flow_ab);
	fg_flow_pass(engine, encoder, cur_slot, prev_slot, engine->flow_ba);

	struct { float range, grad; } stats_params = { engine->range * 0.9f, 0.03f };
	[encoder setTexture:engine->luma_view[prev_slot][0] atIndex:0];
	[encoder setTexture:engine->flow_ab[0] atIndex:1];
	[encoder setTexture:engine->flow_ba[0] atIndex:2];
	[encoder setBytes:&stats_params length:sizeof(stats_params) atIndex:0];
	[encoder setBuffer:stats offset:0 atIndex:1];
	fg_dispatch(encoder, engine->ps_stats, engine->flow_ab[0].width, engine->flow_ab[0].height);

	if (engine->kind == 2) {
		// MetalFX does not estimate motion; it gets ours, new frame to previous
		struct fg_synth_params params = fg_engine_params(engine, 0.5f);
		[encoder setTexture:engine->flow_ba[0] atIndex:0];
		[encoder setTexture:engine->motion atIndex:1];
		[encoder setBytes:&params length:sizeof(params) atIndex:0];
		fg_dispatch(encoder, engine->ps_motion, engine->width, engine->height);
	}
	[encoder endEncoding];
	return stats;
}

// After fg_engine_prepare: the frame at t between prev and cur into engine->out
static void fg_engine_synth(struct fg_engine *engine, id<MTLCommandBuffer> buffer,
                            id<MTLTexture> prev, id<MTLTexture> cur, float t, float delta)
{
	struct fg_synth_params params = fg_engine_params(engine, t);

	if (engine->kind == 2) {
		id<np_fx_interpolator> interpolator = engine->interpolator;
		[interpolator setColorTexture:cur];
		[interpolator setPrevColorTexture:prev];
		[interpolator setDepthTexture:engine->depth];
		[interpolator setMotionTexture:engine->motion];
		[interpolator setOutputTexture:engine->fx_out];
		[interpolator setMotionVectorScaleX:1.0f];
		[interpolator setMotionVectorScaleY:1.0f];
		[interpolator setJitterOffsetX:0.0f];
		[interpolator setJitterOffsetY:0.0f];
		[interpolator setDeltaTime:delta > 0 ? delta : 1.0f / 60.0f];
		[interpolator setNearPlane:0.1f];
		[interpolator setFarPlane:1000.0f];
		[interpolator setFieldOfView:60.0f];
		[interpolator setAspectRatio:(float)engine->width / (float)engine->height];
		[interpolator setDepthReversed:YES];
		[interpolator setShouldResetHistory:engine->reset_pending ? YES : NO];
		if (engine->reset_pending)
			engine->warm = 0;
		engine->reset_pending = 0;
		engine->warm++;
		[interpolator encodeToCommandBuffer:buffer];

		id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
		[encoder setTexture:prev atIndex:0];
		[encoder setTexture:cur atIndex:1];
		[encoder setTexture:engine->fx_out atIndex:2];
		[encoder setTexture:engine->out atIndex:3];
		[encoder setBytes:&params length:sizeof(params) atIndex:0];
		[encoder setBuffer:engine->stats_cur offset:0 atIndex:1];
		fg_dispatch(encoder, engine->ps_post, engine->width, engine->height);
		[encoder endEncoding];
		return;
	}

	id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
	[encoder setTexture:prev atIndex:0];
	[encoder setTexture:cur atIndex:1];
	[encoder setTexture:engine->flow_ab[0] atIndex:2];
	[encoder setTexture:engine->flow_ba[0] atIndex:3];
	[encoder setTexture:engine->out atIndex:4];
	[encoder setBytes:&params length:sizeof(params) atIndex:0];
	[encoder setBuffer:engine->stats_cur offset:0 atIndex:1];
	fg_dispatch(encoder, engine->ps_synth, engine->width, engine->height);
	[encoder endEncoding];
}

// Encodes the frame halfway between prev (slot prev_slot) and cur (slot cur_slot) into engine->out
static void fg_engine_interpolate(struct fg_engine *engine, id<MTLCommandBuffer> buffer,
                                  id<MTLTexture> prev, int prev_slot, id<MTLTexture> cur,
                                  int cur_slot, float delta)
{
	fg_engine_prepare(engine, buffer, prev, prev_slot, cur, cur_slot);
	fg_engine_synth(engine, buffer, prev, cur, 0.5f, delta);
}

static struct fg_engine fg_engine;

// Test entry: interpolate a and b at t into out synchronously. engine 1 own,
// 2 metalfx, 0 auto; quality 0 performance, 1 balanced, 2 quality; ui and
// fallback as the environment switches. Returns the engine used, or 0 on
// failure. *fell_back reports whether the fast-motion fallback replaced the
// result with the nearer real frame.
__attribute__((visibility("default"))) int np_framegen_interpolate_opts(id device, id a, id b,
                                                                       id out, int engine_pref,
                                                                       int quality, int ui,
                                                                       int fallback, double t,
                                                                       double *gpu_ms,
                                                                       int *fell_back)
{
	struct fg_engine engine;
	id<MTLTexture> ta = a, tb = b, tout = out;

	if (fell_back != NULL)
		*fell_back = 0;
	if (!fg_engine_create(&engine, device, ta.width, ta.height, ta.pixelFormat, engine_pref, quality,
	                      ui, fallback))
		return 0;
	if (engine_pref == 2 && engine.kind != 2) {
		fg_engine_destroy(&engine);
		return 0;
	}

	id<MTLCommandQueue> queue = [(id<MTLDevice>)device newCommandQueue];
	int kind = engine.kind;
	double total = 0;
	int runs = gpu_ms != NULL ? 16 : kind == 2 ? 6 : 1;
	id<MTLBuffer> stats = nil;
	for (int i = 0; i < runs; i++) {
		id<MTLCommandBuffer> buffer = [queue commandBuffer];
		engine.luma_valid[0] = engine.luma_valid[1] = 0;
		stats = fg_engine_prepare(&engine, buffer, ta, 0, tb, 1);
		fg_engine_synth(&engine, buffer, ta, tb, (float)t, 1.0f / 60.0f);
		id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
		[blit copyFromTexture:engine.out toTexture:tout];
		[blit endEncoding];
		[buffer commit];
		[buffer waitUntilCompleted];
		if (buffer.error != nil)
			kind = 0;
		if (i >= runs / 2)
			total += buffer.GPUEndTime - buffer.GPUStartTime;
	}
	if (gpu_ms != NULL)
		*gpu_ms = total / (double)(runs - runs / 2) * 1000.0;
	if (fell_back != NULL)
		*fell_back = fg_verdict(fg_verdict_args(&engine), stats);
	[queue release];
	fg_engine_destroy(&engine);
	return kind;
}

// The original test entry: balanced quality, UI protection and the fallback on, t=1/2
__attribute__((visibility("default"))) int np_framegen_interpolate_sync(id device, id a, id b,
                                                                       id out, int engine_pref,
                                                                       double *gpu_ms)
{
	return np_framegen_interpolate_opts(device, a, b, out, engine_pref, fg_quality_balanced, 1, 1, 0.5,
	                                    gpu_ms, NULL);
}

// ---------------------------------------------------------------------------
// Overlay layer and worker

// The screen the game is on, not the main screen: with an external display attached
// mainScreen can be a 60 Hz monitor while the game runs on a 120 Hz ProMotion panel. The
// screen whose backing size matches the drawable wins; else the fastest screen.
static double fg_display_interval(NSUInteger width, NSUInteger height)
{
	// Only object and integer returns go through objc_msgSend here: a struct return such
	// as -[NSScreen frame] needs objc_msgSend_stret on x86_64, and getting that wrong
	// crashed the worker under Rosetta.
	typedef id (*obj_fn)(id, SEL);
	typedef id (*obj_arg_fn)(id, SEL, id);
	typedef NSInteger (*fps_fn)(id, SEL);
	typedef unsigned int (*uint_fn)(id, SEL);

	NSInteger matched = 0, fastest = 0;
	Class screen_class = objc_getClass("NSScreen");
	if (screen_class != Nil) {
		id screens = ((obj_fn)objc_msgSend)((id)screen_class, sel_registerName("screens"));
		SEL fps_sel = sel_registerName("maximumFramesPerSecond");
		for (id screen in (NSArray *)screens) {
			if (![screen respondsToSelector:fps_sel])
				continue;
			NSInteger fps = ((fps_fn)objc_msgSend)(screen, fps_sel);
			if (fps > fastest)
				fastest = fps;
			id info = ((obj_fn)objc_msgSend)(screen, sel_registerName("deviceDescription"));
			id number = info ? ((obj_arg_fn)objc_msgSend)(info, sel_registerName("objectForKey:"),
			                                             @"NSScreenNumber") : nil;
			if (fps <= 0 || number == nil)
				continue;
			CGDirectDisplayID display = ((uint_fn)objc_msgSend)(number, sel_registerName("unsignedIntValue"));
			CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
			if (mode == NULL)
				continue;
			if (CGDisplayModeGetPixelWidth(mode) == width && CGDisplayModeGetPixelHeight(mode) == height)
				matched = fps;
			CGDisplayModeRelease(mode);
		}
	}
	if (matched > 0)
		return 1.0 / (double)matched;
	if (fastest > 0)
		return 1.0 / (double)fastest;

	CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
	double rate = mode != NULL ? CGDisplayModeGetRefreshRate(mode) : 0;
	if (mode != NULL)
		CGDisplayModeRelease(mode);
	return rate > 0 ? 1.0 / rate : 1.0 / 60.0;
}

// Layer-tree changes belong to the main thread, which owns the window's layer
// tree and commits it; a change committed from the worker races with it. The
// block runs on the main queue when that is being drained (Wine's main thread
// runs the Cocoa run loop), inline when we are the main thread, and inline as
// the fallback when the main queue has not picked it up within 50 ms.
static void fg_on_main(void (^block)(void))
{
	if (pthread_main_np())
		return block();

	struct task {
		_Atomic int claimed; // whoever flips 0 -> 1 runs the block
		_Atomic int finished; // the second party to finish frees the task
		dispatch_semaphore_t done;
	} *task = calloc(1, sizeof(*task));
	task->done = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_main_queue(), ^{
		int expected = 0;
		if (atomic_compare_exchange_strong(&task->claimed, &expected, 1))
			block();
		dispatch_semaphore_signal(task->done);
		if (atomic_fetch_add(&task->finished, 1) == 1) {
			dispatch_release(task->done);
			free(task);
		}
	});
	if (dispatch_semaphore_wait(task->done, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0) {
		int expected = 0;
		if (atomic_compare_exchange_strong(&task->claimed, &expected, 1))
			block(); // main thread not draining its queue; the block above then only signals
	}
	if (atomic_fetch_add(&task->finished, 1) == 1) {
		dispatch_release(task->done);
		free(task);
	}
}

static void fg_ca_begin(void)
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
}

static void fg_ca_end(void)
{
	[CATransaction commit];
	[CATransaction flush];
}

// With MTL_HUD_ENABLED every CAMetalLayer gets its own HUD, so the game's layer
// (frozen at its own present rate) shows a second one under ours. libMTLHud
// (HUDMTLLayerTracking -observeValueForKeyPath:, macOS 27) reads only the "mode"
// key of a layer's developerHUDProperties: "default" shows that layer's HUD,
// "main" shows it and makes the layer the main one (full layout), any other
// string hides it. A dictionary without "mode" hands the layer back to MTL_HUD_*
// (so it does not hide anything), and nil is ignored. Caller is on the main thread.
static void fg_hud_set_mode(CAMetalLayer *layer, CFStringRef mode)
{
	SEL set = sel_registerName("setDeveloperHUDProperties:");
	if (layer == nil || ![layer respondsToSelector:set])
		return;
	const void *key = CFSTR("mode"), *value = mode;
	CFDictionaryRef props = CFDictionaryCreate(NULL, &key, &value, 1, &kCFTypeDictionaryKeyCallBacks,
	                                           &kCFTypeDictionaryValueCallBacks);
	((void (*)(id, SEL, id))objc_msgSend)(layer, set, (id)props);
	CFRelease(props);
}

// Whether the HUD is on for the game: from the environment, or a mode the game's
// layer already carries (set by the HUD itself or the app)
static int fg_hud_wanted(CAMetalLayer *game)
{
	const char *env = getenv("MTL_HUD_ENABLED");
	if (env != NULL && *env != '\0' && strcmp(env, "0") != 0)
		return 1;
	SEL get = sel_registerName("developerHUDProperties");
	if (game == nil || ![game respondsToSelector:get])
		return 0;
	CFTypeRef props = (CFTypeRef)((id (*)(id, SEL))objc_msgSend)(game, get);
	if (props == NULL || CFGetTypeID(props) != CFDictionaryGetTypeID())
		return 0;
	CFTypeRef mode = CFDictionaryGetValue((CFDictionaryRef)props, CFSTR("mode"));
	return mode != NULL && CFGetTypeID(mode) == CFStringGetTypeID() &&
	       (CFEqual(mode, CFSTR("default")) || CFEqual(mode, CFSTR("main")));
}

// covering = 1: hide the game layer's HUD so only the covering layer's (real +
// generated frames) shows; 0: show it again. The covering layer's own properties
// stay untouched: marking it "main" left its drawables never presented (black
// screen, HUD FPS inf, no presented handler ever ran). "default", not "main",
// on restore for the same reason.
static void fg_hud_suppress(CAMetalLayer *game, int covering)
{
	if (covering && !fg_hud_suppressed) {
		if (!fg_hud_wanted(game))
			return;
		fg_hud_set_mode(game, CFSTR("off"));
		fg_hud_suppressed = 1;
	} else if (!covering && fg_hud_suppressed) {
		fg_hud_set_mode(game, CFSTR("default"));
		fg_hud_suppressed = 0;
	}
}

// Shows or hides the covering layer, and with it swaps which layer carries the HUD
static void fg_layer_set_hidden(int hidden)
{
	CAMetalLayer *layer = fg_layer, *game = (CAMetalLayer *)fg_game_layer;
	if (layer == nil)
		return;
	fg_on_main(^{
		fg_ca_begin();
		layer.hidden = hidden ? YES : NO;
		fg_hud_suppress(game, !hidden);
		fg_ca_end();
	});
}

// Colour state last handed to the covering layer (fg_layer_create, fg_layer_sync_geometry).
static CGColorSpaceRef fg_synced_space;
static int fg_synced_edr = -1;

static void fg_layer_sync_geometry(CAMetalLayer *game)
{
	CGRect bounds = game.bounds;
	CGFloat scale = game.contentsScale;
	CAMetalLayer *layer = fg_layer;
	if (!CGRectEqualToRect(layer.frame, bounds) || layer.contentsScale != scale) {
		fg_on_main(^{
			fg_ca_begin();
			layer.frame = bounds;
			layer.contentsScale = scale;
			fg_ca_end();
		});
	}
	// Games switch to HDR (PQ, EDR) after the layer exists; copied PQ pixels shown through
	// an sRGB, non-EDR layer look washed out, so the colour state follows the game's.
	// Compared against what was last requested: the layer's own properties are set on the
	// main thread and may not read back yet.
	CGColorSpaceRef space = game.colorspace;
	int edr = [game respondsToSelector:@selector(wantsExtendedDynamicRangeContent)] ?
	                  (int)game.wantsExtendedDynamicRangeContent : -1;
	int space_same = (space == NULL && fg_synced_space == NULL) ||
	                 (space != NULL && fg_synced_space != NULL && CFEqual(space, fg_synced_space));
	if (!space_same || edr != fg_synced_edr) {
		if (fg_synced_space != NULL)
			CGColorSpaceRelease(fg_synced_space);
		fg_synced_space = space != NULL ? CGColorSpaceRetain(space) : NULL;
		fg_synced_edr = edr;
		CGColorSpaceRef held = space != NULL ? CGColorSpaceRetain(space) : NULL;
		id metadata = [game respondsToSelector:@selector(EDRMetadata)] ? game.EDRMetadata : nil;
		fg_on_main(^{
			fg_ca_begin();
			layer.colorspace = held;
			if (edr >= 0 && [layer respondsToSelector:@selector(setWantsExtendedDynamicRangeContent:)])
				layer.wantsExtendedDynamicRangeContent = edr != 0;
			if ([layer respondsToSelector:@selector(setEDRMetadata:)])
				layer.EDRMetadata = metadata;
			fg_ca_end();
			if (held != NULL)
				CGColorSpaceRelease(held);
		});
	}
}

static int fg_layer_create(CAMetalLayer *game, NSUInteger width, NSUInteger height, NSUInteger format)
{
	CAMetalLayer *layer = [[CAMetalLayer alloc] init];
	if (layer == nil)
		return 0;
	if (fg_synced_space != NULL)
		CGColorSpaceRelease(fg_synced_space);
	fg_synced_space = game.colorspace != NULL ? CGColorSpaceRetain(game.colorspace) : NULL;
	fg_synced_edr = [game respondsToSelector:@selector(wantsExtendedDynamicRangeContent)] ?
	                        (int)game.wantsExtendedDynamicRangeContent : -1;

	fg_on_main(^{
	fg_ca_begin();
	layer.device = fg_device;
	layer.pixelFormat = (MTLPixelFormat)format;
	layer.colorspace = game.colorspace;
	layer.framebufferOnly = NO;
	layer.maximumDrawableCount = 3;
	layer.presentsWithTransaction = NO;
	// Past the hook, which would take this copy of the game layer's (maybe forced) value for
	// the game's own choice
	if (next_set_display_sync != NULL)
		next_set_display_sync(layer, @selector(setDisplaySyncEnabled:), game.displaySyncEnabled);
	else
		layer.displaySyncEnabled = game.displaySyncEnabled;
	layer.opaque = YES;
	layer.contentsGravity = game.contentsGravity;
	layer.hidden = YES;
	layer.zPosition = 1000;
	if ([layer respondsToSelector:@selector(setWantsExtendedDynamicRangeContent:)])
		layer.wantsExtendedDynamicRangeContent = game.wantsExtendedDynamicRangeContent;
	if ([layer respondsToSelector:@selector(setEDRMetadata:)] && game.EDRMetadata != nil)
		layer.EDRMetadata = game.EDRMetadata;
	layer.contentsScale = game.contentsScale;
	layer.frame = game.bounds;
	layer.drawableSize = CGSizeMake(width, height);
	[game addSublayer:layer];
	fg_ca_end();
	});

	fg_layer = layer;
	return 1;
}

static void fg_layer_destroy(void)
{
	CAMetalLayer *layer = fg_layer, *game = (CAMetalLayer *)fg_game_layer;
	if (layer == nil)
		return;
	fg_on_main(^{
		fg_ca_begin();
		fg_hud_suppress(game, 0);
		[layer removeFromSuperlayer];
		fg_ca_end();
	});
	[layer release];
	fg_layer = nil;
}

// Worker side: tear down what the previous configuration built
static void fg_resources_destroy(void)
{
	fg_engine_destroy(&fg_engine);
	fg_engine_kind = 0;
	for (int i = 0; i < 2; i++) {
		fg_release((id *)&fg_hist[i]);
		fg_release((id *)&fg_diag_buffer[i]);
	}
	fg_release((id *)&fg_diag_texture);
	fg_layer_destroy();
}

static void fg_configure(CAMetalLayer *game, NSUInteger width, NSUInteger height, NSUInteger format,
                         unsigned generation)
{
	double start = fg_now();

	fg_resources_destroy();

	int ok = 1;
	for (int i = 0; i < 2 && ok; i++) {
		fg_hist[i] = fg_make_texture(fg_device, format, width, height, fg_history_usage(), 0);
		ok = fg_hist[i] != nil;
	}
	if (ok)
		ok = fg_engine_create(&fg_engine, fg_device, width, height, format, framegen_engine_pref,
		                      framegen_quality, framegen_ui, framegen_fallback);
	if (ok)
		ok = fg_layer_create(game, width, height, format);
	if (ok) {
		NSUInteger dw = (width + 63) / 64, dh = (height + 63) / 64;
		fg_diag_texture = fg_make_texture(fg_device, MTLPixelFormatR16Float, dw, dh,
		                                  MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, 0);
		for (int i = 0; i < 2; i++)
			fg_diag_buffer[i] = [fg_device newBufferWithLength:dw * dh * 2
			                                           options:MTLResourceStorageModeShared];
	}

	// Outside fg_lock: the present path waits on that lock.
	double refresh_interval = framegen_refresh_override > 0 ? 1.0 / framegen_refresh_override
	                                                        : fg_display_interval(width, height);

	os_unfair_lock_lock(&fg_lock);
	if (atomic_load(&fg_generation) != generation) {
		// Reconfigured again meanwhile; the next configure replaces this
		os_unfair_lock_unlock(&fg_lock);
		return;
	}
	fg_width = width;
	fg_height = height;
	fg_format = format;
	fg_hist_valid = 0;
	fg_hist_next = 0;
	fg_engine_kind = fg_engine.kind;
	fg_refresh_interval = refresh_interval;
	fg_slow_since = fg_fast_since = 0;
	fg_rate_start = 0;
	fg_rate_frames = 0;
	fg_rate_interval = 0;
	atomic_store(&fg_mode, ok ? fg_mode_passthrough : fg_mode_idle);
	os_unfair_lock_unlock(&fg_lock);

	if (!ok) {
		fg_resources_destroy();
		shim_log("overlay_shim framegen: setup failed for %lux%lu %s, framegen off for this layer\n",
		        (unsigned long)width, (unsigned long)height, format_name(format));
		return;
	}

	shim_log("overlay_shim framegen: ready %lux%lu %s engine=%s mode=%s quality=%s flow=%lux%lu "
	        "levels=%d ui=%d fallback=%d refresh=%.0fHz in %.0f ms\n",
	        (unsigned long)width, (unsigned long)height, format_name(format),
	        fg_engine_name(fg_engine.kind), fg_multiplier_name(framegen_multiplier),
	        fg_quality_names[framegen_quality], (unsigned long)fg_engine.flow_ab[0].width,
	        (unsigned long)fg_engine.flow_ab[0].height, fg_engine.levels, framegen_ui, framegen_fallback,
	        1.0 / fg_refresh_interval, (fg_now() - start) * 1000.0);
	if (fg_engine.kind == 2 && framegen_multiplier != fg_mult_2x)
		shim_log("overlay_shim framegen: metalfx generates one frame per pair, mode %s runs as 2x\n",
		        fg_multiplier_name(framegen_multiplier));
}

struct fg_job {
	int slot; // history slot holding this frame
	uint64_t value; // event value signalled after the blit
	double arrived; // game present time
	double interval;
	int interpolate;
	int count; // generated frames for this pair
	double step; // spacing of the presents; 0 = interval/(count+1)
	int reset; // first pair after a history reset
	int first; // unhide the overlay layer once the real copy is presented
	unsigned generation;
};

static void fg_note_gpu(id<MTLCommandBuffer> buffer)
{
	double ms = (buffer.GPUEndTime - buffer.GPUStartTime) * 1000.0;
	if (ms <= 0 || ms > 1000)
		return;
	os_unfair_lock_lock(&fg_lock);
	fg_stat_gpu_ms += ms;
	fg_stat_gpu_n++;
	if (ms > fg_stat_gpu_max_ms)
		fg_stat_gpu_max_ms = ms;
	os_unfair_lock_unlock(&fg_lock);
}

static void fg_track_present(id<CAMetalDrawable> drawable)
{
	[drawable addPresentedHandler:^(id<MTLDrawable> done) {
		if (done.presentedTime > 0)
			atomic_fetch_add(&fg_total_presented, 1);
		else
			atomic_fetch_add(&fg_total_dropped, 1);
	}];
}

// The game's own presents while passing through: whether this layer reaches a
// display at all. Offscreen layers (tests) report every drawable dropped, and
// the safety net must not fire there.
static void fg_track_game_present(id drawable)
{
	if (atomic_load(&fg_game_presented) > 0)
		return;
	[(id<CAMetalDrawable>)drawable addPresentedHandler:^(id<MTLDrawable> done) {
		if (done.presentedTime > 0)
			atomic_fetch_add(&fg_game_presented, 1);
	}];
}

static float fg_half_to_float(uint16_t h)
{
	unsigned sign = (h >> 15) & 1, exp = (h >> 10) & 0x1f, mant = h & 0x3ff;
	float value;
	if (exp == 0)
		value = (float)mant / 1024.0f / 16384.0f;
	else if (exp == 31)
		value = mant ? 0.0f : 1e30f;
	else
		value = ldexpf(1.0f + (float)mant / 1024.0f, (int)exp - 15);
	return sign ? -value : value;
}

// Mean luma of texture into fg_diag_luma[which] once the buffer completes
static void fg_diag_encode(id<MTLCommandBuffer> buffer, id<MTLTexture> texture, int which)
{
	if (fg_diag_texture == nil || fg_diag_buffer[which] == nil || fg_engine.ps_luma == nil)
		return;
	id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
	struct { unsigned scale; } params = { 64 };
	[encoder setTexture:texture atIndex:0];
	[encoder setTexture:fg_diag_texture atIndex:1];
	[encoder setBytes:&params length:sizeof(params) atIndex:0];
	fg_dispatch(encoder, fg_engine.ps_luma, fg_diag_texture.width, fg_diag_texture.height);
	[encoder endEncoding];
	NSUInteger w = fg_diag_texture.width, h = fg_diag_texture.height;
	id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
	[blit copyFromTexture:fg_diag_texture
	                sourceSlice:0
	                sourceLevel:0
	               sourceOrigin:MTLOriginMake(0, 0, 0)
	                 sourceSize:MTLSizeMake(w, h, 1)
	                   toBuffer:fg_diag_buffer[which]
	          destinationOffset:0
	     destinationBytesPerRow:w * 2
	   destinationBytesPerImage:w * h * 2];
	[blit endEncoding];
	id<MTLBuffer> result = fg_diag_buffer[which];
	[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
		if (done.error != nil)
			return;
		const uint16_t *px = result.contents;
		double sum = 0;
		for (NSUInteger i = 0; i < w * h; i++)
			sum += fg_half_to_float(px[i]);
		os_unfair_lock_lock(&fg_lock);
		fg_diag_luma[which] = sum / (double)(w * h);
		os_unfair_lock_unlock(&fg_lock);
	}];
}

static const char *fg_colorspace_name(CGColorSpaceRef space, char *scratch, size_t size)
{
	if (space == NULL)
		return "none";
	CFStringRef name = CGColorSpaceCopyName(space);
	if (name == NULL)
		return "unnamed";
	if (!CFStringGetCString(name, scratch, (CFIndex)size, kCFStringEncodingUTF8))
		snprintf(scratch, size, "?");
	CFRelease(name);
	const char *tail = strrchr(scratch, ' ');
	return tail != NULL ? tail + 1 : scratch;
}

// The overlay layer against the game's, for the stats line. Game thread.
static void fg_describe_layers(char *out, size_t size)
{
	CAMetalLayer *game = (CAMetalLayer *)fg_game_layer;
	CAMetalLayer *layer = fg_layer;
	if (layer == nil || game == nil) {
		snprintf(out, size, "layer=none");
		return;
	}
	char ours[64], theirs[64];
	CGRect frame = layer.frame, bounds = game.bounds;
	int edr_game = [game respondsToSelector:@selector(wantsExtendedDynamicRangeContent)] ?
	                       game.wantsExtendedDynamicRangeContent : -1;
	int edr_ours = [layer respondsToSelector:@selector(wantsExtendedDynamicRangeContent)] ?
	                       layer.wantsExtendedDynamicRangeContent : -1;
	snprintf(out, size,
	         "layer[hidden=%d opacity=%.2f frame=%.0fx%.0f@%.0f,%.0f bounds=%.0fx%.0f scale=%.1f/%.1f "
	         "z=%.0f super=%s cs=%s/%s edr=%d/%d sync=%d/%d]",
	         layer.hidden, layer.opacity, frame.size.width, frame.size.height, frame.origin.x,
	         frame.origin.y, bounds.size.width, bounds.size.height, layer.contentsScale,
	         game.contentsScale, layer.zPosition,
	         layer.superlayer == game ? "game" : layer.superlayer == nil ? "none" : "other",
	         fg_colorspace_name(layer.colorspace, ours, sizeof(ours)),
	         fg_colorspace_name(game.colorspace, theirs, sizeof(theirs)), edr_ours, edr_game,
	         layer.displaySyncEnabled, game.displaySyncEnabled);
}

static void fg_log_stats(double now)
{
	if (!framegen_stats_log)
		return;

	os_unfair_lock_lock(&fg_lock);
	if (fg_stat_start == 0)
		fg_stat_start = now;
	double span = now - fg_stat_start;
	if (span < 1.0) {
		os_unfair_lock_unlock(&fg_lock);
		return;
	}
	char skips[160];
	int used = 0;
	skips[0] = '\0';
	for (int i = 0; i < fg_skip_count; i++) {
		if (fg_stat_skips[i] == 0)
			continue;
		used += snprintf(skips + used, sizeof(skips) - (size_t)used, " %s=%d", fg_skip_names[i],
		                 fg_stat_skips[i]);
		if (used >= (int)sizeof(skips))
			break;
	}
	int presented = atomic_load(&fg_total_presented), dropped = atomic_load(&fg_total_dropped);
	int presented_now = presented - fg_stat_presented, dropped_now = dropped - fg_stat_dropped;
	fg_stat_presented = presented;
	fg_stat_dropped = dropped;
	double luma_real = fg_diag_luma[0], luma_gen = fg_diag_luma[1];
	os_unfair_lock_unlock(&fg_lock);
	char layers[320];
	fg_describe_layers(layers, sizeof(layers));
	os_unfair_lock_lock(&fg_lock);
	shim_log("NP framegen stats: real=%.1f fps generated=%.1f fps gpu=%.2f ms avg %.2f ms max "
	        "engine=%s mode=%s quality=%s ui=%d fallback=%d state=%d lead=%.1f ms presented=%d "
	        "dropped=%d luma real=%.3f gen=%.3f %s skips:%s\n",
	        fg_stat_real / span, fg_stat_generated / span,
	        fg_stat_gpu_n > 0 ? fg_stat_gpu_ms / fg_stat_gpu_n : 0.0, fg_stat_gpu_max_ms,
	        fg_engine_name(fg_engine_kind), fg_multiplier_name(framegen_multiplier),
	        fg_quality_names[framegen_quality], framegen_ui, framegen_fallback, atomic_load(&fg_mode),
	        fg_lead * 1000.0, presented_now, dropped_now, luma_real, luma_gen, layers,
	        skips[0] != '\0' ? skips : " none");
	fg_stat_start = now;
	fg_stat_real = fg_stat_generated = 0;
	fg_stat_gpu_ms = fg_stat_gpu_max_ms = 0;
	fg_stat_gpu_n = 0;
	memset(fg_stat_skips, 0, sizeof(fg_stat_skips));
	os_unfair_lock_unlock(&fg_lock);
}

// Active, presents issued, none reached the glass for about a second: the
// game's own presents are suppressed meanwhile, so hand presentation back.
static void fg_display_check(double now)
{
	if (atomic_load(&fg_mode) != fg_mode_active) {
		fg_display_check_time = 0;
		return;
	}
	int presented = atomic_load(&fg_total_presented);
	int issued = atomic_load(&fg_total_real_copies);
	if (fg_display_check_time == 0) {
		fg_display_check_time = now;
		fg_display_check_presented = presented;
		fg_display_check_issued = issued;
		return;
	}
	if (now - fg_display_check_time < 1.0)
		return;
	int issued_since = issued - fg_display_check_issued;
	int presented_since = presented - fg_display_check_presented;
	fg_display_check_time = now;
	fg_display_check_presented = presented;
	fg_display_check_issued = issued;
	if (issued_since < 10 || presented_since > 0 || atomic_load(&fg_game_presented) == 0)
		return;
	os_unfair_lock_lock(&fg_lock);
	int still_active = atomic_load(&fg_mode) == fg_mode_active;
	if (still_active) {
		fg_mode_store(fg_mode_passthrough);
		fg_hist_valid = 0;
		fg_retry_not_before = now + 5.0; // a few seconds of pass-through before trying again
		fg_slow_since = 0;
		fg_stat_skips[fg_skip_display_dropped]++;
	}
	os_unfair_lock_unlock(&fg_lock);
	if (still_active) {
		fg_layer_set_hidden(1);
		shim_log("overlay_shim framegen: %d presents issued in the last second, none reached the "
		        "display (%d dropped); pass-through\n",
		        issued_since, atomic_load(&fg_total_dropped));
	}
}

// Per-second stats and the display check, driven from the game's present path
static void framegen_tick(void)
{
	if (!framegen_enabled)
		return;
	double now = fg_now();
	fg_display_check(now);
	if (framegen_stats_log)
		fg_log_stats(now);
}

// Releases the game's drawable, no earlier than not_before: a game that asked
// for presentDrawable:afterMinimumDuration: relies on the drawable staying in
// flight that long to pace itself.
static void fg_release_drawable_at(id drawable, double not_before)
{
	if (drawable == nil)
		return;

	double wait = not_before - fg_now();
	if (wait > 0.0005) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * 1e9)), fg_worker, ^{
			[drawable release];
		});
	} else {
		[drawable release];
	}
}

static void fg_run_job(struct fg_job *job)
{
	fg_internal = 1;

	if (job->generation != atomic_load(&fg_generation) || fg_layer == nil ||
	    atomic_load(&fg_mode) != fg_mode_active) {
		fg_internal = 0;
		return;
	}

	fg_layer_sync_geometry((CAMetalLayer *)fg_game_layer);

	int prev_slot = job->slot ^ 1;
	int count = job->interpolate ? job->count : 0;
	if (count < 1 && job->interpolate)
		count = 1;
	if (count > 1 && fg_engine.kind == 2)
		count = 1; // MetalFX makes one frame per pair
	double step = job->step > 0 ? job->step : job->interval / (double)(count + 1);
	double lead = fg_lead;
	if (lead < 0.003)
		lead = 0.003;
	if (lead > step)
		lead = step;
	double target_generated = job->arrived + lead;
	double target_real = target_generated + (double)count * step;
	int failed = 0;
	double now = fg_now();
	int diag = now - fg_diag_time > 1.0; // measure luma on this pair

	if (job->interpolate && fg_engine.kind == 2 &&
	    (job->reset || fg_engine.warm < fg_metalfx_warmup)) {
		// MetalFX echoes the new frame for two encodes after a reset: run them
		// to warm it up, show nothing extra
		id<MTLCommandBuffer> buffer = [fg_queue commandBuffer];
		[buffer encodeWaitForEvent:fg_event value:job->value];
		fg_engine.luma_valid[job->slot] = 0;
		if (job->reset) {
			fg_engine.luma_valid[prev_slot] = 0;
			fg_engine.reset_pending = 1;
		}
		fg_engine_interpolate(&fg_engine, buffer, fg_hist[prev_slot], prev_slot,
		                      fg_hist[job->slot], job->slot, (float)job->interval);
		[buffer commit];
		job->interpolate = 0;
		job->reset = 0;
		fg_stat_skip(fg_skip_warmup);
		target_real = job->arrived + lead;
	} else if (job->interpolate) {
		// Flow once for the pair on the first buffer, then one synthesis per
		// generated frame; each frame gets its own drawable and present time
		id<MTLBuffer> stats = nil;
		if (diag)
			fg_diag_time = now;
		for (int k = 1; k <= count; k++) {
			id<CAMetalDrawable> drawable = [fg_layer nextDrawable];
			if (drawable == nil) {
				fg_stat_skip(fg_skip_no_drawable);
				break;
			}
			id<MTLCommandBuffer> buffer = [fg_queue commandBuffer];
			if (k == 1) {
				[buffer encodeWaitForEvent:fg_event value:job->value];
				fg_engine.luma_valid[job->slot] = 0;
				if (job->reset) {
					fg_engine.luma_valid[prev_slot] = 0;
					fg_engine.reset_pending = 1;
				}
				stats = fg_engine_prepare(&fg_engine, buffer, fg_hist[prev_slot], prev_slot,
				                          fg_hist[job->slot], job->slot);
			}
			fg_engine_synth(&fg_engine, buffer, fg_hist[prev_slot], fg_hist[job->slot],
			                (float)k / (float)(count + 1), (float)job->interval);
			id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
			[blit copyFromTexture:fg_engine.out toTexture:drawable.texture];
			[blit endEncoding];
			if (k == 1 && diag)
				fg_diag_encode(buffer, fg_engine.out, 1);
			fg_track_present(drawable);
			[buffer presentDrawable:drawable atTime:target_generated + (double)(k - 1) * step];
			double started = fg_now();
			int first_of_pair = k == 1;
			struct fg_verdict_args verdict = fg_verdict_args(&fg_engine);
			[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
				fg_note_gpu(done);
				// The pair's verdict is in by now: the stats buffer was written on
				// this queue before any of the pair's syntheses
				int fell_back = fg_verdict(verdict, stats);
				// Submission to GPU completion, in the CACurrentMediaTime domain
				double latency = done.GPUEndTime - started + 0.001;
				if (latency < 0.001 || latency > 0.25)
					latency = 0.003;
				os_unfair_lock_lock(&fg_lock);
				if (first_of_pair)
					fg_lead = fg_lead == 0 ? latency : fg_lead * 0.8 + latency * 0.2;
				if (done.error != nil) {
					fg_stat_skips[fg_skip_error]++;
				} else if (fell_back) {
					if (first_of_pair)
						fg_stat_skips[fg_skip_fast_motion]++;
				} else {
					fg_stat_generated++;
					atomic_fetch_add(&fg_total_generated, 1);
				}
				os_unfair_lock_unlock(&fg_lock);
			}];
			[buffer commit];
		}
	} else {
		target_real = job->arrived + 0.0005;
	}

	id<CAMetalDrawable> real = [fg_layer nextDrawable];
	if (real == nil) {
		fg_stat_skip(fg_skip_no_drawable);
		failed = 1;
	} else {
		id<MTLCommandBuffer> buffer = [fg_queue commandBuffer];
		if (!job->interpolate)
			[buffer encodeWaitForEvent:fg_event value:job->value];
		id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
		[blit copyFromTexture:fg_hist[job->slot] toTexture:real.texture];
		[blit endEncoding];
		if (diag) {
			fg_diag_encode(buffer, fg_hist[job->slot], 0);
			fg_diag_time = now;
		}
		fg_track_present(real);
		[buffer presentDrawable:real atTime:target_real];
		atomic_fetch_add(&fg_total_real_copies, 1);
		int first = job->first;
		if (first) {
			[buffer addScheduledHandler:^(id<MTLCommandBuffer> done) {
				(void)done;
				fg_layer_set_hidden(0);
			}];
		}
		[buffer commit];
	}

	fg_internal = 0;

	if (failed && atomic_load(&fg_mode) == fg_mode_active) {
		// The overlay layer cannot keep up; hand presentation back to the game
		fg_mode_store(fg_mode_passthrough);
		fg_layer_set_hidden(1);
		os_unfair_lock_lock(&fg_lock);
		fg_hist_valid = 0;
		fg_slow_since = 0;
		fg_retry_not_before = fg_now() + 1.0;
		os_unfair_lock_unlock(&fg_lock);
	}
}

static void fg_enqueue_job(struct fg_job job)
{
	atomic_fetch_add(&fg_inflight, 1);
	dispatch_async(fg_worker, ^{
		struct fg_job local = job;
		fg_run_job(&local);
		atomic_fetch_sub(&fg_inflight, 1);
	});
}

// ---------------------------------------------------------------------------
// Game-thread side

static void framegen_init(void)
{
	const char *value = getenv("NOTPROTON_FRAMEGEN");
	if (value == NULL || value[0] == '\0' || value[0] == '0' || strcasecmp(value, "off") == 0)
		return;

	if (strcasecmp(value, "adaptive") == 0)
		framegen_multiplier = fg_mult_adaptive;
	else if (strcasecmp(value, "on") == 0 || atoi(value) == 1 || atoi(value) == 2)
		framegen_multiplier = fg_mult_2x;
	else if (atoi(value) >= 3)
		framegen_multiplier = fg_mult_3x;
	else {
		shim_log("overlay_shim framegen: BRIDGEPLAY_FRAMEGEN=%s not understood (0|1|2|3|adaptive), off\n",
		        value);
		return;
	}
	framegen_enabled = 1;

	const char *engine = getenv("NOTPROTON_FRAMEGEN_ENGINE");
	if (engine != NULL && strcmp(engine, "own") == 0)
		framegen_engine_pref = 1;
	else if (engine != NULL && strcmp(engine, "metalfx") == 0)
		framegen_engine_pref = 2;

	const char *quality = getenv("NOTPROTON_FRAMEGEN_QUALITY");
	framegen_quality = fg_quality_balanced;
	if (quality != NULL && strcasecmp(quality, "performance") == 0)
		framegen_quality = fg_quality_performance;
	else if (quality != NULL && strcasecmp(quality, "quality") == 0)
		framegen_quality = fg_quality_quality;

	const char *ui = getenv("NOTPROTON_FRAMEGEN_UI");
	framegen_ui = ui == NULL || ui[0] == '\0' || ui[0] != '0';
	const char *fallback = getenv("NOTPROTON_FRAMEGEN_FALLBACK");
	framegen_fallback = fallback == NULL || fallback[0] == '\0' || fallback[0] != '0';
	const char *refresh = getenv("NOTPROTON_FRAMEGEN_REFRESH_HZ");
	framegen_refresh_override = refresh != NULL ? atof(refresh) : 0;
	if (framegen_refresh_override < 1 || framegen_refresh_override > 1000)
		framegen_refresh_override = 0;

	// Experimental, so the once-a-second stats are on by default: the Metal HUD only counts
	// the game's own presents and cannot show what generation adds. OVERLAY_SHIM_LOG=0 mutes.
	const char *log = getenv("OVERLAY_SHIM_LOG");
	framegen_stats_log = log == NULL || (log[0] != '\0' && log[0] != '0');

	dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
	        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
	fg_worker = dispatch_queue_create("com.notproton.framegen", attr);

	shim_log("overlay_shim framegen: enabled mode=%s quality=%s ui=%d fallback=%d engine=%s stats=%s%s\n",
	        fg_multiplier_name(framegen_multiplier), fg_quality_names[framegen_quality], framegen_ui,
	        framegen_fallback,
	        framegen_engine_pref == 1 ? "own" : framegen_engine_pref == 2 ? "metalfx" : "auto",
	        framegen_stats_log ? "on" : "off",
	        framegen_refresh_override > 0 ? " (refresh overridden)" : "");
}

static struct fg_pending *fg_pending_find(id buffer, int create)
{
	struct fg_pending *free_slot = NULL;

	for (int i = 0; i < fg_max_pending; i++) {
		if (fg_pending[i].buffer == buffer)
			return &fg_pending[i];
		if (fg_pending[i].buffer == nil && free_slot == NULL)
			free_slot = &fg_pending[i];
	}
	if (!create || free_slot == NULL)
		return NULL;
	memset(free_slot, 0, sizeof(*free_slot));
	free_slot->buffer = buffer;
	return free_slot;
}

static void fg_pending_clear(struct fg_pending *entry)
{
	fg_release(&entry->drawable);
	memset(entry, 0, sizeof(*entry));
}

static void framegen_note_drawable(id layer, id drawable)
{
	(void)layer;
	if (!framegen_enabled || fg_internal || drawable == nil)
		return;
	os_unfair_lock_lock(&fg_lock);
	fg_last_vended_texture = [(id<CAMetalDrawable>)drawable texture];
	os_unfair_lock_unlock(&fg_lock);
}

static void framegen_note_render_pass(id buffer, id attachment)
{
	if (!framegen_enabled || fg_internal || attachment == nil ||
	    atomic_load(&fg_mode) != fg_mode_active)
		return;
	os_unfair_lock_lock(&fg_lock);
	if (attachment == fg_last_vended_texture) {
		struct fg_pending *entry = fg_pending_find(buffer, 1);
		if (entry != NULL && entry->texture == nil)
			entry->texture = attachment;
	}
	os_unfair_lock_unlock(&fg_lock);
}

// Takes a layer as the one framegen follows. Lock held by caller. Returns 0
// when the device offers no queue or event.
static int fg_adopt(CAMetalLayer *layer, id<MTLTexture> texture)
{
	id<MTLDevice> device = texture.device;

	if (fg_device != device) {
		fg_release((id *)&fg_queue);
		fg_release((id *)&fg_event);
		fg_release((id *)&fg_device);
		fg_device = [device retain];
		fg_queue = [fg_device newCommandQueue];
		fg_event = [fg_device newEvent];
		fg_event_value = 0;
	}
	if (fg_queue == nil || fg_event == nil) {
		shim_log("overlay_shim framegen: no queue or event on %s, framegen off\n",
		        [[fg_device name] UTF8String]);
		return 0;
	}
	fg_release(&fg_game_layer);
	fg_game_layer = [layer retain];
	if (layer.framebufferOnly)
		layer.framebufferOnly = NO;
	fg_last_present_time = 0;
	fg_interval = 0;
	fg_blit_texture = nil;
	shim_log("overlay_shim framegen: following layer %p on %s\n", (void *)layer,
	        [[fg_device name] UTF8String]);
	return 1;
}

// Decides what to do with a real frame. Returns 1 to divert it. Holds no lock
// on return; *interpolate is set for the job.
static int fg_decide(id drawable, int *interpolate)
{
	id<CAMetalDrawable> d = drawable;
	id<MTLTexture> texture = d.texture;
	CAMetalLayer *layer = d.layer;
	double now = fg_now();

	if (texture == nil || layer == nil)
		return 0;

	framegen_tick();
	os_unfair_lock_lock(&fg_lock);

	if (layer != fg_game_layer) {
		// A second layer takes over once the followed one has gone quiet
		if (fg_game_layer != nil && now - fg_last_present_time < 0.5) {
			fg_stat_skips[fg_skip_other_layer]++;
			os_unfair_lock_unlock(&fg_lock);
			return 0;
		}
		int was_active = atomic_load(&fg_mode) == fg_mode_active;
		atomic_fetch_add(&fg_generation, 1);
		atomic_store(&fg_mode, fg_mode_idle);
		fg_hist_valid = 0;
		if (!fg_adopt(layer, texture)) {
			os_unfair_lock_unlock(&fg_lock);
			framegen_enabled = 0;
			return 0;
		}
		fg_width = fg_height = 0;
		os_unfair_lock_unlock(&fg_lock);
		if (was_active)
			fg_layer_set_hidden(1);
		os_unfair_lock_lock(&fg_lock);
	}

	// Real-frame timing. The EMA paces the presents; a gap under a quarter of it
	// is a second present inside one vsync (a double present), a gap over 250 ms
	// a stall: neither moves the EMA, neither gets an interpolated frame.
	double interval = fg_interval;
	int double_present = 0, stall = 0;
	if (fg_last_present_time > 0) {
		double gap = now - fg_last_present_time;
		if (gap > 0.25)
			stall = 1;
		else if (interval > 0 && gap < interval * 0.25)
			double_present = 1;
		else
			interval = interval == 0 ? gap : interval * 0.8 + gap * 0.2;
	}
	fg_last_present_time = now;
	fg_interval = interval;
	fg_stat_real++;

	// The smoothed rate: frames per half-second window
	if (fg_rate_start == 0 || stall) {
		fg_rate_start = now;
		fg_rate_frames = 0;
		if (stall)
			fg_rate_interval = 0;
	} else if (now - fg_rate_start >= 0.5) {
		fg_rate_interval = (now - fg_rate_start) / (double)fg_rate_frames;
		fg_rate_start = now;
		fg_rate_frames = 0;
	}
	fg_rate_frames++;

	int mode = atomic_load(&fg_mode);
	int mismatch = texture.width != fg_width || texture.height != fg_height ||
	               texture.pixelFormat != fg_format;

	if (mode == fg_mode_idle || (mismatch && mode != fg_mode_configuring)) {
		if (texture.framebufferOnly) {
			// Cannot copy out of this drawable; the layer is set to stop making them
			fg_stat_skips[fg_skip_mismatch]++;
			os_unfair_lock_unlock(&fg_lock);
			return 0;
		}
		unsigned generation = atomic_fetch_add(&fg_generation, 1) + 1;
		NSUInteger width = texture.width, height = texture.height, format = texture.pixelFormat;
		fg_mode_store(fg_mode_configuring);
		fg_hist_valid = 0;
		fg_blit_texture = nil;
		os_unfair_lock_unlock(&fg_lock);
		if (mode == fg_mode_active)
			fg_layer_set_hidden(1);
		fg_stat_skip(fg_skip_mismatch);
		dispatch_async(fg_worker, ^{
			fg_internal = 1;
			fg_configure(layer, width, height, format, generation);
			fg_internal = 0;
		});
		return 0;
	}

	if (mode == fg_mode_configuring) {
		fg_stat_skips[fg_skip_mismatch]++;
		os_unfair_lock_unlock(&fg_lock);
		return 0;
	}

	// Near the refresh rate already there is nothing to add; generation starts
	// when the smoothed rate has been below ~77% of it for a second and stops
	// when it has been above ~87% for a second, so a cutscene's uneven cadence
	// or a few quick frames do not move the picture between the layers.
	// 3x needs two free slots per real frame, so its thresholds sit at half the
	// refresh rate; adaptive engages like 2x and adds frames as they fit.
	double needed = fg_refresh_interval * (framegen_multiplier == fg_mult_3x ? 2.0 : 1.0);
	int rate_known = fg_rate_interval > 0;
	int fast = rate_known && fg_rate_interval < needed * 1.15;
	int slow = rate_known && fg_rate_interval > needed * 1.3;
	if (mode == fg_mode_active) {
		if (fast) {
			if (fg_fast_since == 0)
				fg_fast_since = now;
			if (now - fg_fast_since >= 1.0) {
				fg_mode_store(fg_mode_passthrough);
				fg_hist_valid = 0;
				fg_fast_since = fg_slow_since = 0;
				os_unfair_lock_unlock(&fg_lock);
				fg_layer_set_hidden(1);
				fg_stat_skip(fg_skip_fast);
				return 0;
			}
		} else {
			fg_fast_since = 0;
		}
	} else {
		// Pass-through: wait for a second of slow frames and an idle worker
		if (!slow || now < fg_retry_not_before) {
			fg_slow_since = 0;
			fg_stat_skips[fast ? fg_skip_fast : fg_skip_settling]++;
			os_unfair_lock_unlock(&fg_lock);
			return 0;
		}
		if (fg_slow_since == 0)
			fg_slow_since = now;
		if (now - fg_slow_since < 1.0 || atomic_load(&fg_inflight) > 0) {
			fg_stat_skips[fg_skip_settling]++;
			os_unfair_lock_unlock(&fg_lock);
			return 0;
		}
		fg_mode_store(fg_mode_active);
		fg_hist_valid = 0;
		fg_fast_since = 0;
		fg_unhide_pending = 1;
	}

	int inflight = atomic_load(&fg_inflight);
	if (inflight >= 4) {
		fg_mode_store(fg_mode_passthrough);
		fg_hist_valid = 0;
		fg_slow_since = 0;
		fg_retry_not_before = now + 1.0;
		os_unfair_lock_unlock(&fg_lock);
		fg_layer_set_hidden(1);
		fg_stat_skip(fg_skip_lag);
		return 0;
	}
	if (stall)
		fg_hist_valid = 0; // the pair across a stall is not worth a frame
	*interpolate = fg_hist_valid >= 1 && inflight < 2 && interval > 0 && !double_present && !stall;
	if (!*interpolate && fg_hist_valid >= 1 && interval > 0) {
		if (double_present)
			fg_stat_skips[fg_skip_double_present]++;
		else if (!stall)
			fg_stat_skips[fg_skip_lag]++;
	}
	os_unfair_lock_unlock(&fg_lock);
	return 1;
}

// Encodes the history copy for texture on buffer. Lock held by caller.
static void fg_encode_copy(id<MTLCommandBuffer> buffer, id<MTLTexture> texture, double now)
{
	int slot;
	if (fg_blit_texture == texture && fg_blit_texture != nil) {
		slot = fg_blit_slot; // another buffer into the same frame: overwrite
	} else {
		slot = fg_hist_next;
		fg_hist_next ^= 1;
	}
	if (fg_hist[slot] == nil || texture.width != fg_hist[slot].width ||
	    texture.height != fg_hist[slot].height || texture.pixelFormat != fg_hist[slot].pixelFormat)
		return;

	id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
	[blit copyFromTexture:texture toTexture:fg_hist[slot]];
	[blit endEncoding];
	[buffer encodeSignalEvent:fg_event value:++fg_event_value];
	fg_blit_texture = texture;
	fg_blit_value = fg_event_value;
	fg_blit_slot = slot;
	fg_blit_time = now;
}

// After the copy is encoded: hand the frame to the worker. Lock held by caller.
static void fg_launch(int interpolate)
{
	struct fg_job job;
	memset(&job, 0, sizeof(job));
	job.slot = fg_blit_slot;
	job.value = fg_blit_value;
	job.arrived = fg_blit_time;
	job.interval = fg_interval;
	job.interpolate = interpolate && fg_hist_valid >= 1;
	job.count = 1;
	job.step = 0;
	if (framegen_multiplier == fg_mult_3x) {
		job.count = 2;
	} else if (framegen_multiplier == fg_mult_adaptive && fg_refresh_interval > 0) {
		// One generated frame per refresh slot between this real frame and the next
		int slots = (int)(fg_interval / fg_refresh_interval + 0.5) - 1;
		job.count = slots < 1 ? 1 : slots > fg_adaptive_max ? fg_adaptive_max : slots;
		job.step = fg_refresh_interval;
	}
	job.reset = fg_hist_valid < 2;
	job.first = fg_unhide_pending;
	fg_unhide_pending = 0;
	job.generation = atomic_load(&fg_generation);
	if (fg_hist_valid < 2)
		fg_hist_valid++;
	fg_blit_texture = nil;
	fg_enqueue_job(job);
}

// Command buffer present hooks. These sit under the overlay's own swizzles, so
// the overlay has drawn by the time they run.
typedef void (*present_drawable_fn)(id, SEL, id);
typedef void (*present_drawable_timed_fn)(id, SEL, id, CFTimeInterval);

static present_drawable_fn next_present_drawable;
static present_drawable_timed_fn next_present_drawable_after;
static present_drawable_timed_fn next_present_drawable_at;
static void (*next_commit)(id, SEL);

static int fg_divert_present(id buffer, id drawable, double min_duration)
{
	if (!framegen_enabled || fg_internal || drawable == nil)
		return 0;
	if ([(id<CAMetalDrawable>)drawable layer] == fg_layer)
		return 0;

	int interpolate = 0;
	int divert = fg_decide(drawable, &interpolate);

	os_unfair_lock_lock(&fg_lock);
	if (!divert) {
		// The original present follows; the drawable-level hook must not count it again
		fg_passthrough_drawable = drawable;
		os_unfair_lock_unlock(&fg_lock);
		fg_track_game_present(drawable);
		return 0;
	}
	struct fg_pending *entry = fg_pending_find(buffer, 1);
	if (entry == NULL) {
		fg_passthrough_drawable = drawable;
		os_unfair_lock_unlock(&fg_lock);
		fg_stat_skip(fg_skip_error);
		return 0;
	}
	fg_release(&entry->drawable);
	entry->drawable = [drawable retain];
	entry->texture = [(id<CAMetalDrawable>)drawable texture];
	entry->divert = 1 | (interpolate ? 2 : 0);
	entry->min_duration = min_duration;
	os_unfair_lock_unlock(&fg_lock);
	return 1;
}

static void hook_present_drawable(id self, SEL selector, id drawable)
{
	if (fg_divert_present(self, drawable, 0))
		return;
	next_present_drawable(self, selector, drawable);
}

static void hook_present_drawable_after(id self, SEL selector, id drawable, CFTimeInterval duration)
{
	if (fg_divert_present(self, drawable, duration))
		return;
	next_present_drawable_after(self, selector, drawable, duration);
}

static void hook_present_drawable_at(id self, SEL selector, id drawable, CFTimeInterval time)
{
	if (fg_divert_present(self, drawable, 0))
		return;
	next_present_drawable_at(self, selector, drawable, time);
}

static void hook_commit(id self, SEL selector)
{
	if (!fg_internal && framegen_enabled && atomic_load(&fg_mode) == fg_mode_active) {
		os_unfair_lock_lock(&fg_lock);
		struct fg_pending *entry = fg_pending_find(self, 0);
		if (entry != NULL) {
			struct fg_pending local = *entry;
			memset(entry, 0, sizeof(*entry));
			if (local.texture != nil && fg_hist[0] != nil)
				fg_encode_copy(self, local.texture, fg_now());
			double arrived = fg_blit_time;
			if (local.divert && fg_blit_texture == local.texture)
				fg_launch((local.divert & 2) != 0);
			else if (local.divert)
				fg_stat_skips[fg_skip_error]++; // copy refused, frame lost
			os_unfair_lock_unlock(&fg_lock);
			if (local.drawable != nil) {
				// The copy reads the drawable on this buffer (the game's queue,
				// or the Metal 4 bridge queue): keep it out of the pool until
				// the buffer is done, and as long as the game's frame cap asked
				id held = local.drawable;
				double hold_until = local.min_duration > 0 ? arrived + local.min_duration : 0;
				[self addCompletedHandler:^(id<MTLCommandBuffer> done) {
					(void)done;
					fg_release_drawable_at(held, hold_until);
				}];
			}
		} else {
			os_unfair_lock_unlock(&fg_lock);
		}
	} else if (!fg_internal && framegen_enabled) {
		os_unfair_lock_lock(&fg_lock);
		struct fg_pending *entry = fg_pending_find(self, 0);
		if (entry != NULL)
			fg_pending_clear(entry);
		os_unfair_lock_unlock(&fg_lock);
	}
	next_commit(self, selector);
}

// A drawable presented on its own ([drawable present], no buffer named). Only
// divertable when a copy was already encoded for it at a commit.
static int framegen_divert_plain_present(id drawable, double min_duration)
{
	if (!framegen_enabled || fg_internal || drawable == nil)
		return 0;
	if ([(id<CAMetalDrawable>)drawable layer] == fg_layer)
		return 0;

	id<MTLTexture> texture = [(id<CAMetalDrawable>)drawable texture];
	os_unfair_lock_lock(&fg_lock);
	if (fg_passthrough_drawable == drawable) {
		fg_passthrough_drawable = nil;
		os_unfair_lock_unlock(&fg_lock);
		return 0;
	}
	int ready = fg_blit_texture == texture && texture != nil;
	os_unfair_lock_unlock(&fg_lock);

	int interpolate = 0;
	if (!fg_decide(drawable, &interpolate))
		return 0;
	if (!ready) {
		static int logged;
		if (!logged) {
			logged = 1;
			shim_log("overlay_shim framegen: a drawable presented without a copy, this present "
			        "path passes through\n");
		}
		fg_stat_skip(fg_skip_unordered);
		return 0;
	}

	os_unfair_lock_lock(&fg_lock);
	double arrived = fg_blit_time;
	fg_launch(interpolate);
	os_unfair_lock_unlock(&fg_lock);
	if (min_duration > 0)
		fg_release_drawable_at([drawable retain], arrived + min_duration);
	return 1;
}

// Hooks under the overlay's: the renamed original when the overlay already
// swizzled, the selector itself otherwise. Either way the overlay has drawn
// before these run.
static const char *fg_inner_selector(Class target, const char *selector_name, char *scratch,
                                     size_t size)
{
	snprintf(scratch, size, "steamoverlay_%s", selector_name);
	return class_has_method(target, scratch) ? scratch : selector_name;
}

static void framegen_install_command_buffer_hooks(Class target)
{
	if (!framegen_enabled || target == Nil)
		return;

	char scratch[96];
	int hooked = 0;
	hooked += interpose(target, fg_inner_selector(target, "presentDrawable:", scratch, sizeof(scratch)),
	                    (IMP)hook_present_drawable, (IMP *)&next_present_drawable);
	hooked += interpose(target,
	                    fg_inner_selector(target, "presentDrawable:afterMinimumDuration:", scratch,
	                                      sizeof(scratch)),
	                    (IMP)hook_present_drawable_after, (IMP *)&next_present_drawable_after);
	hooked += interpose(target, fg_inner_selector(target, "presentDrawable:atTime:", scratch, sizeof(scratch)),
	                    (IMP)hook_present_drawable_at, (IMP *)&next_present_drawable_at);
	hooked += interpose(target, fg_inner_selector(target, "commit", scratch, sizeof(scratch)),
	                    (IMP)hook_commit, (IMP *)&next_commit);
	atomic_store(&fg_hooks_installed, hooked);
	shim_log("overlay_shim framegen: %s hooks=%d under_overlay=%s\n", class_getName(target), hooked,
	        class_has_method(target, "steamoverlay_commit") ? "yes" : "no");
}

typedef void (*set_bool_fn)(id, SEL, BOOL);
static set_bool_fn next_set_framebuffer_only;

static void hook_set_framebuffer_only(id layer, SEL selector, BOOL value)
{
	if (value && framegen_enabled) {
		static int logged;
		if (!logged) {
			logged = 1;
			shim_log("overlay_shim framegen: layer asked for framebufferOnly, kept off so frames "
			        "can be copied\n");
		}
		value = 0;
	}
	next_set_framebuffer_only(layer, selector, value);
}

static void framegen_install_layer_hooks(Class layer)
{
	if (!framegen_enabled)
		return;
	interpose(layer, "setFramebufferOnly:", (IMP)hook_set_framebuffer_only,
	          (IMP *)&next_set_framebuffer_only);
}

// Test entry: what the display did with the overlay layer, and what it was shown
__attribute__((visibility("default"))) void np_framegen_probe_display(int *presented, int *dropped,
                                                                      double *luma_real,
                                                                      double *luma_generated,
                                                                      int *state_changes)
{
	if (state_changes != NULL)
		*state_changes = atomic_load(&fg_total_state_changes);
	if (presented != NULL)
		*presented = atomic_load(&fg_total_presented);
	if (dropped != NULL)
		*dropped = atomic_load(&fg_total_dropped);
	os_unfair_lock_lock(&fg_lock);
	if (luma_real != NULL)
		*luma_real = fg_diag_luma[0];
	if (luma_generated != NULL)
		*luma_generated = fg_diag_luma[1];
	os_unfair_lock_unlock(&fg_lock);
}

// Test entry: what framegen has done so far
__attribute__((visibility("default"))) void np_framegen_probe(int *enabled, int *hooks, int *mode,
                                                              int *objects, int *generated,
                                                              int *real_copies)
{
	if (generated != NULL)
		*generated = atomic_load(&fg_total_generated);
	if (real_copies != NULL)
		*real_copies = atomic_load(&fg_total_real_copies);
	if (enabled != NULL)
		*enabled = framegen_enabled;
	if (hooks != NULL)
		*hooks = atomic_load(&fg_hooks_installed) + (next_set_framebuffer_only != NULL ? 1 : 0);
	if (mode != NULL)
		*mode = atomic_load(&fg_mode);
	if (objects != NULL)
		*objects = (fg_worker != NULL) + (fg_queue != nil) + (fg_event != nil) + (fg_layer != nil) +
		           (fg_hist[0] != nil) + (fg_engine.kind != 0);
}
