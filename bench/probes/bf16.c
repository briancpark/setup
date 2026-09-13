/* Probe: bf16 matrix/dot instructions (BFMMLA on arm64, VDPBF16PS on x86). */
#if defined(__aarch64__) || defined(__arm64__)
#include <arm_neon.h>
__attribute__((target("+bf16")))
static float32x4_t probe(float32x4_t c, bfloat16x8_t a) { return vbfmmlaq_f32(c, a, a); }
float32x4_t (*probe_ref)(float32x4_t, bfloat16x8_t) = probe;
#elif defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
__attribute__((target("avx512bf16,avx512f")))
static __m512 probe(__m512 c, __m512bh a) { return _mm512_dpbf16_ps(c, a, a); }
__m512 (*probe_ref)(__m512, __m512bh) = probe;
#endif
int main(void) { return 0; }
