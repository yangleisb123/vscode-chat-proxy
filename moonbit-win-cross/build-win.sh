#!/usr/bin/env bash
# 从 Linux 交叉编译 MoonBit 程序为 Windows x64 exe（新原生后端 + mingw-w64）
# 依赖：moon 工具链、x86_64-w64-mingw32-gcc
# 用法: ./build-win.sh <moon项目目录> [输出exe路径]
set -euo pipefail

PROJ="${1:?用法: build-win.sh <moon项目目录> [输出exe路径]}"
OUT="${2:-$(basename "$PROJ").exe}"
export PATH="$HOME/.moon/bin:$PATH"
XCC=x86_64-w64-mingw32-gcc
MOON_LIB="$HOME/.moon/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$PROJ"

# 1) 正常构建 release，得到 .core 中间表示
MOONBIT_NEW_NATIVE=1 moon build --target native --release >&2

# 2) 定位 main 包（pkgtype executable）的 .core；推导包全名（模块名 + 相对路径）
MAIN_CORE=""
for c in $(find _build/native/release/build -name '*.core'); do
  rel="$(dirname "${c#_build/native/release/build/}")"
  if grep -q 'pkgtype(kind: "executable")' "$rel/moon.pkg" 2>/dev/null; then
    MAIN_CORE="$c"; break
  fi
done
[ -n "$MAIN_CORE" ] || { echo "找不到 executable 包" >&2; exit 1; }
REL="$(dirname "${MAIN_CORE#_build/native/release/build/}")"
MOD_NAME="$(sed -n 's/^name *= *"\(.*\)"/\1/p' moon.mod | head -1)"
MAIN_FULL="$MOD_NAME/$REL"
PROJ_CORES="$(find _build/native/release/build -name '*.core' | tr '\n' ' ')"

# 3) 交叉生成 Windows COFF 对象（核心库 + 项目代码一起链接）
CORES="$(find "$MOON_LIB/core/_build/native/release/bundle" -name '*.core' | tr '\n' ' ')"
moonc link-core -target x86_64-pc-windows-msvc \
  -main "$MAIN_FULL" -pkg-config-path "$REL/moon.pkg" \
  -o "$WORK/main.o" $CORES $PROJ_CORES

# 4) 用 mingw 编译 MoonBit 运行时 C 源码（默认系统分配器，无需 mimalloc）
for src in runtime env utf backtrace; do
  "$XCC" -c -O2 -I"$HOME/.moon/include" "$MOON_LIB/runtime/$src.c" -o "$WORK/$src.o"
done

# 5) 去掉 MSVC 专用 .drectve 段，静态链接（只依赖 Windows 系统 DLL）
x86_64-w64-mingw32-objcopy --remove-section=.drectve "$WORK/main.o" "$WORK/main-clean.o"
"$XCC" -O2 -static "$WORK/main-clean.o" "$WORK/runtime.o" "$WORK/env.o" \
  "$WORK/utf.o" "$WORK/backtrace.o" -o "$OUT"
echo "已生成: $OUT" >&2
file "$OUT" >&2
