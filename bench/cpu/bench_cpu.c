/*
 * bench.c - tiny CPU/memory microbenchmark suite.
 *
 *   1. peak FP throughput   (dependency-free FMA chains, f64 + f32, 1 core + all cores)
 *   2. memory bandwidth     (STREAM-style read / copy / triad, scaled over thread count)
 *   3. cache hierarchy      (latency vs. working-set via pointer chase, plus read
 *                            bandwidth vs. working-set; levels inferred from the curve)
 *
 * Build:  cc -O3 -march=native -ffp-contract=fast bench.c -o bench -lm -lpthread
 *   (Apple silicon: -mcpu=apple-m1 works too; -march=native is fine on clang >= 15)
 *
 * Usage:  ./bench [-t threads] [-q]      -q = quick mode (fewer/shorter samples)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sched.h>

#if defined(__aarch64__) || defined(__arm64__)
#  define CPU_RELAX() __asm__ __volatile__("yield" ::: "memory")
#elif defined(__x86_64__) || defined(__i386__)
#  define CPU_RELAX() __builtin_ia32_pause()
#else
#  define CPU_RELAX() ((void)0)
#endif

#ifdef __APPLE__
#include <sys/sysctl.h>
#include <pthread/qos.h>
#else
#include <unistd.h>
#if defined(__linux__)
#include <sys/auxv.h>
#endif
#endif

/* ------------------------------------------------------------------ util */

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + 1e-9 * (double)ts.tv_nsec;
}

/* Report in TFLOP/s once the number earns it. */
static const char *flops_s(double gflops, char *b, size_t n) {
    if (gflops <= 0)         snprintf(b, n, "%s", "n/a");
    else if (gflops >= 1000) snprintf(b, n, "%.2f TFLOP/s", gflops / 1000.0);
    else                     snprintf(b, n, "%.1f GFLOP/s", gflops);
    return b;
}

/* compact form for table cells */
static const char *flops_c(double gflops, char *b, size_t n) {
    if (gflops <= 0)         snprintf(b, n, "%s", "n/a");
    else if (gflops >= 1000) snprintf(b, n, "%.2f T", gflops / 1000.0);
    else                     snprintf(b, n, "%.1f G", gflops);
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

static void be_fast(void) {
#ifdef __APPLE__
    /* ask for performance cores instead of the efficiency cluster */
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
}

static void *xalloc(size_t bytes) {
    void *p = NULL;
    if (posix_memalign(&p, 4096, bytes) != 0 || !p) {
        fprintf(stderr, "alloc of %zu bytes failed\n", bytes);
        exit(1);
    }
    return p;
}

/* --------------------------------------------------------- vector config */

#if defined(__AVX512F__)
#  define VBYTES 64
#  define NACC   8
#elif defined(__AVX__)
#  define VBYTES 32
#  define NACC   10
#else                       /* NEON / SSE / generic */
#  define VBYTES 16
#  define NACC   16
#endif

#define NDBL (VBYTES / 8)
#define NFLT (VBYTES / 4)

typedef double vd __attribute__((vector_size(VBYTES)));
typedef float  vf __attribute__((vector_size(VBYTES)));

#if defined(__clang__) && __has_builtin(__builtin_elementwise_fma)
#  define VFMA(a, b, c) __builtin_elementwise_fma((a), (b), (c))
#else
#  define VFMA(a, b, c) ((a) * (b) + (c))   /* relies on -ffp-contract=fast */
#endif

#if defined(__clang__)
#  define FULL_UNROLL _Pragma("clang loop unroll(full)")
#elif defined(__GNUC__)
#  define FULL_UNROLL _Pragma("GCC unroll 16")
#else
#  define FULL_UNROLL
#endif

/* ------------------------------------------------------------ FP kernels */
/*
 * NACC independent FMA chains keep every FP pipe busy: the machine needs
 * (issue width x FMA latency) ops in flight, and chain i never depends on
 * chain j.  The accumulate form acc += m*a matters: writing the result back
 * into the addend register is a single fmla/vfmadd231, whereas acc = acc*m+a
 * costs an extra register move per op and reads ~2x low.  m*a is ~1e-9 so the
 * accumulators drift slowly and stay normal (no denormal/inf penalties).
 *
 * One kernel is generated per ISA with a function-level target attribute, so
 * a single binary carries SSE2/AVX/AVX2/AVX-512 (or NEON/SME) and picks at
 * run time.  Each kernel reports the FLOPs it actually issued, which lets the
 * SME outer-product kernel (N*N MACs per instruction) share the same driver.
 */

typedef double (*fp_fn)(long iters, double *flops);

#define FPOP_1(m, a, acc) VFMA((m), (a), (acc))     /* one fused op  */
#define FPOP_0(m, a, acc) ((acc) * (m) + (a))       /* mul + add     */
#define FPOP_X(F, m, a, acc) FPOP_##F(m, a, acc)
#define FPOP(F, m, a, acc) FPOP_X(F, m, a, acc)

#define DEF_FP_ISA(SUF, TGT, VB, NA, FMA)                                        \
typedef double vd_##SUF __attribute__((vector_size(VB)));                        \
typedef float  vf_##SUF __attribute__((vector_size(VB)));                        \
TGT static double fp64_##SUF(long iters, double *flops) {                        \
    enum { L = (VB) / 8 };                                                       \
    vd_##SUF acc[NA], m, a;                                                      \
    for (int i = 0; i < (NA); i++)                                               \
        for (int j = 0; j < L; j++) ((double *)&acc[i])[j] = 0.1 * (i + 1);      \
    for (int j = 0; j < L; j++) {                                                \
        ((double *)&m)[j] = 1e-9; ((double *)&a)[j] = 1.0000001;                 \
    }                                                                            \
    for (long it = 0; it < iters; it++) {                                        \
        FULL_UNROLL                                                              \
        for (int i = 0; i < (NA); i++) acc[i] = FPOP(FMA, m, a, acc[i]);         \
    }                                                                            \
    *flops = (double)iters * (NA) * L * 2.0;                                     \
    double s = 0;                                                                \
    for (int i = 0; i < (NA); i++)                                               \
        for (int j = 0; j < L; j++) s += ((double *)&acc[i])[j];                 \
    return s;                                                                    \
}                                                                                \
TGT static double fp32_##SUF(long iters, double *flops) {                        \
    enum { L = (VB) / 4 };                                                       \
    vf_##SUF acc[NA], m, a;                                                      \
    for (int i = 0; i < (NA); i++)                                               \
        for (int j = 0; j < L; j++) ((float *)&acc[i])[j] = 0.1f * (i + 1);      \
    for (int j = 0; j < L; j++) {                                                \
        ((float *)&m)[j] = 1e-9f; ((float *)&a)[j] = 1.0000001f;                 \
    }                                                                            \
    for (long it = 0; it < iters; it++) {                                        \
        FULL_UNROLL                                                              \
        for (int i = 0; i < (NA); i++) acc[i] = FPOP(FMA, m, a, acc[i]);         \
    }                                                                            \
    *flops = (double)iters * (NA) * L * 2.0;                                     \
    double s = 0;                                                                \
    for (int i = 0; i < (NA); i++)                                               \
        for (int j = 0; j < L; j++) s += ((float *)&acc[i])[j];                  \
    return s;                                                                    \
}

