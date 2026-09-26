# raylib

Odin bindings for raylib 6.0, with our own static builds for Linux (X11 + Wayland) and macOS (universal).

## Why this is vendored

For native Wayland. The Linux raylib that ships with Odin (`vendor:raylib`, raylib's release build) has only GLFW's X11 backend: it exports `glfwGetX11Display` and no Wayland functions. On Wayland it runs through XWayland, without fractional-scale HiDPI. A native Wayland window needs raylib built with the Wayland backend.

Odin hardcodes that library's path in `vendor:raylib` and reserves the `vendor` collection name, so the bindings are copied here, as Clay's are, and the app imports `../deps/raylib`.

Use Odin's official release. Arch's `odin` package (`dev_2026_09-1`) ships every Git LFS file under `vendor/` as a 132-byte pointer file instead of the library, so its `vendor:raylib` doesn't link at all. Windows still links the compiler's lib, so it needs the real file.

## What's here

| Path | What |
| --- | --- |
| `raylib.odin`, `raymath.odin`, `easings.odin`, `rlgl/rlgl.odin` | Copied whole from Odin `dev-2026-09:a2fb372b7` `vendor/raylib`, the full API. Only the `foreign import` blocks changed (see below). `raygui` is left out. |
| `linux/libraylib.a` | raylib 6.0 static lib, x86_64, X11 + Wayland, built by `build_linux.sh`. |
| `linux-arm64/libraylib.a` | Not built yet. Run `build_linux.sh` on an arm64 Linux machine. |
| `macos/libraylib.a` | raylib 6.0 static lib, universal (arm64 + x86_64), macOS 11+, built by `build_macos.sh`. |
| `build_linux.sh` | Builds the Linux lib for the host arch (`linux/` or `linux-arm64/`). |
| `build_macos.sh` | Builds the macOS lib. |
| `LICENSE.md` | raylib's zlib license. |

The changed `foreign import` blocks:

- **Linux** links `linux/` or `linux-arm64/` by `ODIN_ARCH`, plus `dl`, `pthread`, `m`, and `X11`. GLFW dlopens the Wayland libraries (`wayland-client`, `wayland-cursor`, `wayland-egl`, `xkbcommon`) and EGL/GL at runtime. `X11` is linked because raylib's clipboard-image code calls Xlib directly. There is no fallback to the compiler's lib: `ui/wayland_linux.odin` calls GLFW's Wayland functions, which an X11-only build doesn't have.
- **macOS** links `macos/libraylib.a` when it exists (`#exists`), and falls back to `vendor:raylib/macos/libraylib.a` from the compiler if it is deleted.
- **Windows** links `vendor:raylib/windows/raylib.lib` from the compiler.

The compiler's libs are referenced as `vendor:raylib/...`. `foreign import` rejects absolute paths, so `ODIN_ROOT + "vendor/..."` does not work.

`odin check app -target:<t>` passes for `linux_amd64`, `linux_arm64`, `darwin_arm64`, `darwin_amd64` and `windows_amd64`. `linux_amd64`, `darwin_arm64` and `darwin_amd64` (under Rosetta) have been linked and run.

## Current build

```
linux/libraylib.a
  raylib 6.0, commit dbc56a87da87d973a9c5baa4e7438a9d20121d28
  make PLATFORM=PLATFORM_DESKTOP RAYLIB_LIBTYPE=STATIC RAYLIB_BUILD_MODE=RELEASE
       GLFW_LINUX_ENABLE_X11=TRUE GLFW_LINUX_ENABLE_WAYLAND=TRUE
  gcc 16.2.1 20260810, Arch Linux
  sha256 86395a7d58b948b3d6190e93cc8206351ae6c6acca652988bc3f63bf51bb5cb4

macos/libraylib.a
  raylib 6.0, commit dbc56a87da87d973a9c5baa4e7438a9d20121d28
  make PLATFORM=PLATFORM_DESKTOP RAYLIB_LIBTYPE=STATIC RAYLIB_BUILD_MODE=RELEASE
       CUSTOM_CFLAGS="-arch <arch> -mmacosx-version-min=11.0", per arch, then lipo
  x86_64 + arm64, minos 11.0
  Apple clang 21.0.0 (clang-2100.1.1.101), macOS SDK 26.5, macOS 26 on Apple M5
  sha256 f8100c33ea9d639568809fcb0c149cf69f3f27e72ad64f21442d1be19811dcb0
```

To move to a newer raylib, update `TAG`/`COMMIT` in both scripts, copy the matching bindings from the Odin compiler, reapply the `foreign import` change, and update this file.
