#!/usr/bin/env bash
# Сборка байткода vkplay.luac под нужную версию Lua (Linux / macOS).
#
#   scripts/build.sh <lua-version> <suffix>
#   scripts/build.sh 5.1.5 macos   -> dist/vkplay-macos.luac  (VLC 3.x macOS / Windows)
#   scripts/build.sh 5.2.4 linux   -> dist/vkplay-linux.luac  (VLC 3.x из пакетов Linux)
#   scripts/build.sh 5.4.7 vlc4    -> dist/vkplay-vlc4.luac   (VLC 4.x)
#
# luac собирается из официальных исходников lua.org. Для Lua 5.1 накладывается
# патч VLC (scripts/patches/vlc3-luac-32bits.patch): VLC 3.x для Windows/macOS
# хранит в байткоде размеры 32-битными, иначе он не загрузит .luac.
set -euo pipefail

LUA_VERSION="${1:?usage: build.sh <lua-version> <suffix>}"
SUFFIX="${2:?usage: build.sh <lua-version> <suffix>}"
LUA_TARBALL_URL="${LUA_TARBALL_URL:-https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build"
DIST="$ROOT/dist"
PATCH="$ROOT/scripts/patches/vlc3-luac-32bits.patch"
mkdir -p "$WORK" "$DIST"

case "$LUA_VERSION" in
  5.1.*) VLC_PATCH=1; SIZE_T=04 ;;   # формат VLC 3.x (Windows/macOS)
  5.2.*) VLC_PATCH=0; SIZE_T=08 ;;   # системный Lua 5.2 в Linux-дистрибутивах
  *)     VLC_PATCH=0; SIZE_T=   ;;   # 5.3+: size_t в заголовке нет
esac

if [ -n "${LUAC:-}" ]; then
  # Готовый luac нужной версии (например, для локальной проверки)
  command -v "$LUAC" >/dev/null || { echo "LUAC not found: $LUAC" >&2; exit 1; }
else
  # (без "[ ... ] && echo" в подстановке: при set -e ложное условие молча завершает скрипт)
  if [ "$VLC_PATCH" = 1 ]; then TAG="$LUA_VERSION-vlc"; else TAG="$LUA_VERSION"; fi
  SRC_ROOT="$WORK/lua-$TAG"
  if [ ! -d "$SRC_ROOT" ]; then
    rm -rf "$WORK/unpack" && mkdir -p "$WORK/unpack"
    curl -fsSL "$LUA_TARBALL_URL" | tar -xz -C "$WORK/unpack" --strip-components=1
    if [ "$VLC_PATCH" = 1 ]; then
      patch -d "$WORK/unpack" -p1 --forward --quiet < "$PATCH"
      find "$WORK/unpack" -name '*.orig' -delete   # резервные копии patch
    fi
    mv "$WORK/unpack" "$SRC_ROOT"
  fi

  LUAC="$WORK/luac-$TAG"
  if [ ! -x "$LUAC" ]; then
    # Всё ядро + luac.c, без интерпретатора lua.c
    # (без mapfile: в macOS по умолчанию bash 3.2)
    (cd "$SRC_ROOT/src" && ${CC:-cc} -O2 -w -DLUA_USE_POSIX -o "$LUAC" $(ls *.c | grep -v '^lua\.c$') -lm)
  fi
fi

OUT="$DIST/vkplay-$SUFFIX.luac"
"$LUAC" -s -o "$OUT" "$ROOT/src/vkplay.lua"

# Проверка заголовка: 1B 'Lua' + версия (0x51 / 0x52 / 0x54);
# у 5.1/5.2 байт 8 = sizeof(size_t) в формате байткода
HEADER="$(od -A n -t x1 -N 12 "$OUT" | tr -s ' ' | sed 's/^ //')"
EXPECT_VER="$(echo "$LUA_VERSION" | awk -F. '{printf "%x%x", $1, $2}')"
GOT_VER="$(echo "$HEADER" | cut -d' ' -f5)"
if [ "$GOT_VER" != "$EXPECT_VER" ]; then
  echo "bytecode version mismatch: expected $EXPECT_VER, got $GOT_VER ($HEADER)" >&2
  exit 1
fi
if [ -n "$SIZE_T" ]; then
  GOT_SIZE="$(echo "$HEADER" | cut -d' ' -f9)"
  if [ "$GOT_SIZE" != "$SIZE_T" ]; then
    echo "bytecode size_t mismatch: expected $SIZE_T, got $GOT_SIZE ($HEADER)" >&2
    exit 1
  fi
fi

NOTE=""
if [ "$VLC_PATCH" = 1 ]; then NOTE=" + VLC patch"; fi
echo "built $OUT (Lua $LUA_VERSION$NOTE, header: $HEADER)"