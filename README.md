# odin-ui-v2

Clay layout, raylib drawing, one window loop. Raylib is 6.0: the Odin compiler's bindings, vendored in `deps/raylib` with a Linux build that runs natively on Wayland (see [deps/raylib/README.md](deps/raylib/README.md)). Clay is the bindings and static lib from [nicbarker/clay](https://github.com/nicbarker/clay) `e6cc369`.

The first app is a force-directed graph: nodes repel, edges are springs, a weak pull keeps the cloud on the canvas. The panel is there to drive the model.

```bash
./run.sh
```

Use Odin's [official release](https://github.com/odin-lang/Odin/releases) (built and tested with `dev-2026-09`). Arch's `odin` package ships `vendor/` libraries as Git LFS pointer files, and macOS and Windows link raylib from the compiler.

Drag a node. **Link** then click another node to tie it to the selection. **N** adds a node, **delete** removes the selection, **space** pauses, **F** is fullscreen, **esc** quits. **F3** hides the timing strip.

## macOS

Raylib on its own misses fast trackpad clicks, blurs fullscreen on Retina, and does not lock to ProMotion. This package patches those without forking raylib:

- An `NSEvent` monitor records every mouse and key edge, then hands the event to GLFW unchanged. Raylib compares key state between polls, so a tap that starts and ends inside one frame never reads as pressed; the monitor keeps it.
- Fullscreen is `[NSWindow toggleFullScreen:]`, so the 2x backing store stays. `ToggleFullscreen` is the path that drops the scale to 1x.
- Swap interval stays off. The window view's display link (`NSView.displayLink`, macOS 14+) runs on its own thread; each tick bumps a counter and signals a semaphore, and the frame blocks until the counter has moved. `target_fps` 0 follows the display. A lower cap waits N ticks (60 on a 120 Hz panel is every second tick). The graph asks for 60.
- Input is polled after the wait, not right after the swap, so a frame draws input that is ~1 ms old instead of a frame old. On macOS `end_draw` swaps with `SwapScreenBuffer` instead of `EndDrawing`, which would poll a second time and eat raylib's key-press edges.
- Fullscreen on an adaptive-refresh screen (ProMotion, adaptive sync) runs on a fixed deadline grid instead. The panel scans out directly and refreshes when a frame lands, which made `CVDisplayLink` report our own presents back (ticks 2–11 ms apart). The frame wakes just early enough for its recent peak work, polls, draws, flushes, sleeps to the deadline with `mach_wait_until`, then swaps. The thread is time-constrained in that mode; without it the wake is ~1 ms late and jittery. Swap-to-swap spread at 60 went from ~10 ms to 0.03 ms. Before macOS 14 there is no view link and the grid is the clock everywhere.

## Linux (Wayland)

GLFW uses its Wayland backend when `WAYLAND_DISPLAY` is set, and X11 otherwise. Under X11 the loop is plain raylib with vsync.

On Wayland the frame clock is the surface's frame callback, not EGL's vsync ([ui/wayland_linux.odin](ui/wayland_linux.odin)). Swap interval is 0. `end_draw` requests a callback before the swap so the swap's commit carries it. `frame` waits for the callback on its own event queue, then polls input. A hidden window gets no callbacks, so the wait gives up after 100 ms. A `target_fps` below the refresh adds a deadline grid on top.

Fullscreen (F) on Wayland calls `glfwSetWindowMonitor` directly, not raylib's `ToggleFullscreen`, for two reasons:

- raylib's fullscreen mode drops HiDPI. It sets the screen size to the physical framebuffer and the mouse scale to 1, but Wayland cursor positions stay logical. At scale 1.25 every click landed at 0.8x of where it pointed. raylib's Wayland correction is behind `#if defined(_GLFW_WAYLAND) && !defined(_GLFW_X11)`, so it is compiled out of an X11 + Wayland build. Leaving raylib's fullscreen flag off keeps it on the windowed HiDPI path, the same as Hyprland's own fullscreen (SUPER+F).
- `ToggleFullscreen` turns swap interval 1 back on while raylib's `VSYNC_HINT` flag is set. That stacked the driver's wait on the callback wait, and fullscreen swung between 30 and 50+ fps. The Wayland path also clears that flag at startup.

Wayland gives no window position, so F fullscreens on the primary output.

EGL's vsync is not used because NVIDIA's `egl-wayland2` runs swap interval 1 at half the refresh on Hyprland. The same loop with the older `egl-wayland`, or under XWayland, holds the full rate. `tools/vsync_probe` measures it:

```
odin run tools/vsync_probe
```

| Setup | vsync probe |
| --- | --- |
| native Wayland, `egl-wayland2` (default) | 30.3 fps |
| native Wayland, `egl-wayland` (`__EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES=/usr/share/egl/egl_external_platform.d/10_nvidia_wayland.json`) | 60.6 fps |
| XWayland (`env -u WAYLAND_DISPLAY`) | 60.7 fps |
| the app, frame-callback clock | 60 fps, 16.67 ms frames |

Measured 2026-09-26 on a 60 Hz 3840x2160 output at scale 1.25 with:

- `egl-wayland2` 1.0.2-1 (`libnvidia-egl-wayland2.so.1`, `09_nvidia_wayland2.json`, picked first)
- `egl-wayland` 1.1.22-1
- `nvidia-open-dkms` / `nvidia-utils` 610.57.04-1, RTX 4090
- Hyprland 0.56.2 (`efb5099`), `wayland` 1.26.0, `libglvnd` 1.7.0, `mesa` 26.2.2
- kernel 7.2.5-3-omarchy (Arch)

Once the probe shows the full refresh with the default stack, EGL vsync would work again. The frame-callback clock is still the Wayland-native clock and gives input one frame less latency, so there is no need to switch back.

Glyphs are rasterized at `fontSize * dpi` and drawn with bilinear filtering and no mipmaps, snapped to the physical pixel grid. Trilinear filtering is what softens raylib text. The atlas holds ASCII, Latin-1, and common UI punctuation and symbols; a codepoint the font file lacks draws as `?`.

UI fills are rlgl triangles on a 1×1 white texture, which is also raylib's shapes texture, with rounded corners as triangle fans. Plain `DrawRectangle` and friends work too; rlgl turns quads into triangles on this GL 4.1 context.

## Layout

```
ui/            Clay widgets, the frame loop, the raylib renderer, macOS and Wayland hooks
app/           the graph
deps/clay/     Clay bindings + built static libs
deps/raylib/   raylib bindings + the Linux static lib and its build script
tools/         vsync_probe
fonts/
```

The app owns the loop (`ui.init`, `for ui.frame()`, `ui.shutdown`). Widgets read an input snapshot and emit Clay. They do not call raylib. The graph does, in the canvas region, before `ui.render` paints the panel on top.

## License

MIT, see [LICENSE](LICENSE). Bundled third-party pieces keep their own licenses: Clay is zlib ([deps/clay/LICENSE.md](deps/clay/LICENSE.md)), and the [Inter](https://github.com/rsms/inter) font is SIL OFL 1.1 ([fonts/Inter-LICENSE.txt](fonts/Inter-LICENSE.txt)). raylib is zlib ([deps/raylib/LICENSE.md](deps/raylib/LICENSE.md)).
