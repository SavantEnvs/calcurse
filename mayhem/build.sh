#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# calcurse: autotools C app. Targets: fuzz_ical (in-process libFuzzer over ical_import_data) and three
# AFL file-input drivers (calcurse_apts/_todo/_conf) that run the real parse_args() loaders. The oracle
# build is upstream's own (src/calcurse + test/run-test) with normal flags.
set -euo pipefail


# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

B="$SRC/mayhem/build"
rm -rf "$B"
mkdir -p "$B"

# autoreconf regenerates configure/Makefile.in (gitignored upstream), offline.
sh ./autogen.sh >"$B/autogen.log" 2>&1 || { cat "$B/autogen.log"; exit 1; }

# Test/oracle build: upstream's own, normal flags (+ optional coverage), out of tree.
mkdir -p "$B/test"
(
  cd "$B/test"
  env -u CFLAGS -u CPPFLAGS -u LDFLAGS "$SRC/configure" --disable-nls --disable-docs \
      CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" >configure.log 2>&1 || { cat configure.log; exit 1; }
  make -j"$MAYHEM_JOBS" -C src calcurse
  make -C test run-test
)
LIBS="$(sed -n 's/^LIBS = //p' "$B/test/src/Makefile")"

# -fno-sanitize=function: calcurse pervasively calls its llist/htable callbacks through (void *)-typed
# function pointers, so UBSan's function-type check fires on every item list; ASan and the rest of UBSan stay on.
# The project's own sources, compiled directly against the generated config.h. calcurse.c holds main(),
# renamed so the AFL drivers can use a calcurse_main-free link. Flavours: libFuzzer-instrumented,
# plain sanitized (standalone reproducer), AFL-instrumented.
CFLAGS_COMMON="-std=c99 -D_POSIX_C_SOURCE=200809L -DHAVE_CONFIG_H -DDOCDIR=\"/usr/local/share/doc/calcurse\" -DLOCALEDIR=\"/usr/local/share/locale\" -I$B/test -I$SRC/src -O1 -w"
compile_flavour() {  # <dir> <compiler> <flags...>
  local dir="$1" cc="$2" f extra; shift 2
  mkdir -p "$dir"
  for f in "$SRC"/src/*.c; do
    extra=""; [ "$(basename "$f")" = calcurse.c ] && extra="-Dmain=calcurse_main"
    "$cc" "$@" $extra -c "$f" -o "$dir/$(basename "${f%.c}").o" &
    while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n; done
  done
  wait
}
compile_flavour "$B/obj-fuzz" "$CC" $CFLAGS_COMMON $SANITIZER_FLAGS -fno-sanitize=function $DEBUG_FLAGS -fsanitize=fuzzer-no-link
compile_flavour "$B/obj-plain" "$CC" $CFLAGS_COMMON $SANITIZER_FLAGS -fno-sanitize=function $DEBUG_FLAGS
compile_flavour "$B/obj-afl" afl-clang-fast $CFLAGS_COMMON $SANITIZER_FLAGS -fno-sanitize=function $DEBUG_FLAGS

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$B/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

# libFuzzer target and its run-once reproducer.
$CC $CFLAGS_COMMON $SANITIZER_FLAGS -fno-sanitize=function $DEBUG_FLAGS -fsanitize=fuzzer-no-link -c "$SRC/mayhem/fuzz_ical.c" -o "$B/fuzz_ical-fuzz.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/fuzz_ical-fuzz.o" "$B"/obj-fuzz/*.o "$B/lsan_off.o" $LIBS \
    -o /mayhem/fuzz_ical
$CC $CFLAGS_COMMON $SANITIZER_FLAGS -fno-sanitize=function $DEBUG_FLAGS -c "$SRC/mayhem/fuzz_ical.c" -o "$B/fuzz_ical-plain.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$B/standalone_main.o" "$B/fuzz_ical-plain.o" "$B"/obj-plain/*.o "$B/lsan_off.o" $LIBS \
    -o /mayhem/fuzz_ical-standalone

# AFL file-input targets: the real parse_args() over one data file.
for mode in apts todo conf; do
  afl-clang-fast $CFLAGS_COMMON $SANITIZER_FLAGS -fno-sanitize=function $DEBUG_FLAGS -DMODE_"$(echo "$mode" | tr a-z A-Z)" \
      -c "$SRC/mayhem/calcurse_cli.c" -o "$B/calcurse_$mode.o"
  afl-clang-fast $SANITIZER_FLAGS $DEBUG_FLAGS "$B/calcurse_$mode.o" "$B"/obj-afl/*.o "$B/lsan_off.o" $LIBS \
      -o "/mayhem/calcurse_$mode"
done
