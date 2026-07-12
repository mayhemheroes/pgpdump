#!/usr/bin/env bash
#
# mayhem/build.sh — build pgpdump's fuzz target and the functional-test oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/mayhemheroes/base) exports the build contract: CC, CXX, SANITIZER_FLAGS
# (ASan+UBSan halting), DEBUG_FLAGS (-g -gdwarf-3), SRC.
#
# Two independent out-of-tree autotools builds:
#   build-fuzz/   pgpdump compiled with $CC (clang) + $SANITIZER_FLAGS + $DEBUG_FLAGS.
#                 The whole program is the fuzz target: Mayhem's file-input engine execs a
#                 fresh process per input (`/mayhem/pgpdump @@`), which is the correct model
#                 for this CLI — the parser keeps file-scope/function-local static state
#                 (buffer.c) and terminates through exit()/warn_exit() on most paths, so a
#                 fork-per-input CLI (not an in-process libFuzzer loop) avoids carrying
#                 contaminated state between iterations. Do NOT AFL-instrument this binary:
#                 an afl-clang-fast build + `afl: true` broke Mayhem's mfuzz engine (0 edges,
#                 dynamic_analysis failed — runs #6/#7); a plain clang binary lets Mayhem's
#                 own coverage engine drive it (runs #1-#5 got 2k-16k edges this way). The
#                 instrumented binary doubles as the standalone run-once reproducer:
#                 /mayhem/pgpdump <input>.
#   build-oracle/ pgpdump compiled with the project's NORMAL flags — the binary the
#                 upstream TAP suite (test/test + test/*.res) drives in mayhem/test.sh.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# SANITIZER_FLAGS uses `=` (no colon) on purpose — an explicit EMPTY value
# (--build-arg SANITIZER_FLAGS=) is honored and builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# configure.ac derives the version via build-aux/git-version-gen (reads .git, no network).
git config --global --add safe.directory "$SRC" 2>/dev/null || true
autoreconf -fvi

# 1) Fuzz build: sanitizers + DWARF-3 on the whole program with plain clang, so the fuzzed
#    parser itself is instrumented and backtraces resolve project source lines. Mayhem's own
#    coverage engine instruments this native binary at run time — do NOT use afl-clang-fast
#    (an AFL-instrumented binary + Mayhemfile `afl: true` fails Mayhem's mfuzz phase → 0 edges).
mkdir -p build-fuzz
(cd build-fuzz && ../configure CC="$CC" CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS" \
    && make -j"$MAYHEM_JOBS")
cp build-fuzz/pgpdump /mayhem/pgpdump

# 2) Oracle build with the project's NORMAL flags (clean, independent build) for the
#    upstream golden-output suite; COVERAGE_FLAGS (empty by default) instruments only this.
mkdir -p build-oracle
(cd build-oracle && ../configure CFLAGS="-O -Wall $COVERAGE_FLAGS" \
    && make -j"$MAYHEM_JOBS")
