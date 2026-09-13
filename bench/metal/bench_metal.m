/*
 * bench_metal.m - GPU counterpart of ../cpu/bench_cpu.c for Apple silicon.
 *
 *   1. peak FP throughput   (FMA chains, f32 + f16, no memory traffic)
 *   2. memory bandwidth     (read / copy / triad over a large device buffer)
 *   3. cache hierarchy      (read bandwidth vs. working set + pointer-chase latency)
 *
 * Shader source is embedded and compiled at run time, so there is no offline
 * .metallib step.  Timing uses the command buffer's GPU timestamps, which
 * exclude CPU-side encode and submit overhead.
 *
 * Build: clang -fobjc-arc -O2 -framework Metal -framework Foundation \
 *              -framework MetalPerformanceShaders bench_metal.m -o bench_metal
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <math.h>

static NSString *const kSrc = @R"MSL(
#include <metal_stdlib>
#include <metal_simdgroup_matrix>
using namespace metal;

/* ---- 1. peak FP: 8 independent FMA chains, nothing touches memory.
 *
 * Every accumulator is seeded from the thread id.  This is not cosmetic: Apple
 * GPUs have a uniform (scalar) datapath, and if nothing in the chain varies
 * per lane the compiler hoists the entire loop onto it and runs it once per
 * simdgroup instead of once per lane.  With uniform seeds this kernel reports
 * ~130 TFLOP/s on a 5.3 TFLOP/s GPU.  Keep every lane's value distinct, and
 * keep every vector component live in the final reduction, or the numbers are
 * fiction.
 *
 * The result is stored unconditionally.  The usual trick of hiding the store
 * behind `if (sum == <sentinel>)` is a trap for half/bfloat: no half value can
 * equal 1234.5 exactly, the compiler proves the branch dead, and the entire
 * loop disappears (it reported 97 PFLOP/s before this was fixed).  One store
 * per thread is free next to a few hundred ms of ALU work. ---- */
kernel void fp32_fma(device float *out [[buffer(0)]],
                     constant uint  &iters [[buffer(1)]],
                     constant float2 &k [[buffer(2)]],
                     uint tid [[thread_position_in_grid]]) {
    float4 v = float4(tid) * 1e-9f;      /* see note above: must vary per lane */
    float4 m = float4(k.x), b = float4(k.y);
    float4 a0=float4(0.1)+v, a1=float4(0.2)+v, a2=float4(0.3)+v, a3=float4(0.4)+v;
    float4 a4=float4(0.5)+v, a5=float4(0.6)+v, a6=float4(0.7)+v, a7=float4(0.8)+v;
    for (uint i = 0; i < iters; i++) {
        a0 = fma(m,b,a0); a1 = fma(m,b,a1); a2 = fma(m,b,a2); a3 = fma(m,b,a3);
        a4 = fma(m,b,a4); a5 = fma(m,b,a5); a6 = fma(m,b,a6); a7 = fma(m,b,a7);
    }
    float4 s = ((a0+a1)+(a2+a3)) + ((a4+a5)+(a6+a7));
    out[tid] = s.x + s.y + s.z + s.w;      /* unconditional: see note above */
}

kernel void fp16_fma(device float *out [[buffer(0)]],
                     constant uint  &iters [[buffer(1)]],
                     constant float2 &k [[buffer(2)]],
                     uint tid [[thread_position_in_grid]]) {
    half4 v = half4(float4(tid) * 1e-5f);
    half4 m = half4(k.x), b = half4(k.y);
    half4 a0=half4(0.1h)+v, a1=half4(0.2h)+v, a2=half4(0.3h)+v, a3=half4(0.4h)+v;
    half4 a4=half4(0.5h)+v, a5=half4(0.6h)+v, a6=half4(0.7h)+v, a7=half4(0.8h)+v;
    for (uint i = 0; i < iters; i++) {
        a0 = fma(m,b,a0); a1 = fma(m,b,a1); a2 = fma(m,b,a2); a3 = fma(m,b,a3);
        a4 = fma(m,b,a4); a5 = fma(m,b,a5); a6 = fma(m,b,a6); a7 = fma(m,b,a7);
    }
    half4 s = ((a0+a1)+(a2+a3)) + ((a4+a5)+(a6+a7));
    out[tid] = float(s.x) + float(s.y) + float(s.z) + float(s.w);
}

