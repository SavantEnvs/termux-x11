#!/usr/bin/env bash
#
# mayhem/build.sh — termux-x11 (Android X server). Builds, offline and re-runnably:
#   1. the X server termux-x11 pins (lorie/src/main/cpp/xserver @ 7dbd8d0d, vendored in the image
#      at /opt/toolchains/deps/xserver-7dbd8d0d/src) with meson, out of tree in mayhem/build/,
#      instrumented with AFL (afl-clang-fast) + $SANITIZER_FLAGS + $DEBUG_FLAGS (DWARF 3);
#   2. /mayhem/xvfb-lorie: that server's Xvfb DDX with termux-x11's own lorie/clipboard.c linked in
#      (unmodified) through mayhem/harness/lorie_fuzz_ddx.c. It reads one X11 client byte stream
#      from `-fuzzinput <file>` (an AFL file-input target; it is its own reproducer).
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
: "${XSERVER_SRC:=/opt/toolchains/deps/xserver-7dbd8d0d/src}"
export SANITIZER_FLAGS DEBUG_FLAGS MAYHEM_JOBS

cd "$SRC"
LORIE="$SRC/lorie/src/main/cpp/lorie"
H="$SRC/mayhem/harness"
B="$SRC/mayhem/build"          # gitignored by mayhem/.gitignore
mkdir -p "$B"

# UBSan -fsanitize=function is relaxed (only that check): the X server calls no-op stubs such as
# NoopDDA through mismatched function-pointer types everywhere, so it fires during server start-up.
SAN="$SANITIZER_FLAGS"
[ -z "$SAN" ] || SAN="$SAN -fno-sanitize=function"
FLAGS="$SAN $DEBUG_FLAGS -O1"
# One server build = meson configure+build of the pinned xserver in $1, then link $6 from Xvfb's
# own link line with vfb's InitOutput swapped for the lorie wrapper.
#   build_variant <builddir> <CC> <CXX> <CFLAGS> <LDFLAGS> <output>
build_variant() {
  local XB="$1" CC="$2" CXX="$3" CF="$4" LF="$5" OUT="$6"
  local O="$XB/mayhem-obj"
  if [ ! -f "$XB/build.ninja" ]; then
    CC="$CC" CXX="$CXX" CFLAGS="$CF" CXXFLAGS="$CF" LDFLAGS="$LF" \
    meson setup "$XB" "$XSERVER_SRC" \
      --buildtype=plain -Db_lundef=false -Ddefault_library=static \
      -Dxorg=false -Dxvfb=true -Dxnest=false -Dxephyr=false -Dxwin=false -Dxquartz=false \
      -Dglamor=false -Dglx=false -Ddri1=false -Ddri2=false -Ddri3=false -Ddrm=false \
      -Dudev=false -Dudev_kms=false -Dsystemd_logind=false -Dhal=false -Dlibunwind=false \
      -Dsecure-rpc=false -Dxdmcp=false -Dxdm-auth-1=false -Dlisten_tcp=false -Dlisten_unix=true \
      -Dxselinux=false -Dxcsecurity=false -Ddga=false -Dlinux_apm=false -Dlinux_acpi=false \
      -Dinput_thread=false -Dint10=false -Dvgahw=false -Dpciaccess=false -Ddocs=false -Ddevel-docs=false \
      -Dxkb_dir=/usr/share/X11/xkb -Dxkb_bin_dir=/usr/bin -Dxkb_output_dir=/tmp
  fi
  ninja -C "$XB" -j"$MAYHEM_JOBS" hw/vfb/Xvfb

  # Compile flags meson used for hw/vfb/InitOutput.c (include dirs, defines).
  local INC
  read -r -a INC < <(python3 -I - "$XB/compile_commands.json" <<'PY'
import json, shlex, sys
for e in json.load(open(sys.argv[1])):
    if e["file"].endswith("hw/vfb/InitOutput.c"):
        args = shlex.split(e["command"])
        keep = [a for a in args if a.startswith(("-I", "-D", "-include", "-std"))]
        print(" ".join(shlex.quote(a) for a in keep))
        break
PY
)
  ( cd "$XB"   # meson's -I paths are relative to the build dir
    mkdir -p "$O"
    $CC $CF "${INC[@]}" -DInitOutput=vfbInitOutput -DddxProcessArgument=vfbddxProcessArgument \
        -c "$XSERVER_SRC/hw/vfb/InitOutput.c" -o "$O/vfb_InitOutput.o"
    $CC $CF "${INC[@]}" -I"$H/stubs" -I"$LORIE" '-D__unused=__attribute__((__unused__))' \
        -c "$LORIE/clipboard.c" -o "$O/lorie_clipboard.o"
    $CC $CF "${INC[@]}" -c "$H/lorie_fuzz_ddx.c" -o "$O/lorie_fuzz_ddx.o"
    local EXTRA="$O/vfb_InitOutput.o $O/lorie_clipboard.o $O/lorie_fuzz_ddx.o -lpthread"
    if [ -n "$LF" ]; then
      $CXX $LF $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$O/lsan_off.o"
      EXTRA="$EXTRA $O/lsan_off.o"
    fi
    local LINK
    LINK=$(ninja -t commands hw/vfb/Xvfb | tail -n1)
    LINK=${LINK//hw\/vfb\/Xvfb.p\/InitOutput.c.o/$EXTRA}
    LINK=${LINK/-o hw\/vfb\/Xvfb /-o $OUT.tmp }
    eval "$LINK"
  )
  mv -f "$OUT.tmp" "$OUT"
  echo "built $OUT"
}

# Fuzz target: AFL instrumentation + sanitizers + DWARF 3; the compiler is reached by name via PATH.
AFL_QUIET=1 build_variant "$B/xserver" afl-clang-fast afl-clang-fast++ "$FLAGS" "$SAN" "$SRC/xvfb-lorie"

# Test oracle build: the same server + lorie clipboard with the project's normal flags, no sanitizers.
build_variant "$B/xserver-test" clang clang++ "-O1 -g" "" "$B/xvfb-lorie-test"