#if defined(__x86_64__) || defined(__i386__)
/* 16 ymm / 32 zmm architectural registers bound the usable chain count. */
DEF_FP_ISA(sse2,   __attribute__((target("sse2"))),     16, 10, 0)
DEF_FP_ISA(avx,    __attribute__((target("avx"))),      32, 10, 0)
DEF_FP_ISA(avx2,   __attribute__((target("avx2,fma"))), 32, 10, 1)
DEF_FP_ISA(avx512, __attribute__((target("avx512f"))),  64, 16, 1)

static int has_sse2(void)   { return __builtin_cpu_supports("sse2"); }
static int has_avx(void)    { return __builtin_cpu_supports("avx"); }
static int has_avx2(void)   { return __builtin_cpu_supports("avx2") &&
                                     __builtin_cpu_supports("fma"); }
static int has_avx512(void) { return __builtin_cpu_supports("avx512f"); }

#elif defined(__aarch64__) || defined(__arm64__)
DEF_FP_ISA(neon, , 16, 16, 1)
static int has_neon(void) { return 1; }        /* mandatory in ARMv8 */
#else
DEF_FP_ISA(scalar, , 16, 8, 1)
static int has_scalar(void) { return 1; }
#endif


/* --------------------------------------------------- half / bfloat16 ---- */
/*
 * f16 is a normal FMA on parts with FEAT_FP16 / AVX512-FP16, so it reuses the
 * same chain structure at twice the lane count.  bf16 is not: nobody ships a
 * plain bf16 multiply-add.  The instructions are dot products / matrix ops
 * that accumulate into f32 (BFMMLA, VDPBF16PS), so those kernels measure the
 * bf16 *matrix* path, which is the number vendors quote.
 */

#define DEF_F16_ISA(SUF, TGT, VB, NA)                                            \
typedef _Float16 vh_##SUF __attribute__((vector_size(VB)));                      \
TGT static double f16_##SUF(long iters, double *flops) {                         \
    enum { L = (VB) / 2 };                                                       \
    vh_##SUF acc[NA], m, a;                                                      \
    for (int i = 0; i < (NA); i++)                                               \
        for (int j = 0; j < L; j++) ((_Float16 *)&acc[i])[j] = (_Float16)(0.1 * (i + 1)); \
    for (int j = 0; j < L; j++) {                                                \
        ((_Float16 *)&m)[j] = (_Float16)0.0001; ((_Float16 *)&a)[j] = (_Float16)1.0001; \
    }                                                                            \
    for (long it = 0; it < iters; it++) {                                        \
        FULL_UNROLL                                                              \
        for (int i = 0; i < (NA); i++) acc[i] = VFMA(m, a, acc[i]);              \
    }                                                                            \
    *flops = (double)iters * (NA) * L * 2.0;                                     \
    double s = 0;                                                                \
    for (int i = 0; i < (NA); i++)                                               \
        for (int j = 0; j < L; j++) s += (double)((_Float16 *)&acc[i])[j];        \
    return s;                                                                    \
}

#if defined(__aarch64__) || defined(__arm64__)
DEF_F16_ISA(neon, __attribute__((target("+fp16"))), 16, 16)

static int arm_feat(const char *name) {
#ifdef __APPLE__
    char key[128];
    snprintf(key, sizeof key, "hw.optional.arm.%s", name);
    uint64_t v = 0; size_t sz = sizeof v;
    return sysctlbyname(key, &v, &sz, NULL, 0) == 0 && v;
#elif defined(__linux__) && defined(AT_HWCAP)
    unsigned long h = getauxval(AT_HWCAP);
    if (!strcmp(name, "FEAT_FP16")) return (h & (1UL << 9)) != 0;   /* HWCAP_FPHP */
    if (!strcmp(name, "FEAT_BF16")) return (getauxval(AT_HWCAP2) & (1UL << 14)) != 0;
    return 0;
#else
    (void)name; return 0;
#endif
}
static int has_fp16(void) { return arm_feat("FEAT_FP16"); }
static int has_bf16(void) { return arm_feat("FEAT_BF16"); }