/* bf16: MSL has no fma() overload for bfloat, so spell out mul+add.  On parts
   without a native bf16 ALU this lowers to f32 math, which the measured rate
   will show (bf16 ~= f32 means emulated; ~2x means native). */
kernel void bf16_fma(device float *out [[buffer(0)]],
                     constant uint  &iters [[buffer(1)]],
                     constant float2 &k [[buffer(2)]],
                     uint tid [[thread_position_in_grid]]) {
    float4 v = float4(tid) * 1e-5f;
    bfloat4 m = bfloat4(float4(k.x)), b = bfloat4(float4(k.y));
    bfloat4 a0=bfloat4(float4(0.1)+v), a1=bfloat4(float4(0.2)+v),
            a2=bfloat4(float4(0.3)+v), a3=bfloat4(float4(0.4)+v),
            a4=bfloat4(float4(0.5)+v), a5=bfloat4(float4(0.6)+v),
            a6=bfloat4(float4(0.7)+v), a7=bfloat4(float4(0.8)+v);
    for (uint i = 0; i < iters; i++) {
        a0 = m*b+a0; a1 = m*b+a1; a2 = m*b+a2; a3 = m*b+a3;
        a4 = m*b+a4; a5 = m*b+a5; a6 = m*b+a6; a7 = m*b+a7;
    }
    bfloat4 s = ((a0+a1)+(a2+a3)) + ((a4+a5)+(a6+a7));
    out[tid] = float(s.x) + float(s.y) + float(s.z) + float(s.w);
}

/* simdgroup 8x8 matrix multiply-accumulate: 512 MACs per instruction per
   simdgroup.  This is the matrix path, not the vector ALU path. */
kernel void mma_f16(device float *out [[buffer(0)]],
                    constant uint &iters [[buffer(1)]],
                    uint tid [[thread_position_in_grid]]) {
    float seed = float(tid) * 1e-9f;
    simdgroup_half8x8  A(half(1.0h + half(seed))), B(1.0001h);
    simdgroup_float8x8 c0(seed), c1(seed), c2(seed), c3(seed);
    for (uint i = 0; i < iters; i++) {
        simdgroup_multiply_accumulate(c0, A, B, c0);
        simdgroup_multiply_accumulate(c1, A, B, c1);
        simdgroup_multiply_accumulate(c2, A, B, c2);
        simdgroup_multiply_accumulate(c3, A, B, c3);
    }
    float s = c0.thread_elements()[0] + c1.thread_elements()[0] +
              c2.thread_elements()[0] + c3.thread_elements()[0];
    out[tid] = s;
}

/* ---- 2/3. memory: grid-stride so consecutive lanes touch consecutive
       float4s, which is what the coalescer wants.  n4 = float4 count of the
       window; sweeping a window smaller than the buffer is how the cache
       hierarchy gets probed. ---- */
kernel void mem_read(device const float4 *in [[buffer(0)]],
                     device float *out [[buffer(1)]],
                     constant uint &n4 [[buffer(2)]],
                     constant uint &reps [[buffer(3)]],
                     uint tid [[thread_position_in_grid]],
                     uint gsz [[threads_per_grid]]) {
    float4 s = float4(0);
    for (uint r = 0; r < reps; r++)
        for (uint i = tid; i < n4; i += gsz) s += in[i];
    if (s.x + s.y + s.z + s.w == 1234.5f) out[tid] = s.x;
}

kernel void mem_copy(device const float4 *in [[buffer(0)]],
                     device float4 *dst [[buffer(1)]],
                     constant uint &n4 [[buffer(2)]],
                     uint tid [[thread_position_in_grid]],
                     uint gsz [[threads_per_grid]]) {
    for (uint i = tid; i < n4; i += gsz) dst[i] = in[i];
}

kernel void mem_triad(device float4 *a [[buffer(0)]],
                      device const float4 *b [[buffer(1)]],
                      device const float4 *c [[buffer(2)]],
                      constant uint &n4 [[buffer(3)]],
                      constant float &s [[buffer(4)]],
                      uint tid [[thread_position_in_grid]],
                      uint gsz [[threads_per_grid]]) {
    for (uint i = tid; i < n4; i += gsz) a[i] = fma(float4(s), c[i], b[i]);
}

