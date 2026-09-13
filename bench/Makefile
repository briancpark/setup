# Auto-detecting build for the CPU / Metal / CUDA benchmarks.
#
#   make          build everything this machine can build
#   make run      build, then run each one in turn
#   make info     show what was detected and stop
#
# Detection is by probe, not by guesswork: each optional feature is compiled
# as a tiny test program first, so a toolchain that merely *has* the header
# but cannot build the code is treated as absent.

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

# ---- compiler: clang preferred, and it must actually work ------------------
# On macOS the clang first on PATH is often Homebrew's, which has no SDK
# configured; fall back to the Xcode one rather than failing the build.
# `CC ?= clang` would not work: make defines CC=cc as a built-in default, so
# ?= never fires.  Only override when the value is make's own default, which
# leaves an explicit `make CC=gcc` or an exported CC alone.
ifeq ($(origin CC),default)
  CC := clang
endif
# Invoked directly (not through xcrun) a macOS clang has no SDK, so pass one
# explicitly; this also rescues a Homebrew clang that is first on PATH.
SYSROOT :=
ifeq ($(UNAME_S),Darwin)
  SDK := $(shell xcrun --show-sdk-path 2>/dev/null)
  ifneq ($(SDK),)
    SYSROOT := -isysroot $(SDK)
  endif
  CC_WORKS := $(shell printf 'int main(void){return 0;}' > /tmp/.bench_cc.c 2>/dev/null && \
                $(CC) $(SYSROOT) /tmp/.bench_cc.c -o /tmp/.bench_cc 2>/dev/null && echo yes)
  ifneq ($(CC_WORKS),yes)
    CC := $(shell xcrun --find clang 2>/dev/null || echo /usr/bin/clang)
  endif
endif

# ---- architecture flags ----------------------------------------------------
# -O3 -ffp-contract=fast, never -ffast-math: the FP kernels are fixed
# dependency chains and reassociation is licensed to collapse them.
ARCHFLAGS := -march=native
ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    ARCHFLAGS := -mcpu=apple-m1
  endif
endif
CFLAGS ?= -O3 $(ARCHFLAGS) $(SYSROOT) -ffp-contract=fast -Wall -Wextra
LDLIBS  := -lm -lpthread

# ---- optional CPU features (probe, don't assume) ---------------------------
SME_OK := $(shell $(CC) $(ARCHFLAGS) $(SYSROOT) -fsyntax-only probes/sme.c 2>/dev/null && echo yes)
BF16_OK := $(shell $(CC) $(ARCHFLAGS) $(SYSROOT) -fsyntax-only probes/bf16.c 2>/dev/null && echo yes)
ifneq ($(SME_OK),yes)
  CFLAGS += -DBENCH_NO_SME
endif
ifneq ($(BF16_OK),yes)
  CFLAGS += -DBENCH_NO_BF16
endif

# ---- GPU toolchains --------------------------------------------------------
HAVE_METAL := $(shell [ "$(UNAME_S)" = Darwin ] && xcrun -sdk macosx metal --version >/dev/null 2>&1 && echo yes)
HAVE_CUDA  := $(shell command -v nvcc >/dev/null 2>&1 && echo yes)

TARGETS := bench_cpu
ifeq ($(HAVE_METAL),yes)
  TARGETS += bench_metal
endif
ifeq ($(HAVE_CUDA),yes)
  TARGETS += bench_cuda
endif

all: $(TARGETS)

bench_cpu: cpu/bench_cpu.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

bench_metal: metal/bench_metal.m
	$(CC) -fobjc-arc -O2 $(SYSROOT) -Wall -Wno-deprecated-declarations $< -o $@ \
	  -framework Metal -framework MetalPerformanceShaders -framework Foundation

bench_cuda: cuda/bench_cuda.cu
	nvcc -O3 -arch=native $< -o $@

info:
	@echo "OS/arch     : $(UNAME_S) $(UNAME_M)"
	@echo "compiler    : $(CC)"
	@echo "arch flags  : $(ARCHFLAGS)"
	@echo "SME kernels : $(if $(filter yes,$(SME_OK)),compiled in,not supported by $(CC))"
	@echo "bf16 kernels: $(if $(filter yes,$(BF16_OK)),compiled in,not supported by $(CC))"
	@echo "Metal       : $(if $(filter yes,$(HAVE_METAL)),yes,no)"
	@echo "CUDA        : $(if $(filter yes,$(HAVE_CUDA)),yes,no (nvcc not found))"
	@echo "targets     : $(TARGETS)"

run: all
	@for t in $(TARGETS); do echo; echo "########## $$t ##########"; ./$$t $(ARGS); done

clean:
	rm -f bench_cpu bench_metal bench_cuda

.PHONY: all info run clean