/* BFMMLA: a 2x4 by 4x2 bf16 matrix product accumulated into a 2x2 f32 tile,
 * i.e. 16 MACs (32 FLOPs) per instruction. */
#if __has_include(<arm_neon.h>) && !defined(BENCH_NO_BF16)
#define HAVE_ARM_BF16 1
#include <arm_neon.h>
__attribute__((target("+bf16")))
static double bf16_neon(long iters, double *flops) {
    bfloat16x8_t a = vreinterpretq_bf16_u16(vdupq_n_u16(0x3f80)); /* 1.0bf16 */
    float32x4_t c0 = vdupq_n_f32(0), c1 = vdupq_n_f32(0),
                c2 = vdupq_n_f32(0), c3 = vdupq_n_f32(0),
                c4 = vdupq_n_f32(0), c5 = vdupq_n_f32(0),
                c6 = vdupq_n_f32(0), c7 = vdupq_n_f32(0);
    for (long i = 0; i < iters; i++) {
        c0 = vbfmmlaq_f32(c0, a, a); c1 = vbfmmlaq_f32(c1, a, a);
        c2 = vbfmmlaq_f32(c2, a, a); c3 = vbfmmlaq_f32(c3, a, a);
        c4 = vbfmmlaq_f32(c4, a, a); c5 = vbfmmlaq_f32(c5, a, a);
        c6 = vbfmmlaq_f32(c6, a, a); c7 = vbfmmlaq_f32(c7, a, a);
    }
    *flops = (double)iters * 8.0 * 32.0;
    return vaddvq_f32(c0) + vaddvq_f32(c1) + vaddvq_f32(c2) + vaddvq_f32(c3) +
           vaddvq_f32(c4) + vaddvq_f32(c5) + vaddvq_f32(c6) + vaddvq_f32(c7);
}
#endif

#elif defined(__x86_64__) || defined(__i386__)
DEF_F16_ISA(avx512fp16, __attribute__((target("avx512fp16"))), 64, 16)

#if __has_include(<immintrin.h>) && !defined(BENCH_NO_BF16)
#define HAVE_X86_BF16 1
#include <immintrin.h>
/* VDPBF16PS: 32 bf16 pairs -> 16 f32 lanes, 2 MACs each = 64 FLOPs. */
__attribute__((target("avx512bf16,avx512f")))
static double bf16_avx512(long iters, double *flops) {
    __m512bh a = (__m512bh)_mm512_set1_epi16(0x3f80);
    __m512 c0 = _mm512_setzero_ps(), c1 = _mm512_setzero_ps(),
           c2 = _mm512_setzero_ps(), c3 = _mm512_setzero_ps(),
           c4 = _mm512_setzero_ps(), c5 = _mm512_setzero_ps(),
           c6 = _mm512_setzero_ps(), c7 = _mm512_setzero_ps();
    for (long i = 0; i < iters; i++) {
        c0 = _mm512_dpbf16_ps(c0, a, a); c1 = _mm512_dpbf16_ps(c1, a, a);
        c2 = _mm512_dpbf16_ps(c2, a, a); c3 = _mm512_dpbf16_ps(c3, a, a);
        c4 = _mm512_dpbf16_ps(c4, a, a); c5 = _mm512_dpbf16_ps(c5, a, a);
        c6 = _mm512_dpbf16_ps(c6, a, a); c7 = _mm512_dpbf16_ps(c7, a, a);
    }
    *flops = (double)iters * 8.0 * 64.0;
    __m512 s = ((c0+c1)+(c2+c3)) + ((c4+c5)+(c6+c7));
    return _mm512_reduce_add_ps(s);
}
static int has_avx512bf16(void) { return __builtin_cpu_supports("avx512bf16"); }
#endif
static int has_avx512fp16(void) {
#if defined(__clang__) && __clang_major__ >= 14
    return __builtin_cpu_supports("avx512fp16");
#else
    return 0;
#endif
}
#endif

/* ------------------------------------------------------------------- SME */
/*
 * Scalable Matrix Extension.  Two kernels, because they measure different
 * engines: streaming-SVE FMLA is the vector unit at streaming vector length
 * (SVL), while FMOPA is the outer-product engine - one instruction does an
 * SVLxSVL element MAC into a ZA tile, which is where the real peak lives.
 * Compiled behind a function-level target attribute so the binary still runs
 * on non-SME parts; guarded at run time by FEAT_SME / HWCAP2_SME.
 */
#if (defined(__aarch64__) || defined(__arm64__)) && defined(__clang__) && \
    __has_include(<arm_sme.h>) && !defined(BENCH_NO_SME)
#define HAVE_SME 1
#include <arm_sme.h>

#define SME_ATTR __attribute__((target("+sme"))) __arm_locally_streaming