/* Power-of-two window, wrapped with a mask, so every lane reads inside the
   working set and the access pattern stays coalesced. */
kernel void mem_read_ws(device const float4 *in [[buffer(0)]],
                        device float *out [[buffer(1)]],
                        constant uint &mask [[buffer(2)]],
                        constant uint &iters [[buffer(3)]],
                        uint tid [[thread_position_in_grid]],
                        uint gsz [[threads_per_grid]]) {
    float4 s = float4(0);
    uint p = tid & mask;
    for (uint k = 0; k < iters; k++) { s += in[p]; p = (p + gsz) & mask; }
    if (s.x + s.y + s.z + s.w == 1234.5f) out[tid] = s.x;
}

/* ---- 3b. pointer chase: one lane, fully serial dependent loads ---- */
kernel void chase(device const uint *idx [[buffer(0)]],
                  device uint *out [[buffer(1)]],
                  constant uint &steps [[buffer(2)]]) {
    uint p = 0;
    for (uint i = 0; i < steps; i++) p = idx[p];
    out[0] = p;
}
)MSL";

/* ------------------------------------------------------------------ util */

static id<MTLDevice>              gDev;
static id<MTLCommandQueue>        gQ;
static id<MTLLibrary>             gLib;

static id<MTLComputePipelineState> pipeline(NSString *name) {
    NSError *err = nil;
    id<MTLFunction> fn = [gLib newFunctionWithName:name];
    if (!fn) { fprintf(stderr, "missing kernel %s\n", name.UTF8String); exit(1); }
    id<MTLComputePipelineState> p =
        [gDev newComputePipelineStateWithFunction:fn error:&err];
    if (!p) { fprintf(stderr, "pipeline %s: %s\n", name.UTF8String,
                      err.localizedDescription.UTF8String); exit(1); }
    return p;
}

/* Runs the encoded work and returns GPU-side seconds, best of `reps`. */
typedef void (^encode_b)(id<MTLComputeCommandEncoder> enc);

static double timed(id<MTLComputePipelineState> p, MTLSize grid, MTLSize tg,
                    int reps, encode_b enc) {
    double best = INFINITY;
    for (int r = 0; r < reps; r++) {
        id<MTLCommandBuffer> cb = [gQ commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:p];
        enc(e);
        [e dispatchThreadgroups:grid threadsPerThreadgroup:tg];
        [e endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) { fprintf(stderr, "gpu: %s\n",
                                cb.error.localizedDescription.UTF8String); exit(1); }
        double dt = cb.GPUEndTime - cb.GPUStartTime;
        if (dt > 0 && dt < best) best = dt;
    }
    return best;
}

/* Report in TFLOP/s once the number earns it. */
static const char *flops_s(double gflops, char *b, size_t n) {
    if (gflops <= 0)          snprintf(b, n, "%s", "n/a");
    else if (gflops >= 1000)  snprintf(b, n, "%.2f TFLOP/s", gflops / 1000.0);
    else                      snprintf(b, n, "%.1f GFLOP/s", gflops);
    return b;
}

static const char *bw_s(double gbs, char *b, size_t n) {
    if (gbs >= 1000) snprintf(b, n, "%.2f TB/s", gbs / 1000.0);
    else             snprintf(b, n, "%.1f GB/s", gbs);
    return b;
}

