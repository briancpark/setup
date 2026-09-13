/* Probe: can this compiler build SME kernels for a baseline arm64 binary? */
#if defined(__aarch64__) || defined(__arm64__)
#include <arm_sme.h>
__attribute__((target("+sme"))) __arm_locally_streaming __arm_new("za")
static void probe(float *o) {
    svbool_t pg = svptrue_b32();
    svfloat32_t a = svdup_f32(1.0f);
    svzero_za();
    svmopa_za32_f32_m(0, pg, pg, a, a);
    svst1_hor_za32(0, 0, pg, o);
}
void (*probe_ref)(float *) = probe;
#endif
int main(void) { return 0; }
