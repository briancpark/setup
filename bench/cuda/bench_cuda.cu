/*
 * bench_cuda.cu - GPU counterpart of ../cpu/bench_cpu.c for NVIDIA parts.
 *
 *   1. peak FP throughput   (FMA chains: f64, f32, f16, bf16, plus tensor cores)
 *   2. memory bandwidth     (read / copy / triad over device memory)
 *   3. cache hierarchy      (read bandwidth vs. working set + pointer-chase latency)
 *
 * Build: nvcc -O3 -arch=native bench_cuda.cu -o bench_cuda
 *   older nvcc: -arch=sm_80 (Ampere), sm_90 (Hopper), sm_75 (Turing), ...
 *
 * The same two traps as the Metal version apply and are handled the same way:
 * every accumulator is seeded from the thread id so the compiler cannot hoist
 * the chain into uniform/scalar form, and results are stored unconditionally
 * rather than behind a sentinel compare that the compiler can prove false.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cuda_bf16.h>
#include <mma.h>

#define CHECK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
    fprintf(stderr, "%s:%d %s: %s\n", __FILE__, __LINE__, #x, \
            cudaGetErrorString(e_)); exit(1); } } while (0)

#define NCHAIN 8

/* Explicit per-type FMA.  A bare fma(float,float,float) can resolve to the
 * double overload, which would silently measure f64 rate in the f32 test. */
__device__ __forceinline__ float  fma_t(float a, float b, float c)    { return __fmaf_rn(a, b, c); }
__device__ __forceinline__ double fma_t(double a, double b, double c) { return __fma_rn(a, b, c); }

/* ---------------------------------------------------------- FP kernels */

template <typename T>
__global__ void fma_kernel(T *out, unsigned iters, T m, T b) {
    unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
    T v = (T)((float)tid * 1e-9f);
    T a[NCHAIN];
#pragma unroll
    for (int i = 0; i < NCHAIN; i++) a[i] = (T)(0.1f * (i + 1)) + v;
    for (unsigned it = 0; it < iters; it++) {
#pragma unroll
        for (int i = 0; i < NCHAIN; i++) a[i] = fma_t(m, b, a[i]);
    }
    T s = a[0];
#pragma unroll
    for (int i = 1; i < NCHAIN; i++) s += a[i];
    out[tid] = s;                      /* unconditional: keeps every chain live */
}

/* half2 / bf16x2 are the packed forms: two lanes per instruction. */
__global__ void fma_h2(float *out, unsigned iters, __half2 m, __half2 b) {
    unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
    __half2 v = __float2half2_rn((float)tid * 1e-5f);
    __half2 a[NCHAIN];
#pragma unroll
    for (int i = 0; i < NCHAIN; i++) a[i] = __hadd2(__float2half2_rn(0.1f * (i + 1)), v);
    for (unsigned it = 0; it < iters; it++) {
#pragma unroll
        for (int i = 0; i < NCHAIN; i++) a[i] = __hfma2(m, b, a[i]);
    }
    __half2 s = a[0];
#pragma unroll
    for (int i = 1; i < NCHAIN; i++) s = __hadd2(s, a[i]);
    out[tid] = __low2float(s) + __high2float(s);
}

__global__ void fma_bf2(float *out, unsigned iters, __nv_bfloat162 m, __nv_bfloat162 b) {
#if __CUDA_ARCH__ >= 800
    unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
    __nv_bfloat162 v = __float2bfloat162_rn((float)tid * 1e-5f);
    __nv_bfloat162 a[NCHAIN];
#pragma unroll
    for (int i = 0; i < NCHAIN; i++)
        a[i] = __hadd2(__float2bfloat162_rn(0.1f * (i + 1)), v);
    for (unsigned it = 0; it < iters; it++) {
#pragma unroll
        for (int i = 0; i < NCHAIN; i++) a[i] = __hfma2(m, b, a[i]);
    }
    __nv_bfloat162 s = a[0];
#pragma unroll
    for (int i = 1; i < NCHAIN; i++) s = __hadd2(s, a[i]);
    out[tid] = __low2float(s) + __high2float(s);
#else
    (void)out; (void)iters; (void)m; (void)b;
#endif
}

/* Tensor cores: 16x16x16 f16 inputs with f32 accumulate = 4096 MACs per warp
 * per mma, which is where the headline TFLOP/s numbers come from. */
