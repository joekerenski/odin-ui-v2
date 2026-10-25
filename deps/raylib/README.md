# raylib

Odin bindings for raylib master at `debc1f6` (6.5-dev, 45 commits after the 6.2 release), with our own static builds for Linux (X11 + Wayland) and macOS (universal).

## Why this is vendored

For native Wayland. The Linux raylib that ships with Odin (`vendor:raylib`, raylib's release build) has only GLFW's X11 backend: it exports `glfwGetX11Display` and no Wayland functions. On Wayland it runs through XWayland, without fractional-scale HiDPI. A native Wayland window needs raylib built with the Wayland backend.

Odin hardcodes that library's path in `vendor:raylib` and reserves the `vendor` collection name, so the bindings are copied here, as Clay's are, and the app imports `../deps/raylib`.

Use Odin's official release. Arch's `odin` package (`dev_2026_09-1`) ships every Git LFS file under `vendor/` as a 132-byte pointer file instead of the library, so its `vendor:raylib` doesn't link at all. Windows still links the compiler's lib, so it needs the real file.

## What's here

| Path | What |
| --- | --- |
| `raylib.odin`, `raymath.odin`, `easings.odin`, `rlgl/rlgl.odin` | Started as a copy of Odin `dev-2026-09:a2fb372b7` `vendor/raylib` (raylib 6.0), brought up to `debc1f6` by hand (see below). The `foreign import` blocks are ours. `raygui` is left out. |
| `linux/libraylib.a` | **Still raylib 6.0.** Rebuild it with `build_linux.sh` on Linux; until then, the functions changed since 6.0 are wrong there (below). |
| `linux-arm64/libraylib.a` | Not built yet. Run `build_linux.sh` on an arm64 Linux machine. |
| `macos/libraylib.a` | raylib `debc1f6` static lib, universal (arm64 + x86_64), macOS 11+, built by `build_macos.sh`. |
| `build_linux.sh` | Builds the Linux lib for the host arch (`linux/` or `linux-arm64/`). |
| `build_macos.sh` | Builds the macOS lib. |
| `LICENSE.md` | raylib's zlib license. |

The changed `foreign import` blocks:

- **Linux** links `linux/` or `linux-arm64/` by `ODIN_ARCH`, plus `dl`, `pthread`, `m`, and `X11`. GLFW dlopens the Wayland libraries (`wayland-client`, `wayland-cursor`, `wayland-egl`, `xkbcommon`) and EGL/GL at runtime. `X11` is linked because raylib's clipboard-image code calls Xlib directly. There is no fallback to the compiler's lib: `ui/wayland_linux.odin` calls GLFW's Wayland functions, which an X11-only build doesn't have.
- **macOS** links `macos/libraylib.a` when it exists (`#exists`), and falls back to `vendor:raylib/macos/libraylib.a` from the compiler if it is deleted. It also links QuartzCore: the GLFW in raylib after 6.0 makes a `CAMetalLayer`.
- **Windows** links `vendor:raylib/windows/raylib.lib` from the compiler.

The compiler's libs are referenced as `vendor:raylib/...`. `foreign import` rejects absolute paths, so `ODIN_ROOT + "vendor/..."` does not work.

`odin check app -target:<t>` passes for `linux_amd64`, `linux_arm64`, `darwin_arm64`, `darwin_amd64` and `windows_amd64`. `linux_amd64`, `darwin_arm64` and `darwin_amd64` (under Rosetta) have been linked and run.

## Bindings against `debc1f6`

raylib's own header parser (`tools/rlparser`) describes every function, struct and enum of `raylib.h`, `rlgl.h` and `raymath.h`. The bindings were diffed against that, both ways, and every bound function was checked to exist in the built library (`nm`). Changed since 6.0:

- **Added:** `IsFileHidden`, `IsPathDirectory`, `IsPathAbsolute`, `GetGestureDetected`, `DrawTriangleGradient`, `DrawTriangleLinesEx`, `DrawCircleLinesEx`, `DrawCircleSectorLinesEx`, `DrawEllipseLinesEx`, `DrawRingLinesEx`, `ImageDrawLineStrip`, `ImageDrawCircleGradient`, `ImageDrawRectanglePro`, `ImageDrawRectangleGradientEx`, `ImageDrawRectangleLinesEx`, `ImageDrawImage`, `ImageDrawImageEx`, `ImageDrawImageRec`, `ImageDrawImagePro`, `ImageDrawTextPro`, `LoadRenderTextureEx`. rlgl: `GetActiveFramebuffer`, `BindFramebuffer`, `CopyFramebuffer`, `ResizeFramebuffer`, `ColorMask`, `DisablePointMode`, `SetPointSize`, `GetPointSize`, `LoadShader`, `LoadShaderProgramEx`, `LoadShaderProgramCompute`, `SetUniformMatrices`.
- **Renamed:** `GetSplinePointBezierQuad` → `GetSplinePointBezierQuadratic`, `ImageDrawTriangleEx` → `ImageDrawTriangleGradient`, `ImageDraw` → `ImageDrawImagePro` (which also takes an origin and rotation). rlgl: `LoadComputeShaderProgram` → `LoadShaderProgramCompute`; `LoadShaderCode` is gone, and `LoadShaderProgram` now takes the two code strings (it took two shader ids, which is `LoadShaderProgramEx` now); `CompileShader` → `LoadShader`.
- **Changed signatures:** `ImageDrawRectangleLines` takes x, y, width, height (the rectangle and thickness form is `ImageDrawRectangleLinesEx`), `ImageColorContrast` takes an int, `ChangeDirectory` returns 0 on success, `DecodeDataBase64` takes a string and returns bytes, `ColorIsEqual` returns its bool (the 6.0 binding dropped it). rlgl: `Frustum`, `Ortho`, `SetClipPlanes` and the cull distances are `f32` (raylib dropped doubles), `LoadTextureCubemap` takes a mipmap count, `CheckRenderBatchLimit` returns bool, `CubemapParameters` takes an unsigned id, and `VertexBuffer` has `normals` and five VBO ids.

Not differences: the camera functions come from `rcamera.h`, which the parser doesn't read, and they are in the library; `TextFormat` is written in Odin; parameters typed as Odin enums or `rune` where C says `int` are the same ABI. `raymath.odin` is Odin's own port, not a binding, so nothing links against it; it lacks raymath's newer helpers (mostly `Vector4*`, which Odin's array arithmetic covers).