SME_ATTR static double sme_fmla_f32(long iters, double *flops) {
    svbool_t pg = svptrue_b32();
    svfloat32_t m = svdup_f32(1e-9f), b = svdup_f32(1.0000001f);
    svfloat32_t a0 = svdup_f32(0.1f), a1 = svdup_f32(0.2f),
                a2 = svdup_f32(0.3f), a3 = svdup_f32(0.4f),
                a4 = svdup_f32(0.5f), a5 = svdup_f32(0.6f),
                a6 = svdup_f32(0.7f), a7 = svdup_f32(0.8f);
    for (long i = 0; i < iters; i++) {
        a0 = svmla_f32_x(pg, a0, m, b); a1 = svmla_f32_x(pg, a1, m, b);
        a2 = svmla_f32_x(pg, a2, m, b); a3 = svmla_f32_x(pg, a3, m, b);
        a4 = svmla_f32_x(pg, a4, m, b); a5 = svmla_f32_x(pg, a5, m, b);
        a6 = svmla_f32_x(pg, a6, m, b); a7 = svmla_f32_x(pg, a7, m, b);
    }
    *flops = (double)iters * 8.0 * (double)svcntw() * 2.0;
    return svaddv_f32(pg, a0) + svaddv_f32(pg, a1) + svaddv_f32(pg, a2) +
           svaddv_f32(pg, a3) + svaddv_f32(pg, a4) + svaddv_f32(pg, a5) +
           svaddv_f32(pg, a6) + svaddv_f32(pg, a7);
}

SME_ATTR __arm_new("za") static double sme_fmopa_f32(long iters, double *flops) {
    svbool_t pg = svptrue_b32();
    svfloat32_t a = svdup_f32(1e-9f), b = svdup_f32(1.0000001f);
    uint64_t n = svcntw();                       /* SVL / 32 bits */
    svzero_za();
    for (long i = 0; i < iters; i++) {           /* 4 ZA tiles = 4 chains */
        svmopa_za32_f32_m(0, pg, pg, a, b);
        svmopa_za32_f32_m(1, pg, pg, a, b);
        svmopa_za32_f32_m(2, pg, pg, a, b);
        svmopa_za32_f32_m(3, pg, pg, a, b);
    }
    *flops = (double)iters * 4.0 * (double)(n * n) * 2.0;
    float out[64] = {0};                         /* SVL <= 2048b => <= 64 f32 */
    svst1_hor_za32(0, 0, pg, out);
    double s = 0;
    for (uint64_t i = 0; i < n && i < 64; i++) s += out[i];
    return s;
}

/* f16/bf16 outer products accumulate into an f32 ZA tile: each of the n*n
 * accumulators takes a 2-element dot product, so 4*n*n FLOPs per instruction. */
SME_ATTR __arm_new("za") static double sme_fmopa_f16(long iters, double *flops) {
    svbool_t pg = svptrue_b16();
    svfloat16_t a = svdup_f16((__fp16)1.0), b = svdup_f16((__fp16)1.0001);
    uint64_t n = svcntw();
    svzero_za();
    for (long i = 0; i < iters; i++) {
        svmopa_za32_f16_m(0, pg, pg, a, b);
        svmopa_za32_f16_m(1, pg, pg, a, b);
        svmopa_za32_f16_m(2, pg, pg, a, b);
        svmopa_za32_f16_m(3, pg, pg, a, b);
    }
    *flops = (double)iters * 4.0 * (double)(n * n) * 4.0;
    float out[64] = {0};
    svst1_hor_za32(0, 0, svptrue_b32(), out);
    double s = 0;
    for (uint64_t i = 0; i < n && i < 64; i++) s += out[i];
    return s;
}

SME_ATTR __arm_new("za") static double sme_fmopa_bf16(long iters, double *flops) {
    svbool_t pg = svptrue_b16();
    svbfloat16_t a = svreinterpret_bf16_u16(svdup_u16(0x3f80));
    uint64_t n = svcntw();
    svzero_za();
    for (long i = 0; i < iters; i++) {
        svmopa_za32_bf16_m(0, pg, pg, a, a);
        svmopa_za32_bf16_m(1, pg, pg, a, a);
        svmopa_za32_bf16_m(2, pg, pg, a, a);
        svmopa_za32_bf16_m(3, pg, pg, a, a);
    }
    *flops = (double)iters * 4.0 * (double)(n * n) * 4.0;
    float out[64] = {0};
    svst1_hor_za32(0, 0, svptrue_b32(), out);
    double s = 0;
    for (uint64_t i = 0; i < n && i < 64; i++) s += out[i];
    return s;
}

static int has_sme(void) {
#ifdef __APPLE__
    uint64_t v = 0; size_t sz = sizeof v;
    return sysctlbyname("hw.optional.arm.FEAT_SME", &v, &sz, NULL, 0) == 0 && v;
#elif defined(__linux__) && defined(AT_HWCAP2)
    return (getauxval(AT_HWCAP2) & (1UL << 23)) != 0;   /* HWCAP2_SME */
#else
    return 0;
#endif
}
#endif /* HAVE_SME */

/* ------------------------------------------------------------- ISA table */

typedef struct {
    const char *name;
    const char *note;
    fp_fn       f64, f32, f16, bf16;
    int       (*avail)(void);
} isa_t;

