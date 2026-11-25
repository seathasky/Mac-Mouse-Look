#!/bin/sh
set -eu
cd "$(dirname "$0")"
out=${1:?Pass an absolute destination for MouseLook.exe}
mkdir -p "$(dirname "$out")"
# Link the Win64 helper for this build from its C source.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
if command -v lld-link >/dev/null 2>&1; then
    set -- lld-link
elif command -v rustc >/dev/null 2>&1; then
    toolchain=$(rustc --print sysroot)
    host=$(rustc -vV | sed -n 's/^host: //p')
    set -- "$toolchain/lib/rustlib/$host/bin/rust-lld" -flavor link
else
    echo 'error: Building the Wine helper requires lld-link (brew install lld) or rust-lld from Rust.' >&2
    exit 1
fi
build=$(mktemp -d "${TMPDIR:-/tmp}/MacMouseLookHelper.XXXXXX")
trap 'rm -rf "$build"' EXIT
for dll in kernel32 user32; do
    "$@" /lib /machine:x64 "/def:$dll.def" "/out:$build/$dll.lib"
done
/usr/bin/xcrun clang -target x86_64-pc-windows-msvc -O2 -Wall -Wextra -Werror -ffreestanding -fno-stack-protector -c mouse.c -o "$build/mouse.obj"
"$@" /nodefaultlib /entry:start /subsystem:console /machine:x64 /timestamp:0 "/out:$build/MouseLook.exe" "$build/mouse.obj" "$build/kernel32.lib" "$build/user32.lib"
/bin/cp "$build/MouseLook.exe" "$out"