__global__ void wmma_f16(float *out, unsigned iters) {
#if __CUDA_ARCH__ >= 700
    using namespace nvcuda::wmma;
    fragment<matrix_a, 16, 16, 16, __half, row_major> a;
    fragment<matrix_b, 16, 16, 16, __half, col_major> b;
    fragment<accumulator, 16, 16, 16, float> c0, c1, c2, c3;
    fill_fragment(a, __float2half(1.0f));
    fill_fragment(b, __float2half(1.0001f));
    float seed = (float)(blockIdx.x * blockDim.x + threadIdx.x) * 1e-9f;
    fill_fragment(c0, seed); fill_fragment(c1, seed);
    fill_fragment(c2, seed); fill_fragment(c3, seed);
    for (unsigned i = 0; i < iters; i++) {
        mma_sync(c0, a, b, c0); mma_sync(c1, a, b, c1);
        mma_sync(c2, a, b, c2); mma_sync(c3, a, b, c3);
    }
    float s = c0.x[0] + c1.x[0] + c2.x[0] + c3.x[0];
    out[blockIdx.x * blockDim.x + threadIdx.x] = s;
#else
    (void)out; (void)iters;
#endif
}

/* ------------------------------------------------------- memory kernels */

__global__ void mem_read(const float4 *__restrict__ in, float *out,
                         size_t n4, unsigned reps) {
    size_t tid = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
    size_t gsz = (size_t)gridDim.x * blockDim.x;
    float4 s = make_float4(0, 0, 0, 0);
    for (unsigned r = 0; r < reps; r++)
        for (size_t i = tid; i < n4; i += gsz) {
            float4 v = in[i];
            s.x += v.x; s.y += v.y; s.z += v.z; s.w += v.w;
        }
    if (s.x + s.y + s.z + s.w == 1234.5f) out[tid] = s.x;
}

/* Power-of-two window wrapped with a mask: every lane stays inside the
 * working set, so this measures cache bandwidth and not occupancy. */
__global__ void mem_read_ws(const float4 *__restrict__ in, float *out,
                            unsigned mask, unsigned iters) {
    unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned gsz = gridDim.x * blockDim.x;
    float4 s = make_float4(0, 0, 0, 0);
    unsigned p = tid & mask;
    for (unsigned k = 0; k < iters; k++) {
        float4 v = in[p];
        s.x += v.x; s.y += v.y; s.z += v.z; s.w += v.w;
        p = (p + gsz) & mask;
    }
    if (s.x + s.y + s.z + s.w == 1234.5f) out[tid] = s.x;
}

__global__ void mem_copy(const float4 *__restrict__ in, float4 *__restrict__ dst,
                         size_t n4) {
    size_t tid = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
    size_t gsz = (size_t)gridDim.x * blockDim.x;
    for (size_t i = tid; i < n4; i += gsz) dst[i] = in[i];
}

__global__ void mem_triad(float4 *__restrict__ a, const float4 *__restrict__ b,
                          const float4 *__restrict__ c, float s, size_t n4) {
    size_t tid = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
    size_t gsz = (size_t)gridDim.x * blockDim.x;
    for (size_t i = tid; i < n4; i += gsz) {
        float4 bb = b[i], cc = c[i];
        a[i] = make_float4(fmaf(s, cc.x, bb.x), fmaf(s, cc.y, bb.y),
                           fmaf(s, cc.z, bb.z), fmaf(s, cc.w, bb.w));
    }
}

/* Single-lane dependent-load chase: exposes L1 / L2 / DRAM latency. */
__global__ void chase(const unsigned *idx, unsigned *out, unsigned steps) {
    unsigned p = 0;
    for (unsigned i = 0; i < steps; i++) p = idx[p];
    out[0] = p;
}

/* ------------------------------------------------------------------ util */