static const isa_t ISAS[] = {
#if defined(__x86_64__) || defined(__i386__)
    { "sse2",       "128b, mul+add",    fp64_sse2,   fp32_sse2,   NULL, NULL, has_sse2   },
    { "avx",        "256b, mul+add",    fp64_avx,    fp32_avx,    NULL, NULL, has_avx    },
    { "avx2+fma",   "256b, FMA",        fp64_avx2,   fp32_avx2,   NULL, NULL, has_avx2   },
    { "avx512f",    "512b, FMA",        fp64_avx512, fp32_avx512, NULL, NULL, has_avx512 },
    { "avx512fp16", "512b, FMA",        NULL, NULL, f16_avx512fp16, NULL, has_avx512fp16 },
#ifdef HAVE_X86_BF16
    { "avx512bf16", "VDPBF16PS",        NULL, NULL, NULL, bf16_avx512, has_avx512bf16 },
#endif
#elif defined(__aarch64__) || defined(__arm64__)
    { "neon",       "128b, FMA",        fp64_neon, fp32_neon, NULL, NULL, has_neon },
    { "neon+fp16",  "128b, FMA",        NULL, NULL, f16_neon,  NULL, has_fp16 },
#ifdef HAVE_ARM_BF16
    { "neon+bf16",  "BFMMLA",           NULL, NULL, NULL, bf16_neon, has_bf16 },
#endif
#ifdef HAVE_SME
    { "sme-fmla",   "streaming SVE",    NULL, sme_fmla_f32,  NULL, NULL, has_sme },
    { "sme-fmopa",  "ZA outer product", NULL, sme_fmopa_f32, sme_fmopa_f16,
                                                            sme_fmopa_bf16, has_sme },
#endif
#else
    { "scalar",     "portable",         fp64_scalar, fp32_scalar, NULL, NULL, has_scalar },
#endif
};
#define NISA ((int)(sizeof ISAS / sizeof ISAS[0]))

/* -------------------------------------------------------------- barrier */
/*
 * macOS has no pthread_barrier_t.  This one spins: a condvar wakeup costs tens
 * of microseconds, which is the same order as a single bandwidth kernel, and
 * that skew shows up as wild thread-scaling numbers.  Safe to spin because the
 * benchmark never runs more threads than cores.
 */

typedef struct {
    _Atomic int count;
    _Atomic int gen;
    int n;
} barrier_t;

static void barrier_init(barrier_t *b, int n) {
    atomic_store(&b->count, 0);
    atomic_store(&b->gen, 0);
    b->n = n;
}

static void barrier_wait(barrier_t *b) {
    int g = atomic_load_explicit(&b->gen, memory_order_acquire);
    if (atomic_fetch_add(&b->count, 1) == b->n - 1) {
        atomic_store(&b->count, 0);
        atomic_fetch_add_explicit(&b->gen, 1, memory_order_release);
        return;
    }
    for (long spins = 0; atomic_load_explicit(&b->gen, memory_order_acquire) == g; spins++) {
        if (spins < 4096) CPU_RELAX();
        else sched_yield();
    }
}

/* ------------------------------------------------------- memory kernels */

/*
 * Eight independent add chains.  With four, fadd latency (~3 cycles) caps the
 * kernel around 60 GB/s on this class of core and you measure the FPU, not
 * the memory system.
 */
static double read_sum(const double *p, size_t n) {
    const vd *v = (const vd *)p;
    size_t nv = n / NDBL;
    vd s0 = {0}, s1 = {0}, s2 = {0}, s3 = {0}, s4 = {0}, s5 = {0}, s6 = {0}, s7 = {0};
    size_t i = 0;
    for (; i + 8 <= nv; i += 8) {
        s0 += v[i];   s1 += v[i+1]; s2 += v[i+2]; s3 += v[i+3];
        s4 += v[i+4]; s5 += v[i+5]; s6 += v[i+6]; s7 += v[i+7];
    }
    s0 += s1; s2 += s3; s4 += s5; s6 += s7; s0 += s2; s4 += s6; s0 += s4;
    double r = 0;
    for (int j = 0; j < NDBL; j++) r += ((double *)&s0)[j];
    for (size_t k = i * NDBL; k < n; k++) r += p[k];
    return r;
}

static void copy_kern(double *restrict a, const double *restrict b, size_t n) {
    vd *va = (vd *)a; const vd *vb = (const vd *)b;
    size_t nv = n / NDBL;
    for (size_t i = 0; i < nv; i++) va[i] = vb[i];
}

static void triad_kern(double *restrict a, const double *restrict b,
                       const double *restrict c, double s, size_t n) {
    vd *va = (vd *)a; const vd *vb = (const vd *)b; const vd *vc = (const vd *)c;
    vd vs;
    for (int j = 0; j < NDBL; j++) ((double *)&vs)[j] = s;
    size_t nv = n / NDBL;
    for (size_t i = 0; i < nv; i++) va[i] = VFMA(vc[i], vs, vb[i]);
}

/* ------------------------------------------------------- worker plumbing */

enum { JOB_FP, JOB_READ, JOB_COPY, JOB_TRIAD };

typedef struct {
    int       tid, nthreads;
    int       job;
    fp_fn     fn;           /* FP job kernel */
    double    flops;        /* FLOPs it reported */
    long      iters;        /* FP jobs */
    size_t    n;            /* elements per thread (memory jobs) */
    int       reps;
    double   *a, *b, *c;    /* this thread's slices */
    barrier_t *bar;
    double    sink;
} work_t;

static void *worker(void *arg) {
    work_t *w = (work_t *)arg;
    be_fast();

    if (w->job == JOB_FP) {
        barrier_wait(w->bar);
        w->sink = w->fn(w->iters, &w->flops);
        barrier_wait(w->bar);
        return NULL;
    }

    for (int r = 0; r < w->reps; r++) {
        barrier_wait(w->bar);
        switch (w->job) {
            case JOB_READ:  w->sink += read_sum(w->a, w->n);                  break;
            case JOB_COPY:  copy_kern(w->a, w->b, w->n);                      break;
            case JOB_TRIAD: triad_kern(w->a, w->b, w->c, 1.0000001, w->n);    break;
        }
        barrier_wait(w->bar);
    }
    return NULL;
}

/*
 * Master participates as thread 0 so the timed region contains exactly one
 * kernel invocation per thread with no thread-create overhead inside it.
 */