## Current build

```
macos/libraylib.a
  raylib 6.5-dev, commit debc1f6b1f86ca12119824f15974758d2d875394
  make PLATFORM=PLATFORM_DESKTOP RAYLIB_LIBTYPE=STATIC RAYLIB_BUILD_MODE=RELEASE
       CUSTOM_CFLAGS="-arch <arch> -mmacosx-version-min=11.0", per arch, then lipo
  x86_64 + arm64, minos 11.0
  Apple clang 21.0.0 (clang-2100.1.1.101), macOS 26 on Apple M5
  sha256 48329af56d95744151fecad6ab0c8448f0899f68cd1b24f49b38b7ce6ce87974

linux/libraylib.a (to rebuild on Linux with build_linux.sh)
  raylib 6.0, commit dbc56a87da87d973a9c5baa4e7438a9d20121d28
  make PLATFORM=PLATFORM_DESKTOP RAYLIB_LIBTYPE=STATIC RAYLIB_BUILD_MODE=RELEASE
       GLFW_LINUX_ENABLE_X11=TRUE GLFW_LINUX_ENABLE_WAYLAND=TRUE
  gcc 16.2.1 20260810, Arch Linux
  sha256 86395a7d58b948b3d6190e93cc8206351ae6c6acca652988bc3f63bf51bb5cb4
```

To move to a newer raylib, update `VERSION`/`COMMIT` in both scripts, rebuild, and diff the bindings against the new headers as above (generate the JSON with `rlparser -i raylib.h -f JSON -d RLAPI`, and the same for `rlgl.h` with `-t "RLGL IMPLEMENTATION"` and `raymath.h` with `-d RMAPI`).