static const char *flops_s(double gflops, char *b, size_t n) {
    if (gflops <= 0)         snprintf(b, n, "%s", "n/a");
    else if (gflops >= 1000) snprintf(b, n, "%.2f TFLOP/s", gflops / 1000.0);
    else                     snprintf(b, n, "%.1f GFLOP/s", gflops);
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

/* Best-of-N GPU time in seconds, measured with CUDA events. */
template <typename F>
static double timed(int reps, F launch) {
    cudaEvent_t t0, t1;
    CHECK(cudaEventCreate(&t0));
    CHECK(cudaEventCreate(&t1));
    double best = INFINITY;
    for (int r = 0; r < reps; r++) {
        CHECK(cudaEventRecord(t0));
        launch();
        CHECK(cudaEventRecord(t1));
        CHECK(cudaEventSynchronize(t1));
        CHECK(cudaGetLastError());
        float ms = 0;
        CHECK(cudaEventElapsedTime(&ms, t0, t1));
        if (ms > 0 && ms / 1e3 < best) best = ms / 1e3;
    }
    cudaEventDestroy(t0); cudaEventDestroy(t1);
    return best;
}

int main(int argc, char **argv) {
    int quick = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-q")) quick = 1;
        else { fprintf(stderr, "usage: %s [-q]\n", argv[0]); return 2; }
    }

    cudaDeviceProp p;
    CHECK(cudaGetDeviceProperties(&p, 0));
    printf("=== GPU (CUDA) ===\n");
    printf("  %s, sm_%d%d, %d SMs @ %.2f GHz\n", p.name, p.major, p.minor,
           p.multiProcessorCount, p.clockRate / 1e6);
    printf("  %.1f GiB global, %.1f MiB L2, %d KiB shared/SM, %d-bit @ %.0f MHz\n",
           p.totalGlobalMem / 1073741824.0, p.l2CacheSize / 1048576.0,
           (int)(p.sharedMemPerMultiprocessor / 1024), p.memoryBusWidth,
           p.memoryClockRate / 1e3);
    /* GDDR/HBM are double data rate */
    double peak_bw = 2.0 * p.memoryClockRate * 1e3 * (p.memoryBusWidth / 8) / 1e9;
    printf("  theoretical DRAM bandwidth: %.0f GB/s\n", peak_bw);

    int threads = 256;
    int blocks  = p.multiProcessorCount * 32;
    size_t nthreads = (size_t)threads * blocks;
    int reps = quick ? 2 : 4;
    printf("  launching %d blocks x %d threads\n", blocks, threads);

    float *sink;
    CHECK(cudaMalloc(&sink, nthreads * sizeof(double)));

    /* ---------------- 1. peak FP ---------------- */
    printf("\n=== 1. peak FP throughput (FMA chains, no memory traffic) ===\n");
    unsigned iters = quick ? 20000 : 80000;
    char fb[32];

    double t = timed(reps, [&] {
        fma_kernel<double><<<blocks, threads>>>((double *)sink, iters, 1e-9, 1.0000001);
    });
    double flops = (double)nthreads * iters * NCHAIN * 2.0;
    printf("  %-14s %14s\n", "f64", flops_s(flops / t / 1e9, fb, sizeof fb));

    t = timed(reps, [&] {
        fma_kernel<float><<<blocks, threads>>>((float *)sink, iters, 1e-9f, 1.0000001f);
    });
    printf("  %-14s %14s\n", "f32", flops_s(flops / t / 1e9, fb, sizeof fb));

    t = timed(reps, [&] {
        fma_h2<<<blocks, threads>>>((float *)sink, iters,
                                    __float2half2_rn(1e-4f), __float2half2_rn(1.0001f));
    });
    printf("  %-14s %14s\n", "f16 (half2)",
           flops_s(2.0 * flops / t / 1e9, fb, sizeof fb));

    if (p.major >= 8) {
        t = timed(reps, [&] {
            fma_bf2<<<blocks, threads>>>((float *)sink, iters,
                                         __float2bfloat162_rn(1e-4f),
                                         __float2bfloat162_rn(1.0001f));
        });
        printf("  %-14s %14s\n", "bf16 (bf16x2)",
               flops_s(2.0 * flops / t / 1e9, fb, sizeof fb));
    } else {
        printf("  %-14s %14s   (needs sm_80+)\n", "bf16", "n/a");
    }

    if (p.major >= 7) {                  /* tensor cores from Volta on */
        unsigned mi = iters / 8;
        t = timed(reps, [&] { wmma_f16<<<blocks, threads>>>((float *)sink, mi); });
        /* 4 fragments x 16x16x16 MACs x 2 flops, once per warp */
        double warps = (double)nthreads / p.warpSize;
        double tf = warps * mi * 4.0 * 16 * 16 * 16 * 2.0;
        printf("  %-14s %14s  (wmma 16x16x16, f32 accumulate)\n", "f16 tensor",
               flops_s(tf / t / 1e9, fb, sizeof fb));
    }

    /* ---------------- 2. bandwidth ---------------- */
    size_t bytes = (size_t)(quick ? 256 : 512) * 1048576;
    size_t n4 = bytes / 16;
    float4 *A, *B, *C;
    CHECK(cudaMalloc(&A, bytes));
    CHECK(cudaMalloc(&B, bytes));
    CHECK(cudaMalloc(&C, bytes));
    CHECK(cudaMemset(A, 0, bytes));
    CHECK(cudaMemset(B, 0, bytes));
    CHECK(cudaMemset(C, 0, bytes));

    printf("\n=== 2. memory bandwidth (%zu MiB buffers) ===\n", bytes >> 20);
    char bb[32];

    t = timed(reps, [&] { mem_read<<<blocks, threads>>>(A, sink, n4, 1); });
    printf("  %-8s %11s  (%.0f%% of theoretical)\n", "read",
           bw_s(bytes / t / 1e9, bb, sizeof bb), 100.0 * (bytes / t / 1e9) / peak_bw);

    t = timed(reps, [&] { mem_copy<<<blocks, threads>>>(A, B, n4); });
    printf("  %-8s %11s\n", "copy", bw_s(2.0 * bytes / t / 1e9, bb, sizeof bb));

    t = timed(reps, [&] { mem_triad<<<blocks, threads>>>(A, B, C, 1.0000001f, n4); });
    printf("  %-8s %11s\n", "triad", bw_s(3.0 * bytes / t / 1e9, bb, sizeof bb));

    /* ---------------- 3. cache hierarchy ---------------- */
    printf("\n=== 3. cache hierarchy ===\n");
    printf("  %12s %14s %12s\n", "working set", "read bandwidth", "latency");

    size_t maxChase = 128 * 1048576;
    unsigned *dIdx, *hIdx = (unsigned *)malloc(maxChase);
    CHECK(cudaMalloc(&dIdx, maxChase));

    for (size_t ws = 16384; ws <= bytes; ws *= 2) {
        unsigned mask = (unsigned)(ws / 16) - 1;
        unsigned iter = (unsigned)(256 * 1048576 / 16 / nthreads);
        if (iter < 8) iter = 8;

        double tb = timed(reps, [&] {
            mem_read_ws<<<blocks, threads>>>(A, sink, mask, iter);
        });
        double bw = (double)nthreads * iter * 16.0 / tb / 1e9;

        double lat = 0;
        if (ws <= maxChase) {
            size_t stride = 128 / 4, nodes = ws / 128;
            if (nodes >= 2) {
                unsigned *perm = (unsigned *)malloc(nodes * 4);
                for (size_t i = 0; i < nodes; i++) perm[i] = (unsigned)i;
                for (size_t i = nodes - 1; i > 0; i--) {      /* Sattolo */
                    size_t j = (size_t)(rand() % (int)i);
                    unsigned tmp = perm[i]; perm[i] = perm[j]; perm[j] = tmp;
                }
                for (size_t i = 0; i < nodes; i++)
                    hIdx[perm[i] * stride] = (unsigned)(perm[(i + 1) % nodes] * stride);
                free(perm);
                CHECK(cudaMemcpy(dIdx, hIdx, ws, cudaMemcpyHostToDevice));
                unsigned steps = quick ? 100000 : 400000;
                double tl = timed(reps, [&] {
                    chase<<<1, 1>>>(dIdx, (unsigned *)sink, steps);
                });
                lat = tl / steps * 1e9;
            }
        }
        char hb[32], b2[32];
        if (lat > 0) printf("  %12s %14s %9.1f ns\n", hsize(ws, hb, sizeof hb),
                            bw_s(bw, b2, sizeof b2), lat);
        else         printf("  %12s %14s %12s\n", hsize(ws, hb, sizeof hb),
                            bw_s(bw, b2, sizeof b2), "-");
    }
    printf("  note: the first step is L1/texture cache, the plateau at ~%.0f MiB\n"
           "        is L2, and the floor is DRAM\n", p.l2CacheSize / 1048576.0);

    free(hIdx);
    cudaFree(A); cudaFree(B); cudaFree(C); cudaFree(sink); cudaFree(dIdx);
    return 0;
}