static double run_parallel(work_t *w, pthread_t *th, int nthreads,
                           barrier_t *bar, int reps) {
    for (int i = 1; i < nthreads; i++) pthread_create(&th[i], NULL, worker, &w[i]);

    double best = 1e30;
    for (int r = 0; r < reps; r++) {
        barrier_wait(bar);
        double t0 = now_s();
        switch (w[0].job) {
            case JOB_FP:    w[0].sink = w[0].fn(w[0].iters, &w[0].flops); break;
            case JOB_READ:  w[0].sink += read_sum(w[0].a, w[0].n); break;
            case JOB_COPY:  copy_kern(w[0].a, w[0].b, w[0].n); break;
            case JOB_TRIAD: triad_kern(w[0].a, w[0].b, w[0].c, 1.0000001, w[0].n); break;
        }
        barrier_wait(bar);
        double dt = now_s() - t0;
        if (dt < best) best = dt;
    }
    for (int i = 1; i < nthreads; i++) pthread_join(th[i], NULL);
    return best;
}

/* ------------------------------------------------------------- FP driver */

static double fp_gflops(fp_fn fn, int nthreads, long iters, int reps) {
    if (!fn) return 0.0;
    barrier_t bar; barrier_init(&bar, nthreads);
    work_t   *w  = calloc(nthreads, sizeof *w);
    pthread_t *th = calloc(nthreads, sizeof *th);
    for (int i = 0; i < nthreads; i++) {
        w[i] = (work_t){ .tid = i, .nthreads = nthreads, .job = JOB_FP, .fn = fn,
                         .iters = iters, .reps = reps, .bar = &bar };
    }

    /* FP jobs sync once per run, so re-launch threads for each rep. */
    double best = 1e30;
    for (int r = 0; r < reps; r++) {
        double t = run_parallel(w, th, nthreads, &bar, 1);
        if (t < best) best = t;
    }

    double flops = w[0].flops * nthreads;   /* each kernel reports its own */
    double sink = 0;
    for (int i = 0; i < nthreads; i++) sink += w[i].sink;
    if (sink == 12345.6789) printf(" ");   /* keep results live */
    free(w); free(th);
    return flops / best / 1e9;
}

/* ------------------------------------------------------ bandwidth driver */

typedef struct { double read_gbs, copy_gbs, triad_gbs; } bw_t;

static bw_t bandwidth(double *A, double *B, double *C, size_t n_total,
                      int nthreads, int reps) {
    barrier_t bar; barrier_init(&bar, nthreads);
    work_t   *w  = calloc(nthreads, sizeof *w);
    pthread_t *th = calloc(nthreads, sizeof *th);

    size_t chunk = (n_total / nthreads) & ~(size_t)(NDBL * 8 - 1);
    for (int i = 0; i < nthreads; i++) {
        w[i] = (work_t){ .tid = i, .nthreads = nthreads, .n = chunk, .reps = reps,
                         .a = A + i * chunk, .b = B + i * chunk, .c = C + i * chunk,
                         .bar = &bar };
    }
    size_t n_used = chunk * (size_t)nthreads;
    bw_t r;

    for (int i = 0; i < nthreads; i++) w[i].job = JOB_READ;
    r.read_gbs = n_used * sizeof(double) / run_parallel(w, th, nthreads, &bar, reps) / 1e9;

    for (int i = 0; i < nthreads; i++) w[i].job = JOB_COPY;
    r.copy_gbs = 2.0 * n_used * sizeof(double) / run_parallel(w, th, nthreads, &bar, reps) / 1e9;

    for (int i = 0; i < nthreads; i++) w[i].job = JOB_TRIAD;
    r.triad_gbs = 3.0 * n_used * sizeof(double) / run_parallel(w, th, nthreads, &bar, reps) / 1e9;

    double sink = 0;
    for (int i = 0; i < nthreads; i++) sink += w[i].sink;
    if (sink == 12345.6789) printf(" ");
    free(w); free(th);
    return r;
}

/* ------------------------------------------------------ cache: latency */
/*
 * Pointer chase around a single random cycle over cache lines.  Random order
 * defeats the hardware prefetcher and the serial dependency exposes raw
 * load-to-use latency, so the curve steps up once per cache level.
 */

static uint64_t rng_s = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) {
    rng_s ^= rng_s << 13; rng_s ^= rng_s >> 7; rng_s ^= rng_s << 17;
    return rng_s;
}

#define LINE 64

static double chase_ns(void **buf, size_t bytes, long steps) {
    size_t nodes = bytes / LINE;
    if (nodes < 2) return 0;

    size_t *perm = malloc(nodes * sizeof *perm);
    for (size_t i = 0; i < nodes; i++) perm[i] = i;
    /* Sattolo: guarantees one cycle covering every node */
    for (size_t i = nodes - 1; i > 0; i--) {
        size_t j = rnd() % i;
        size_t t = perm[i]; perm[i] = perm[j]; perm[j] = t;
    }
    char *base = (char *)buf;
    for (size_t i = 0; i < nodes; i++)
        *(void **)(base + perm[i] * LINE) = base + perm[(i + 1) % nodes] * LINE;
    free(perm);

    void **p = (void **)base;
    for (size_t i = 0; i < nodes; i++) p = (void **)*p;   /* warm */

    double t0 = now_s();
    for (long i = 0; i < steps; i++) p = (void **)*p;
    double dt = now_s() - t0;

    if (p == (void **)0x1) printf(" ");
    return dt / (double)steps * 1e9;
}

/* --------------------------------------------- cache: read bandwidth */

