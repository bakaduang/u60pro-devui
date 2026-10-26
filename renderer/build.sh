#!/usr/bin/env bash
# Build the extended u60pro-devui renderer (static aarch64-linux-musl) with zig 0.13.
#   renderer/build.sh <work-dir> <out-binary>
# Fetches scoltzero/u60pro-devui-remix at the pinned commit, applies devui-xpage.patch,
# downloads litehtml v0.10 and FreeType 2.13.3, and links everything statically.
# Needs: git, curl, tar, zig (ZIG=/path/to/zig to override).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="${1:?work dir}"; OUT="${2:?output binary}"
ZIG="${ZIG:-zig}"
TGT="-target aarch64-linux-musl"
cfg() { node -e "const c=require('$ROOT/version.config.json');console.log(c.upstream.$1)"; }
UP_REPO="$(cfg repo)"; UP_COMMIT="$(cfg commit)"

mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
SRC="$WORK/remix"; LH="$WORK/litehtml"; FT="$WORK/freetype"
DEP="$WORK/deps"; OBJ="$WORK/obj"

if [ ! -d "$SRC/.git" ]; then
  git -c core.autocrlf=false clone -q "$UP_REPO" "$SRC"
fi
git -C "$SRC" -c core.autocrlf=false checkout -q -f "$UP_COMMIT"
git -C "$SRC" clean -qfdx
git -C "$SRC" -c core.autocrlf=false apply "$HERE/devui-xpage.patch"
echo "upstream $UP_COMMIT + devui-xpage.patch"

fetch() { # url dir
  [ -d "$2" ] && return 0
  mkdir -p "$2"
  curl -fsSL --retry 3 "$1" | tar -xz --strip-components=1 -C "$2"
}
fetch https://github.com/litehtml/litehtml/archive/refs/tags/v0.10.tar.gz "$LH"
fetch https://github.com/freetype/freetype/archive/refs/tags/VER-2-13-3.tar.gz "$FT"

build_ft() {
  mkdir -p "$DEP/ft"
  cat > "$DEP/ft/ftmodule_min.h" <<'EOF'
FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
EOF
  local objs=""
  for s in base/ftbase base/ftsystem base/ftinit base/ftdebug base/ftbbox \
           base/ftbitmap base/ftglyph base/ftmm cache/ftcache autofit/autofit \
           truetype/truetype cff/cff psaux/psaux psnames/psnames \
           pshinter/pshinter sfnt/sfnt smooth/smooth gzip/ftgzip; do
    o="$DEP/ft/$(echo "$s" | tr / _).o"
    "$ZIG" cc $TGT -O2 -w -DFT2_BUILD_LIBRARY -I"$FT/include" -I"$DEP/ft" \
      -DFT_CONFIG_MODULES_H='"ftmodule_min.h"' -c "$FT/src/$s.c" -o "$o"
    objs="$objs $o"
  done
  rm -f "$DEP/libfreetype.a"
  "$ZIG" ar rcs "$DEP/libfreetype.a" $objs
}

build_lh() {
  mkdir -p "$DEP/lh"
  local GI="-I$LH/src/gumbo/include -I$LH/src/gumbo/include/gumbo"
  local objs=""
  for f in "$LH"/src/gumbo/*.c; do
    o="$DEP/lh/gumbo_$(basename "$f" .c).o"
    "$ZIG" cc $TGT -O2 -w $GI -c "$f" -o "$o"; objs="$objs $o"
  done
  for f in "$LH"/src/*.cpp; do
    o="$DEP/lh/lh_$(basename "$f" .cpp).o"
    "$ZIG" c++ $TGT -O2 -std=c++17 -w -I"$LH/include" -I"$LH/include/litehtml" $GI -c "$f" -o "$o"
    objs="$objs $o"
  done
  rm -f "$DEP/liblitehtml.a"
  "$ZIG" ar rcs "$DEP/liblitehtml.a" $objs
}

build_app() {
  local CFLAGS="-std=c11 -Os -ffunction-sections -fdata-sections -Wall -Wextra -Wno-unused-parameter \
    -Wno-format-truncation -Wno-unknown-warning-option \
    -D_GNU_SOURCE -DLV_CONF_INCLUDE_SIMPLE -I$SRC -I$SRC/include -I$SRC/third_party/stb -I$FT/include"
  local objs=""
  rm -rf "$OBJ"; mkdir -p "$OBJ"
  for s in backlight data devui_ext drm_disp json key_input touch_input xpage htmlmain; do
    "$ZIG" cc $TGT $CFLAGS -pthread -c "$SRC/src/$s.c" -o "$OBJ/$s.o"
    objs="$objs $OBJ/$s.o"
  done
  "$ZIG" c++ $TGT -std=c++17 -O2 -w -I"$SRC/include" -I"$FT/include" -I"$LH/include" -I"$LH/include/litehtml" \
    -I"$SRC/third_party/stb" -c "$SRC/src/html_view.cpp" -o "$OBJ/html_view.o"
  objs="$objs $OBJ/html_view.o"
  mkdir -p "$(dirname "$OUT")"
  "$ZIG" c++ $TGT -static -s $objs "$DEP/liblitehtml.a" "$DEP/libfreetype.a" -Wl,--gc-sections -pthread -lm -o "$OUT"
}

[ -f "$DEP/libfreetype.a" ] || build_ft
[ -f "$DEP/liblitehtml.a" ] || build_lh
build_app
grep -q DEVUI-XPAGE-API-2 "$OUT" || { echo "xpage marker missing" >&2; exit 1; }
ls -l "$OUT"
sha256sum "$OUT" 2>/dev/null || true