static const char *hsize(size_t b, char *buf, size_t n) {
    if (b >= (1u << 20)) snprintf(buf, n, "%.3g MiB", b / 1048576.0);
    else                 snprintf(buf, n, "%.3g KiB", b / 1024.0);
    return buf;
}

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv) {
    @autoreleasepool {
        int quick = 0;
        for (int i = 1; i < argc; i++)
            if (!strcmp(argv[i], "-q")) quick = 1;
            else { fprintf(stderr, "usage: %s [-q]\n", argv[0]); return 2; }

        gDev = MTLCreateSystemDefaultDevice();
        if (!gDev) { fprintf(stderr, "no Metal device\n"); return 1; }
        gQ = [gDev newCommandQueue];

        NSError *err = nil;
        MTLCompileOptions *opt = [MTLCompileOptions new];
        opt.languageVersion = MTLLanguageVersion3_1;   /* bfloat, simdgroup_matrix */
        /* Without this the compiler is free to reassociate acc += m*b into a
         * closed form and the "peak FP" number comes out ~30x the hardware.
         * fastMathEnabled is deprecated and ignored on macOS 15+, so set both. */
        if (@available(macOS 15.0, iOS 18.0, *)) opt.mathMode = MTLMathModeSafe;
        else opt.fastMathEnabled = NO;
        gLib = [gDev newLibraryWithSource:kSrc options:opt error:&err];
        if (!gLib) { fprintf(stderr, "shader compile failed:\n%s\n",
                             err.localizedDescription.UTF8String); return 1; }

        printf("=== GPU (Metal) ===\n");
        printf("  %s\n", gDev.name.UTF8String);
        printf("  unified memory: %s, max working set %.1f GiB\n",
               gDev.hasUnifiedMemory ? "yes" : "no",
               gDev.recommendedMaxWorkingSetSize / 1073741824.0);

        id<MTLComputePipelineState> pFp32  = pipeline(@"fp32_fma");
        id<MTLComputePipelineState> pFp16  = pipeline(@"fp16_fma");
        id<MTLComputePipelineState> pBf16  = pipeline(@"bf16_fma");
        id<MTLComputePipelineState> pMma   = pipeline(@"mma_f16");
        id<MTLComputePipelineState> pRead  = pipeline(@"mem_read");
        id<MTLComputePipelineState> pReadWs = pipeline(@"mem_read_ws");
        id<MTLComputePipelineState> pCopy  = pipeline(@"mem_copy");
        id<MTLComputePipelineState> pTriad = pipeline(@"mem_triad");
        id<MTLComputePipelineState> pChase = pipeline(@"chase");

        NSUInteger tgSize = pFp32.maxTotalThreadsPerThreadgroup;
        if (tgSize > 256) tgSize = 256;
        NSUInteger ntg = 2048;                       /* plenty to fill any GPU */
        NSUInteger threads = tgSize * ntg;
        printf("  threadgroup %lu threads, %lu groups (%lu lanes total)\n",
               (unsigned long)tgSize, (unsigned long)ntg, (unsigned long)threads);
        printf("  simd width %lu, fp32 pipeline max threads/group %lu\n",
               (unsigned long)pFp32.threadExecutionWidth,
               (unsigned long)pFp32.maxTotalThreadsPerThreadgroup);

        MTLSize grid = MTLSizeMake(ntg, 1, 1), tg = MTLSizeMake(tgSize, 1, 1);
        int reps = quick ? 2 : 4;

        /* ---------------- 1. peak FP ---------------- */
        printf("\n=== 1. peak FP throughput (FMA chains, no memory traffic) ===\n");
        id<MTLBuffer> sink = [gDev newBufferWithLength:threads * 4
                                               options:MTLResourceStorageModeShared];
        uint32_t fpIters = quick ? 20000 : 80000;
        struct { float m, b; } k = { 1e-9f, 1.0000001f };

        struct { const char *nm; id<MTLComputePipelineState> p; } fp[] = {
            { "f32", pFp32 }, { "f16", pFp16 }, { "bf16", pBf16 },
        };
        for (int i = 0; i < 3; i++) {
            double t = timed(fp[i].p, grid, tg, reps, ^(id<MTLComputeCommandEncoder> e) {
                [e setBuffer:sink offset:0 atIndex:0];
                [e setBytes:&fpIters length:sizeof fpIters atIndex:1];
                [e setBytes:&k length:sizeof k atIndex:2];
            });
            /* 8 chains x 4 lanes x 2 flops per iteration per thread */
            double flops = (double)threads * fpIters * 8.0 * 4.0 * 2.0;
            char fb[32];
            printf("  %-14s %14s\n", fp[i].nm, flops_s(flops / t / 1e9, fb, sizeof fb));
        }
        printf("  %-14s %14s   (Metal has no double type)\n", "f64", "n/a");
        {
            uint32_t mmaIters = fpIters / 4;
            double t = timed(pMma, grid, tg, reps, ^(id<MTLComputeCommandEncoder> e) {
                [e setBuffer:sink offset:0 atIndex:0];
                [e setBytes:&mmaIters length:sizeof mmaIters atIndex:1];
            });
            /* 4 chains x 8x8x8 MACs x 2 flops, once per simdgroup */
            double sgs = (double)threads / pFp32.threadExecutionWidth;
            double flops = sgs * mmaIters * 4.0 * 512.0 * 2.0;
            char fb[32];
            printf("  %-14s %14s  (simdgroup 8x8 matrix)\n",
                   "f16 matrix", flops_s(flops / t / 1e9, fb, sizeof fb));
        }

        /* A hand-written FMA loop is a floor, not a ceiling, on Apple GPUs.
         * MPS's tuned GEMM is the reference for what the part can actually
         * sustain, so report both and let the gap be visible. */
        {
            const int N = 4096;
            MPSDataType dts[2] = { MPSDataTypeFloat32, MPSDataTypeFloat16 };
            const char *dtn[2] = { "f32 GEMM (MPS)", "f16 GEMM (MPS)" };
            for (int i = 0; i < 2; i++) {
                size_t esz = (dts[i] == MPSDataTypeFloat32) ? 4 : 2;
                MPSMatrixDescriptor *desc =
                    [MPSMatrixDescriptor matrixDescriptorWithRows:N columns:N
                                                        rowBytes:N * esz dataType:dts[i]];
                id<MTLBuffer> ba = [gDev newBufferWithLength:(NSUInteger)N * N * esz
                                                     options:MTLResourceStorageModePrivate];
                id<MTLBuffer> bb = [gDev newBufferWithLength:(NSUInteger)N * N * esz
                                                     options:MTLResourceStorageModePrivate];
                id<MTLBuffer> bc = [gDev newBufferWithLength:(NSUInteger)N * N * esz
                                                     options:MTLResourceStorageModePrivate];
                MPSMatrix *MA = [[MPSMatrix alloc] initWithBuffer:ba descriptor:desc];
                MPSMatrix *MB = [[MPSMatrix alloc] initWithBuffer:bb descriptor:desc];
                MPSMatrix *MC = [[MPSMatrix alloc] initWithBuffer:bc descriptor:desc];
                MPSMatrixMultiplication *mm =
                    [[MPSMatrixMultiplication alloc] initWithDevice:gDev
                        transposeLeft:NO transposeRight:NO resultRows:N resultColumns:N
                        interiorColumns:N alpha:1.0 beta:0.0];
                double best = INFINITY;
                for (int r = 0; r < reps + 1; r++) {
                    id<MTLCommandBuffer> cb = [gQ commandBuffer];
                    [mm encodeToCommandBuffer:cb leftMatrix:MA rightMatrix:MB resultMatrix:MC];
                    [cb commit];
                    [cb waitUntilCompleted];
                    double dt = cb.GPUEndTime - cb.GPUStartTime;
                    if (dt > 0 && dt < best) best = dt;
                }
                double flops = 2.0 * N * N * (double)N;
                char fb[32];
                printf("  %-14s %14s  (tuned reference)\n", dtn[i],
                       flops_s(flops / best / 1e9, fb, sizeof fb));
            }
        }

        /* ---------------- 2. bandwidth ---------------- */
        size_t bytes = (size_t)(quick ? 128 : 256) * 1048576;
        uint32_t n4  = (uint32_t)(bytes / 16);
        id<MTLBuffer> A = [gDev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
        id<MTLBuffer> B = [gDev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
        id<MTLBuffer> C = [gDev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];

        printf("\n=== 2. memory bandwidth (%zu MiB buffers) ===\n", bytes >> 20);
        uint32_t one = 1;
        double t;

        t = timed(pRead, grid, tg, reps, ^(id<MTLComputeCommandEncoder> e) {
            [e setBuffer:A offset:0 atIndex:0];
            [e setBuffer:sink offset:0 atIndex:1];
            [e setBytes:&n4 length:4 atIndex:2];
            [e setBytes:&one length:4 atIndex:3];
        });
        char bb2[32];
        printf("  %-8s %11s\n", "read", bw_s(bytes / t / 1e9, bb2, sizeof bb2));

        t = timed(pCopy, grid, tg, reps, ^(id<MTLComputeCommandEncoder> e) {
            [e setBuffer:A offset:0 atIndex:0];
            [e setBuffer:B offset:0 atIndex:1];
            [e setBytes:&n4 length:4 atIndex:2];
        });
        printf("  %-8s %11s\n", "copy", bw_s(2.0 * bytes / t / 1e9, bb2, sizeof bb2));

        float sc = 1.0000001f;
        t = timed(pTriad, grid, tg, reps, ^(id<MTLComputeCommandEncoder> e) {
            [e setBuffer:A offset:0 atIndex:0];
            [e setBuffer:B offset:0 atIndex:1];
            [e setBuffer:C offset:0 atIndex:2];
            [e setBytes:&n4 length:4 atIndex:3];
            [e setBytes:&sc length:4 atIndex:4];
        });
        printf("  %-8s %11s\n", "triad", bw_s(3.0 * bytes / t / 1e9, bb2, sizeof bb2));

        /* ---------------- 3. cache hierarchy ---------------- */
        printf("\n=== 3. cache hierarchy ===\n");
        printf("  %12s %14s %12s\n", "working set", "read bandwidth", "latency");

        /* one random cycle over 128-byte strides, chased by a single lane */
        size_t maxChase = 128 * 1048576;
        id<MTLBuffer> idx = [gDev newBufferWithLength:maxChase
                                              options:MTLResourceStorageModeShared];
        uint32_t *ix = (uint32_t *)idx.contents;

        for (size_t ws = 16384; ws <= bytes; ws *= 2) {
            uint32_t mask = (uint32_t)(ws / 16) - 1;      /* float4 index mask */
            uint32_t iter = (uint32_t)(64 * 1048576 / 16 / threads);
            if (iter < 8) iter = 8;

            double tb = timed(pReadWs, grid, tg, reps, ^(id<MTLComputeCommandEncoder> e) {
                [e setBuffer:A offset:0 atIndex:0];
                [e setBuffer:sink offset:0 atIndex:1];
                [e setBytes:&mask length:4 atIndex:2];
                [e setBytes:&iter length:4 atIndex:3];
            });
            double bw = (double)threads * iter * 16.0 / tb / 1e9;

            double lat = 0;
            if (ws <= maxChase) {
                size_t stride = 128 / 4;                /* uint32 elements */
                size_t nodes = ws / 128;
                if (nodes >= 2) {
                    uint32_t *perm = malloc(nodes * 4);
                    for (size_t i = 0; i < nodes; i++) perm[i] = (uint32_t)i;
                    for (size_t i = nodes - 1; i > 0; i--) {   /* Sattolo */
                        size_t j = (size_t)(arc4random_uniform((uint32_t)i));
                        uint32_t tmp = perm[i]; perm[i] = perm[j]; perm[j] = tmp;
                    }
                    for (size_t i = 0; i < nodes; i++)
                        ix[perm[i] * stride] = (uint32_t)(perm[(i + 1) % nodes] * stride);
                    free(perm);
                    uint32_t steps = quick ? 100000 : 400000;
                    MTLSize one1 = MTLSizeMake(1, 1, 1);
                    double tl = timed(pChase, one1, one1, reps,
                                      ^(id<MTLComputeCommandEncoder> e) {
                        [e setBuffer:idx offset:0 atIndex:0];
                        [e setBuffer:sink offset:0 atIndex:1];
                        [e setBytes:&steps length:4 atIndex:2];
                    });
                    lat = tl / steps * 1e9;
                }
            }
            char hb[32], bb3[32];
            if (lat > 0) printf("  %12s %14s %9.1f ns\n",
                                hsize(ws, hb, sizeof hb), bw_s(bw, bb3, sizeof bb3), lat);
            else         printf("  %12s %14s %12s\n",
                                hsize(ws, hb, sizeof hb), bw_s(bw, bb3, sizeof bb3), "-");
        }
        printf("  note: the GPU's last-level cache is shared with the CPU on\n"
               "        unified-memory parts, so the DRAM plateau is the SLC floor\n");
    }
    return 0;
}