static double cache_bw_gbs(double *buf, size_t bytes, double target_s) {
    size_t n = bytes / sizeof(double);
    n &= ~(size_t)(NDBL * 8 - 1);
    if (!n) return 0;

    long reps = 1;
    double dt;
    for (;;) {                       /* scale reps until the sample is long enough */
        double t0 = now_s();
        double s = 0;
        for (long r = 0; r < reps; r++) s += read_sum(buf, n);
        dt = now_s() - t0;
        if (s == 12345.6789) printf(" ");
        if (dt > target_s || reps > (1L << 30)) break;
        reps *= 2;
    }
    return (double)n * sizeof(double) * reps / dt / 1e9;
}

/* ---------------------------------------------------------- HW reporting */

static void print_hw_caches(void) {
#ifdef __APPLE__
    const char *keys[] = { "hw.perflevel0.l1dcachesize", "hw.perflevel0.l2cachesize",
                           "hw.perflevel1.l1dcachesize", "hw.perflevel1.l2cachesize" };
    const char *lbl[]  = { "P-core L1d", "P-core L2 (shared)",
                           "E-core L1d", "E-core L2 (shared)" };
    char b[32];
    for (int i = 0; i < 4; i++) {
        uint64_t v = 0; size_t sz = sizeof v;
        if (sysctlbyname(keys[i], &v, &sz, NULL, 0) == 0 && v)
            printf("  %-20s %s\n", lbl[i], hsize((size_t)v, b, sizeof b));
    }
#else
    long v; char b[32];
    if ((v = sysconf(_SC_LEVEL1_DCACHE_SIZE)) > 0) printf("  %-20s %s\n", "L1d", hsize(v, b, sizeof b));
    if ((v = sysconf(_SC_LEVEL2_CACHE_SIZE))  > 0) printf("  %-20s %s\n", "L2",  hsize(v, b, sizeof b));
    if ((v = sysconf(_SC_LEVEL3_CACHE_SIZE))  > 0) printf("  %-20s %s\n", "L3",  hsize(v, b, sizeof b));
#endif
}

static int default_threads(void) {
#ifdef __APPLE__
    uint64_t p = 0; size_t sz = sizeof p;
    if (sysctlbyname("hw.perflevel0.physicalcpu", &p, &sz, NULL, 0) == 0 && p) return (int)p;
    sz = sizeof p;
    if (sysctlbyname("hw.physicalcpu", &p, &sz, NULL, 0) == 0 && p) return (int)p;
    return 4;
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int)n : 4;
#endif
}

static const char *cpu_name(char *buf, size_t n) {
#ifdef __APPLE__
    size_t sz = n;
    if (sysctlbyname("machdep.cpu.brand_string", buf, &sz, NULL, 0) == 0) return buf;
#else
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof line, f)) {
            char *c = strchr(line, ':');
            if (c && (strstr(line, "model name") || strstr(line, "Model"))) {
                c += 2; c[strcspn(c, "\n")] = 0;
                snprintf(buf, n, "%s", c); fclose(f); return buf;
            }
        }
        fclose(f);
    }
