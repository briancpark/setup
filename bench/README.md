# bench

Microbenchmarks for **peak FP throughput**, **memory bandwidth**, and an
**empirical read of the cache hierarchy** — on the CPU, the Apple GPU (Metal),
and NVIDIA GPUs (CUDA).

```sh
make          # builds whatever this machine can build
make info     # show what was detected
make run      # build, then run each one
./bench_cpu -q   # quick mode; -t N pins thread count
```

`make` probes rather than assumes: SME and bf16 kernels are compiled only if
the compiler can actually build them, Metal is built only if the Metal
toolchain answers, CUDA only if `nvcc` is on PATH. clang is preferred and a
macOS SDK is passed explicitly, so a Homebrew clang first on PATH does not
break the build.

## Coverage

| | f64 | f32 | f16 | bf16 | matrix engine |
|---|---|---|---|---|---|
| CPU x86-64 | SSE2 / AVX / AVX2 / AVX-512 | same | AVX512-FP16 | VDPBF16PS | — |
| CPU arm64 | NEON | NEON | NEON+fp16 | BFMMLA | SME FMOPA (f32/f16/bf16) |
| Metal | not in Metal | ✓ | ✓ | ✓ | simdgroup 8x8 + MPS GEMM |
| CUDA | ✓ | ✓ | half2 | bf16x2 | WMMA tensor cores |

x86 kernels are selected at run time from one binary (`__builtin_cpu_supports`),
as are SME and bf16 on arm64 (`FEAT_SME` / `FEAT_BF16`), so the same build runs
on parts that lack them and reports `n/a`.

## What the three tests measure

**1. Peak FP** — N independent FMA chains, no memory traffic, so the only limit
is issue width × FMA latency. Nothing here is incidental:

- The **accumulate form** `acc += m*a` is required. `acc = acc*m + a` makes the
  result land in the addend register, costing an extra `mov` per op — it reads
  ~2× low.
- **bf16 has no plain multiply-add** on any shipping ISA. Those kernels use the
  dot-product/matrix instructions (BFMMLA, VDPBF16PS, bf16 FMOPA) that
  accumulate into f32, which is the number vendors quote.
- SME reports two rows: streaming-SVE FMLA (the vector unit at SVL) and FMOPA
  (the outer-product engine, SVL×SVL MACs per instruction) — different engines,
  and only the second one is the headline figure.

**2. Memory bandwidth** — STREAM-style read/copy/triad, swept over thread count.
Byte counts are *touched* bytes; with write-allocate, copy and triad move ~1.5×
that against DRAM.

**3. Cache hierarchy** — two independent probes over a growing working set:
pointer chase around one random cycle (Sattolo shuffle, defeats the prefetcher,
exposes load-to-use latency) and a streaming read. Levels are inferred from
sustained jumps in the latency curve.

## Apple M1 Pro reference run

CPU (8 P-cores):

| | measured | nominal |
|---|---|---|
| f64, 1 core | 50.6 GFLOP/s | 51.2 (2 lanes × 2 × 4 FMA × 3.2 GHz) |
| f32, 1 core | 101.6 GFLOP/s | 102.4 |
| f16, 1 core | 198.5 GFLOP/s | 204.8 |
| f64 / f32, 8 cores | 377 / 659 GFLOP/s | 410 / 819 |
| DRAM read / copy | 114 / 149 GB/s | 200 GB/s |
| L1d / L2 / SLC knees | 128 KiB / ~8–11 MiB / ~16–22 MiB | 128 KiB / 12 MiB / 24 MiB |

GPU (16-core, Metal):

| | measured |
|---|---|
| f32 / f16 / bf16 FMA loop | 2.15 / 2.98 / 0.54 TFLOP/s |
| f16 simdgroup matrix | 4.07 TFLOP/s |
| f32 / f16 GEMM (MPS, tuned reference) | 3.89 / 3.79 TFLOP/s |
| DRAM read / copy | 180 / 184 GB/s |
| L1 / L2 / SLC / DRAM latency | 61 / 97 / 106 / 460 ns |
| L1 / L2 / DRAM read bandwidth | 1.30 TB/s / 612 GB/s / 184 GB/s |

bf16 at 0.54 TFLOP/s is emulation — M1 has no bf16 ALU. A hand-written FMA loop
reaches only ~40% of this GPU's 5.3 TFLOP/s paper peak while MPS's tuned GEMM
reaches ~73%, so both are reported: the loop is a floor, not a ceiling.

## Traps these benchmarks are built around

Each of these produced a wrong number during development, and each is now
guarded in the code:

- **`-Ofast` / `-ffast-math`** is licensed to reassociate FP and collapse a
  fixed dependency chain. The build uses `-O3 -ffp-contract=fast`. (`make ofast`
  is not offered for that reason; on this machine both measured the same, but
  that is luck, not a guarantee.)
- **Too few accumulators in the read kernel** measures the FPU, not memory: with
  4 chains, fadd latency caps it near 60 GB/s. It uses 8.
- **Condvar barriers** cost tens of microseconds — the same order as one
  bandwidth kernel — which shows up as nonsense thread scaling. It spins.
- **GPU: uniform/scalar datapath.** If nothing in a GPU kernel varies per lane,
  the Apple compiler hoists the whole chain onto the scalar unit and runs it
  once per simdgroup. Uniform seeds reported *130 TFLOP/s on a 5.3 TFLOP/s
  GPU*. Every accumulator is seeded from the thread id.
- **GPU: dead-code elimination via an impossible compare.** Hiding the store
  behind `if (sum == 1234.5f)` is fine for f32 but fatal for f16: no half value
  equals 1234.5 exactly, so the compiler proves the branch dead and deletes the
  loop (it reported 97 PFLOP/s). Stores are unconditional.
- **GPU: partially-live results.** Reducing only `s[0]` of a `float4` lets the
  compiler drop 3 of 4 lanes and overstates by 4×. Every component is summed.
- **Working-set sweeps** must keep every lane inside the window (power-of-two
  mask), or lanes past its end idle and you measure occupancy, not bandwidth.
- **`CC ?= clang` does nothing** in a Makefile — `CC` is a built-in with default
  `cc`. The Makefile overrides only when `$(origin CC)` is `default`.

## Verification status

- `cpu/bench_cpu.c` — built and run on Apple M1 Pro (arm64). The x86-64 paths
  are cross-compiled and verified at the instruction level (`vfmadd231pd` on
  `%zmm` for AVX-512, `%ymm` for AVX2, `mulpd`+`addpd` for SSE2,
  `vfmadd231ph`, `vdpbf16ps`) but have not been *run* on x86 hardware —
  Rosetta exposes only SSE2. SME kernels compile but this part lacks FEAT_SME,
  so they are unrun.
- `metal/bench_metal.m` — built and run on the M1 Pro GPU.
- `cuda/bench_cuda.cu` — **written but never compiled or run**: no CUDA
  toolchain on the development machine. Treat the first run on a real GPU as a
  debugging session, not a measurement.
