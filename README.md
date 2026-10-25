# odin-ui-v2

A native UI library in Odin for macOS and Linux: [Clay](https://github.com/nicbarker/clay) lays out, a small GPU renderer draws, and raylib provides the window, GL context and input. Clay is `e6cc369` (its current head) and raylib is master at `debc1f6` (6.5-dev), both vendored in `deps/` with their build scripts ([deps/raylib/README.md](deps/raylib/README.md)).

The demo app has three tabs under a top bar. **Graph** is a force-directed graph driven by its side panel. **Showcase** is a column of cards with every widget ([app/showcase.odin](app/showcase.odin)). **Design** edits the look and feel live and saves it as a design file (see [Designs](#designs)).

```bash
./run.sh                  # build and run (Odin deletes the binary afterwards)
./run.sh --showcase       # start on the Showcase tab (--lab: the Design tab)
./run.sh --bench          # a scripted session, then the frame timing report
./build.sh                # optimized standalone binary: ./graph
./build.sh debug          # with symbols, for gdb/lldb: ./graph-debug
```

[app/main.odin](app/main.odin) lists every flag. The fonts, raylib and GLFW are built into the binary, so `./graph` runs from any directory; on Linux it links dynamically only against libc, `libX11` and `libwayland-client`.

Use Odin's [official release](https://github.com/odin-lang/Odin/releases) (built with `dev-2026-10`). Text uses Odin's `vendor:stb/truetype`, which ships prebuilt for macOS; on Linux build it once with `make -C "$(odin root)/vendor/stb/src"`. Arch's `odin` package ships `vendor/` libraries as Git LFS pointer files, which don't link.

On the Graph tab: drag a node; **Link**, then click another node to tie it to the selection. **N** adds a node, **delete** removes the selection, **space** pauses, **F** is fullscreen, **esc** quits, **F3** hides the debug strip. **Ctrl +/−/0** zooms the UI from 50% to 200% (**Cmd** on macOS); zooming in stops before the layout gets smaller than the minimum window.

## The loop

The app owns the loop:

```odin
ui.init(desc)
for ui.frame() {
	ui.begin_layout()
	// widgets
	cmds := ui.end_layout()
	ui.begin_draw()
	// host drawing (ui.draw_*), optionally clipped to an element
	ui.render(&cmds)
	ui.end_draw()
}
ui.shutdown()
```

`frame` waits for the frame's slot, then polls input, so a frame draws input as fresh as the wait allows. `Window_Desc.target_fps` 0 is 120 (`ui.DEFAULT_FPS`): a 60 Hz display runs at 60 and a faster one is held to 120; -1 follows the display at any rate.

## macOS

raylib on its own misses fast trackpad clicks, blurs fullscreen on Retina, and does not lock to ProMotion. [ui/macos_darwin.odin](ui/macos_darwin.odin) patches those without forking raylib:

- An `NSEvent` monitor records every mouse and key edge, then hands the event to GLFW unchanged. raylib compares key state between polls, so a tap that starts and ends inside one frame would never read as pressed.
- Fullscreen is `[NSWindow toggleFullScreen:]`, which keeps the 2x backing store; raylib's `ToggleFullscreen` drops it to 1x.
- The clock is the window view's display link (`NSView.displayLink`, macOS 14+), on its own thread, with the swap interval off. A cap below the display's rate waits N ticks. `end_draw` swaps with `SwapScreenBuffer`, not `EndDrawing`, which would poll a second time and eat raylib's key-press edges.
- Fullscreen on an adaptive-refresh screen (ProMotion) runs on a fixed deadline grid instead: the panel refreshes when a frame lands, so the display link reports our own presents back. The frame wakes just early enough for its recent peak work, draws, sleeps to the deadline with `mach_wait_until` on a time-constrained thread, then swaps. Before macOS 14 the grid is the clock everywhere.

## Linux

GLFW uses its Wayland backend when `WAYLAND_DISPLAY` is set, and X11 otherwise; under X11 the loop is raylib's own, with vsync.

On Wayland the clock is the surface's frame callback ([ui/wayland_linux.odin](ui/wayland_linux.odin)), not EGL's vsync, which NVIDIA's `egl-wayland2` runs at half the refresh. `end_draw` requests a callback before the swap so the swap's commit carries it, and `frame` waits for it on its own event queue, giving up after 100 ms (a hidden window gets none). A `target_fps` below the refresh adds a deadline grid on top.

Fullscreen calls `glfwSetWindowMonitor` directly. raylib's `ToggleFullscreen` drops HiDPI there (Wayland cursor positions stay logical, so clicks landed at 0.8x of where they pointed at scale 1.25), and turns swap interval 1 back on, stacking the driver's wait on the callback's. Wayland gives no window position, so fullscreen uses the primary output.

## Rendering

Everything the UI draws goes through two small pipelines in one stream, one instanced quad per thing ([ui/shapes.odin](ui/shapes.odin)):

- **Shapes** are signed distance fields: the fragment shader works out how far each pixel is from the edge of a rounded box (each corner its own radius), a triangle or a line, and fades the coverage over one physical pixel. Edges are smooth at any zoom without multisampling. A border is the box minus the box inside its widths, so it follows the fill's curve with any width per side. Clay's boxes snap to the physical pixel grid, so straight edges are crisp; shapes a host draws don't, so they move smoothly.
- **Glyphs and images** are textured quads that only sample and tint.

A frame's quads go to the GPU in one upload per pipeline, with a new draw call only where the pipeline, the clip or the texture changes. Clay's overlays (fades) and clips are the stream's state, so everything inside a fading or clipped element follows.

Hosts draw with `ui.draw_circle`, `draw_ring`, `draw_line`, `draw_triangle` and `draw_gradient_pill`, in layout units. raylib's own `rl.*` drawing still works but is a separate batch: call `ui.flush_shapes()` before an `rl.*` call that must land on top of `ui.draw_*` output. A Custom element ([ui/component.odin](ui/component.odin)) draws whatever a host's `ui.Custom_Draw` proc draws, in its box and Clay's order, with the shapes before it already drawn.

Text is drawn from a glyph cache ([ui/glyphs.odin](ui/glyphs.odin)): stb_truetype rasterizes each glyph the first time it's drawn, at its pixel size (`fontSize * display scale * zoom`), into 1024² atlas pages, drawn without mipmaps on the pixel grid. A character the font lacks comes from a fallback font sized to the same em: ones added with `ui.add_fallback_font`, then system fonts (STIX, Apple Symbols, Arial Unicode and Hiragino on macOS; DejaVu and Noto on Linux). There is no shaping (ligatures, Arabic) and no color emoji.

## Idle

With `Window_Desc.idle_after` (seconds), `ui.frame` stops returning while nothing on screen would change, so the app neither lays out nor draws and the GPU rests ([ui/idle.odin](ui/idle.odin)). A frame is drawn on input or a size change; when the pointer moves onto another element or across a hover zone (`ui.hover_zone`); while a spring, a scroll's easing or a theme fade moves; for `idle_after` seconds after the last of those (Clay's transitions finish in that time); when the app calls `ui.request_redraw()` (text streaming in) or `ui.wake_at` / `ui.wake_in` (a caret's next blink); and at least once a second. `UI_IDLE_DEBUG=1` prints every two seconds how many ticks drew and why.

## Frame timing

The frame loop times itself, with nothing for the app to add ([ui/perf.odin](ui/perf.odin)), against a budget of 120 fps on any display (`ui.PERF_BUDGET_MS`): the CPU and the GPU each get 8.33 ms, since they work side by side.

| Part | From, to |
| --- | --- |
| Tick | `frame` returning to `begin_layout`: the app's own logic |
| Layout | `begin_layout` to `end_layout`: building the UI and Clay's layout |
| Draw | `begin_draw` to the last draw call: host drawing, `render`, the upload |
| CPU | `frame` returning to the last draw call: all of the above |
| GPU | the frame's draw calls, from timer queries read three frames late, so reading never stalls; from `ui.perf_gpu_begin()` on, when the app does GPU work before `begin_draw` (a simulation, render-to-texture) |
| Swap | `end_draw`'s present wait and swap: mostly waiting, not budgeted |
| Frame | one frame to the next |

`ui.debug_strip()` (F3) shows the last 120 frames' average and worst of each part, CPU and GPU in green, amber past half the budget, red over it; `ui.perf_stats()` returns the same numbers. A benchmark: `ui.perf_bench_start(warmup)`, a scripted session (`ui.perf_bench_frames()` says how far it is), then `ui.perf_report(title)`, which prints avg, p50, p99 and worst per part and returns false when CPU or GPU p99 is over budget.

## Themes

`ui.theme` is a `Palette` (colors), `Metrics` (shape and spacing), `Typography` (text sizes per role) and `Motion` ([ui/theme.odin](ui/theme.odin)). Widgets read its tokens as they build, so a changed token shows next frame; `ui.set_palette(p, fade)` swaps all colors, cross-faded.

A palette usually comes from a `Theme_Base`: mode, background, foreground, accent, and optionally surface, border, text on the accent, and status colors. `ui.palette_from_base` mixes the rest, with contrast floors so low-contrast themes stay readable (dim text at least 3.5:1, text on the accent 4.5:1 where black or white can reach it). Hover lifts a control toward the text color. Built in: `BASE_DARK` and `BASE_LIGHT`.

Two optional packages follow the system's theme; the library core imports neither, and each compiles to a no-op on the other platform:

- `ui/omarchy` follows the active [Omarchy](https://omarchy.org) theme on Linux: it reads `colors.toml` from Omarchy's current theme and notices `omarchy theme set` by polling twice a second.
- `ui/appearance` follows macOS: AppKit's system colors under the app's appearance (window background, label text, separator, the accent from System Settings, AppKit's white for text on the accent), re-read every 250 ms. `appearance.match_window` pins the title bar to a mode, or back to the system's with nil.

The demo follows Omarchy when it's installed, the macOS appearance on a Mac, and the design's dark colors otherwise; `--theme=omarchy|system|dark|light` picks at startup.

## Designs

A design is the whole look and feel in one file ([ui/design.odin](ui/design.odin)): a font and size for each text role (title, heading, body, small, mono), corner radii, padding, gaps and control sizes, motion, and colors for dark and light. Another project loads it:

```odin
ui.register_font("Inter-Medium", #load("fonts/Inter-Medium.ttf"))
d, ok := ui.load_design("look.toml")      // or ui.parse_design(string(#load("look.toml")))
defer ui.design_destroy(&d)
ui.apply_design(d, .Dark)                 // nil keeps the current colors (system themes)
```

The file is a small TOML subset ([designs/console.toml](designs/console.toml)):

- `[type]`: `font_<role>` is a name given to `ui.register_font`, or a path to a .ttf/.otf relative to the design file; an unknown font falls back to the first one registered. `size_<role>` is in points.
- `[shape]`: `Metrics`. `[motion]`: durations in seconds, bounce, and press depth.
- `[dark]` and `[light]`: a `Theme_Base`. Background, foreground and accent are required; the rest is derived unless given. `[dark.palette]` and `[light.palette]` set single palette fields after the derivation.

Keys a file leaves out keep the built-in value; unknown keys are reported and skipped. Struct tags on the token fields (`range`, `label`, `unit`) drive both the file format and the Design tab, so a new token shows up in both without further code.

The **Design** tab edits a design live next to the showcase: colors (base or single palette fields, with an HSB picker), a font and size for each role, and every shape and motion token. It saves to `designs/` and reloads a file changed on disk, so a text editor works too. Three designs show the range: `console` (the default: sharp, dark blue), `soft` (rounded, lavender, springy) and `compact` (dense, green, quick). Fonts dropped into `fonts/` show up in the font menus; a design refers to such a font by path, so ship it with the design.

### Motion

Widgets animate through `ui.anim(id, target, duration, bounce)`, a spring per widget id and channel ([ui/anim.odin](ui/anim.odin)). A spring retargeted mid-flight turns around from where it is instead of restarting, so sweeping the pointer over a row of buttons stays smooth.

- **Hover** eases each control toward its hover color; **press** darkens it by the press depth. `ui.feedback` does both, for your own components too.
- **Change** slides the segmented control's pill, the tab bar's underline, and the switch's and slider's knobs, with the design's bounce.
- **Enter** fades and drops menus in, and cross-fades palettes.
- **Scroll** smooths the wheel: Clay's scroll position becomes the target, and the container eases toward it.

`Button_Opts.force` shows a hover or press state without the pointer, for specimens.

## Text fields

`ui.text_edit(id, &state, opts)` is a text field, one line or many (`multiline`, growing to `lines` before it scrolls) ([ui/edit.odin](ui/edit.odin)). The host owns the `ui.Text_Edit` and reads it with `ui.edit_text`; the result says whether the text changed, Enter submitted it, or Escape cancelled.

- **Keys** follow the platform: on macOS Option moves by word and Cmd by line, elsewhere Ctrl by word and Home/End by line. Cmd (Ctrl) with A, C, X, V and Z selects all, copies, cuts, pastes and undoes; Shift+Cmd+Z (Ctrl+Y) redoes, a word of typing at a time.
- **The pointer** places the caret, drags a selection, double-clicks a word and triple-clicks a line.
- **Focus**: one field has the keyboard. `ui.focus(id)` and `ui.blur()` set it from code, and `ui.editing()` tells the host to keep bare-key shortcuts out of the way while someone types.

## Rich text

`ui.rich_text(id, spans, opts)` is a paragraph of spans in different styles, wrapped together as one text ([ui/rich.odin](ui/rich.odin)): each `ui.Span` has its text and a `Span_Style` (font slot, size, color, a rounded box behind it, underline, strikethrough, a link id). Baselines line up across fonts, a span with a box (inline code) takes room on either side, and a word too wide for the line breaks between characters. `opts.align` centers or right-aligns; `opts.nowrap` breaks only at newlines. The result has the height, and the link under the pointer and the one clicked.

Paragraphs are selectable together: a drag selects across paragraphs in the order they were declared, a double click takes a word, a triple click a paragraph, Shift+click extends. Cmd+C (Ctrl+C) copies, paragraphs joined by newlines; `ui.rich_selection()` gives the text to the host, and `opts.unselectable` leaves decoration (list markers) out. A layout is kept per id while the text, fonts, sizes and width stay the same. Italic and bold are font slots of their own.

## Layout

```
ui/            widgets, the frame loop, the renderer, text, themes, designs, animation, macOS and Wayland hooks
ui/omarchy/    optional: follow the active Omarchy theme (Linux)
ui/appearance/ optional: follow the system appearance and accent (macOS)
app/           the demo: graph, showcase, design editor, --bench
designs/       console (the default), soft, compact
deps/clay/     Clay bindings + static libs, and their build script
deps/raylib/   raylib bindings + static libs, and their build script
fonts/         Inter and JetBrains Mono; other fonts dropped in stay local
```

## License

MIT, see [LICENSE](LICENSE). Bundled third-party pieces keep their own licenses: Clay and raylib are zlib ([deps/clay/LICENSE.md](deps/clay/LICENSE.md), [deps/raylib/LICENSE.md](deps/raylib/LICENSE.md)), and [Inter](https://github.com/rsms/inter) and [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) are SIL OFL 1.1, with their licenses in [fonts/](fonts). The JetBrains Mono file is the Regular instance of its variable font, cut with `fonttools varLib.instancer`, since only a variable font's default instance is drawn.