#endif
    snprintf(buf, n, "unknown CPU");
    return buf;
}

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv) {
    int nthreads = 0, quick = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-t") && i + 1 < argc) nthreads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-q")) quick = 1;
        else { fprintf(stderr, "usage: %s [-t threads] [-q]\n", argv[0]); return 2; }
    }
    if (nthreads <= 0) nthreads = default_threads();
    be_fast();

    char nb[128];
    printf("=== machine ===\n");
    printf("  %s\n", cpu_name(nb, sizeof nb));
    printf("  memory kernels: %d B vectors (%d x f64); %d threads\n",
           VBYTES, NDBL, nthreads);
    printf("  FP ISAs compiled in:");
    for (int i = 0; i < NISA; i++)
        printf(" %s%s", ISAS[i].name, ISAS[i].avail() ? "" : "(n/a)");
    printf("\n");
    printf("  caches reported by the OS:\n");
    print_hw_caches();

    /* ---------------- 1. peak FP ---------------- */
    printf("\n=== 1. peak FP throughput (FMA chains, no memory traffic) ===\n");
    long iters = quick ? 20L * 1000 * 1000 : 80L * 1000 * 1000;
    int  reps  = quick ? 2 : 3;

    printf("  single thread:\n");
    printf("  %-12s %-18s %10s %10s %10s %10s\n",
           "ISA", "op", "f64", "f32", "f16", "bf16");

    double best_by_type[4] = {0, 0, 0, 0};
    int best = -1; double best_g32 = 0;
    for (int i = 0; i < NISA; i++) {
        int ok = ISAS[i].avail();
        fp_fn fns[4] = { ISAS[i].f64, ISAS[i].f32, ISAS[i].f16, ISAS[i].bf16 };
        char col[4][16];
        for (int d = 0; d < 4; d++) {
            if (!fns[d])   { snprintf(col[d], sizeof col[d], "%s", "-");   continue; }
            if (!ok)       { snprintf(col[d], sizeof col[d], "%s", "n/a"); continue; }
            double g = fp_gflops(fns[d], 1, iters, reps);
            flops_c(g, col[d], sizeof col[d]);
            if (g > best_by_type[d]) best_by_type[d] = g;
            if (d == 1 && g > best_g32) { best_g32 = g; best = i; }
        }
        printf("  %-12s %-18s %10s %10s %10s %10s\n", ISAS[i].name, ISAS[i].note,
               col[0], col[1], col[2], col[3]);
    }
    if (best < 0) { fprintf(stderr, "no usable ISA\n"); return 1; }

    {
        char p0[24], p1[24], p2[24], p3[24];
        printf("\n  1-thread peak by type:  f64 %s   f32 %s   f16 %s   bf16 %s\n",
               flops_s(best_by_type[0], p0, sizeof p0),
               flops_s(best_by_type[1], p1, sizeof p1),
               flops_s(best_by_type[2], p2, sizeof p2),
               flops_s(best_by_type[3], p3, sizeof p3));
    }

    double g64_1 = fp_gflops(ISAS[best].f64, 1, iters, reps);
    double g64_n = fp_gflops(ISAS[best].f64, nthreads, iters, reps);
    double g32_n = fp_gflops(ISAS[best].f32, nthreads, iters, reps);
    printf("\n  fastest ISA: %s\n", ISAS[best].name);
    {
        char a[24], b[24];
        if (g64_n > 0)
            printf("  %-22s %14s  (%.2fx scaling)\n", "f64, all threads",
                   flops_s(g64_n, a, sizeof a), g64_1 > 0 ? g64_n / g64_1 : 0.0);
        printf("  %-22s %14s  (%.2fx scaling)\n", "f32, all threads",
               flops_s(g32_n, b, sizeof b), g32_n / best_g32);
    }

    /* ---------------- 2. memory bandwidth ---------------- */
    size_t arr_bytes = (quick ? 64 : 192) * (size_t)1048576;   /* per array */
    size_t n_total   = arr_bytes / sizeof(double);
    double *A = xalloc(arr_bytes), *B = xalloc(arr_bytes), *C = xalloc(arr_bytes);
    for (size_t i = 0; i < n_total; i++) { A[i] = 1.0; B[i] = 2.0; C[i] = 3.0; }

    printf("\n=== 2. memory bandwidth (%zu MiB/array, DRAM-resident) ===\n",
           arr_bytes >> 20);
    printf("  %-8s %11s %11s %11s\n", "threads", "read", "copy", "triad");
    for (int t = 1; t <= nthreads; t *= 2) {
        bw_t r = bandwidth(A, B, C, n_total, t, quick ? 3 : 5);
        char b1[24], b2[24], b3[24];
        printf("  %-8d %11s %11s %11s\n", t, bw_s(r.read_gbs, b1, sizeof b1),
               bw_s(r.copy_gbs, b2, sizeof b2), bw_s(r.triad_gbs, b3, sizeof b3));
    }
    if ((nthreads & (nthreads - 1)) != 0) {     /* e.g. 10 P-cores */
        bw_t r = bandwidth(A, B, C, n_total, nthreads, quick ? 3 : 5);
        char b1[24], b2[24], b3[24];
        printf("  %-8d %11s %11s %11s\n", nthreads, bw_s(r.read_gbs, b1, sizeof b1),
               bw_s(r.copy_gbs, b2, sizeof b2), bw_s(r.triad_gbs, b3, sizeof b3));
    }
    printf("  (copy/triad counts touched bytes; write-allocate makes real DRAM\n"
           "   traffic ~1.5x higher unless the store bypasses the cache)\n");

    /* ---------------- 3. cache hierarchy ---------------- */
    printf("\n=== 3. cache hierarchy (single thread) ===\n");
    printf("  %12s %12s %13s\n", "working set", "latency", "read bandwidth");

    size_t max_bytes = (quick ? 128 : 512) * (size_t)1048576;
    void **chase_buf = xalloc(max_bytes);
    memset(chase_buf, 0, max_bytes);

    enum { MAXPT = 64 };
    size_t szs[MAXPT]; double lat[MAXPT], bw[MAXPT];
    int np = 0;
    for (double s = 4096.0; s <= (double)max_bytes && np < MAXPT; s *= M_SQRT2) {
        size_t bytes = ((size_t)s) & ~(size_t)(LINE - 1);
        if (np && bytes == szs[np - 1]) continue;
        long steps = bytes <= (1 << 20) ? 20000000 : (bytes <= (32u << 20) ? 4000000 : 1000000);
        if (quick) steps /= 4;

        szs[np] = bytes;
        lat[np] = chase_ns(chase_buf, bytes, steps);
        if (!quick) {
            double l2 = chase_ns(chase_buf, bytes, steps);
            if (l2 < lat[np]) lat[np] = l2;
        }
        bw[np]  = cache_bw_gbs((double *)A, bytes, quick ? 0.03 : 0.08);

        char hb[32];
        char bb[24];
        printf("  %12s %9.2f ns %13s\n", hsize(bytes, hb, sizeof hb), lat[np],
               bw_s(bw[np], bb, sizeof bb));
        np++;
    }

    /* Infer levels: a cache boundary is a sustained jump in chase latency.
       The last size before each jump is the usable capacity of that level. */
    printf("\n  inferred cache levels (last size before each latency jump):\n");
    int found = 0;
    for (int i = 1; i < np - 1; i++) {
        double ratio = lat[i + 1] / lat[i];
        /* require the step to persist, so a single noisy point isn't a "level" */
        double after = (i + 2 < np) ? lat[i + 2] : lat[i + 1];
        if (ratio > 1.30 && after >= lat[i + 1] * 0.9) {
            char hb[32];
            printf("    level %d: ~%-10s  %.2f ns -> %.2f ns (%.2fx)\n",
                   ++found, hsize(szs[i], hb, sizeof hb), lat[i], lat[i + 1], ratio);
            i++;   /* skip the transition point itself */
        }
    }
    if (!found) printf("    none detected - try a longer run (drop -q)\n");
    printf("  note: a level's measured knee lands a bit below its nominal size\n"
           "        (page tables, replacement policy, and code/stack share the cache)\n");

    free(chase_buf); free(A); free(B); free(C);
    return 0;
}
