# raylib

Odin bindings for raylib master at `debc1f6` (6.5-dev, after the 6.2 release), with our own static builds for macOS (universal) and Linux x86_64 (X11 + Wayland).

## Why this is vendored

For native Wayland. The Linux raylib that ships with Odin (`vendor:raylib`) has only GLFW's X11 backend, so on Wayland it runs through XWayland, without fractional-scale HiDPI. Odin hardcodes that library's path in `vendor:raylib` and reserves the `vendor` collection name, so the bindings are copied here, as Clay's are, and `ui/` imports `../deps/raylib`.

## What's here

| Path | What |
| --- | --- |
| `raylib.odin`, `rlgl/rlgl.odin` | Started as Odin `dev-2026-09` `vendor/raylib` (raylib 6.0), brought up to `debc1f6` by hand. The `foreign import` blocks are ours. |
| `macos/libraylib.a` | Universal (arm64 + x86_64), macOS 11+. |
| `linux/libraylib.a` | x86_64, GLFW's X11 and Wayland backends, picked at runtime. **Still raylib 6.0**: run `build.sh` on Linux. Until then, the functions changed since 6.0 are wrong there; none that `ui/` calls. |
| `build.sh` | Builds this platform's library from the pinned commit. |

Linux links `dl`, `pthread`, `m` and `X11` (raylib's clipboard-image code calls Xlib); GLFW dlopens the Wayland libraries and EGL at runtime. macOS links Cocoa, OpenGL, IOKit, and QuartzCore (GLFW after raylib 6.0 makes a `CAMetalLayer`).

## Checking the bindings

To move to another raylib commit: change `COMMIT` in `build.sh`, rebuild on both platforms, then diff the bindings against the new headers with raylib's own parser (`tools/rlparser` in its repo):

```
rlparser -i raylib.h -o raylib.json -f JSON -d RLAPI
rlparser -i rlgl.h -o rlgl.json -f JSON -d RLAPI -t "RLGL IMPLEMENTATION"
```

Compare every function both ways (new ones to bind, bound ones that are gone, parameter types), and check that every bound function exists in the built library (`nm -gU macos/libraylib.a`). Parameters typed as Odin enums or `rune` where C says `int` are the same ABI. The camera functions come from `rcamera.h`, which the parser doesn't read.

## Current build

```
macos/libraylib.a
  raylib 6.5-dev, commit debc1f6b1f86ca12119824f15974758d2d875394
  Apple clang 21.0.0, macOS 26 on Apple M5, x86_64 + arm64, minos 11.0
  sha256 48329af56d95744151fecad6ab0c8448f0899f68cd1b24f49b38b7ce6ce87974

linux/libraylib.a (to rebuild)
  raylib 6.0, commit dbc56a87da87d973a9c5baa4e7438a9d20121d28
  gcc 16.2.1, Arch Linux
  sha256 86395a7d58b948b3d6190e93cc8206351ae6c6acca652988bc3f63bf51bb5cb4
```
