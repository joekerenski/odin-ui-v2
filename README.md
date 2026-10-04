# odin-ui-v2

Clay layout, raylib drawing, one window loop. Raylib is 6.0: the Odin compiler's bindings, vendored in `deps/raylib` with a Linux build that runs natively on Wayland (see [deps/raylib/README.md](deps/raylib/README.md)). Clay is the bindings and static lib from [nicbarker/clay](https://github.com/nicbarker/clay) `e6cc369`.

The app has three tabs under a top bar. **Graph** is a force-directed graph: nodes repel, edges are springs, a weak pull keeps the cloud on the canvas, and the side panel drives the model. **Showcase** is a scrollable column of cards with every widget, a place to try things out ([app/showcase.odin](app/showcase.odin)); `./run.sh --showcase` starts there. **Design** edits the look and feel live and saves it as a design file (see [Designs](#designs)); `./run.sh --lab` starts there.

```bash
./run.sh              # build and run (Odin deletes the binary afterwards)
./build.sh            # optimized standalone binary: ./graph
./build.sh debug      # with symbols, for gdb/lldb: ./graph-debug
```

The font, raylib and GLFW are built into the binary, so `./graph` runs from any directory. On Linux it links dynamically only against libc, `libX11` and `libwayland-client`, which any desktop has.

Use Odin's [official release](https://github.com/odin-lang/Odin/releases) (built and tested with `dev-2026-09`). Text uses Odin's `vendor:stb/truetype`, whose library ships prebuilt for macOS and Windows; on Linux build it once with `make -C "$(odin root)/vendor/stb/src"`. Arch's `odin` package ships `vendor/` libraries as Git LFS pointer files, and Windows links raylib from the compiler.

On the Graph tab: drag a node. **Link** then click another node to tie it to the selection. **N** adds a node, **delete** removes the selection, **space** pauses, **F** is fullscreen, **esc** quits. **F3** hides the timing strip. **Ctrl +/−/0** zooms the UI from 50% to 200% (**Cmd** on macOS); zooming in stops before the layout gets smaller than the 720×480 minimum window.

## macOS

Raylib on its own misses fast trackpad clicks, blurs fullscreen on Retina, and does not lock to ProMotion. This package patches those without forking raylib:

- An `NSEvent` monitor records every mouse and key edge, then hands the event to GLFW unchanged. Raylib compares key state between polls, so a tap that starts and ends inside one frame never reads as pressed; the monitor keeps it.
- Fullscreen is `[NSWindow toggleFullScreen:]`, so the 2x backing store stays. `ToggleFullscreen` is the path that drops the scale to 1x.
- Swap interval stays off. The window view's display link (`NSView.displayLink`, macOS 14+) runs on its own thread; each tick bumps a counter and signals a semaphore, and the frame blocks until the counter has moved. `target_fps` 0 follows the display. A lower cap waits N ticks (60 on a 120 Hz panel is every second tick). The graph asks for 60.
- Input is polled after the wait, not right after the swap, so a frame draws input that is ~1 ms old instead of a frame old. On macOS `end_draw` swaps with `SwapScreenBuffer` instead of `EndDrawing`, which would poll a second time and eat raylib's key-press edges.
- Fullscreen on an adaptive-refresh screen (ProMotion, adaptive sync) runs on a fixed deadline grid instead. The panel scans out directly and refreshes when a frame lands, which made `CVDisplayLink` report our own presents back (ticks 2–11 ms apart). The frame wakes just early enough for its recent peak work, polls, draws, flushes, sleeps to the deadline with `mach_wait_until`, then swaps. The thread is time-constrained in that mode; without it the wake is ~1 ms late and jittery. Swap-to-swap spread at 60 went from ~10 ms to 0.03 ms. Before macOS 14 there is no view link and the grid is the clock everywhere.

## Idle

With `Window_Desc.idle_after` (seconds), `ui.frame` stops returning while nothing on screen would change, so the app neither lays out nor draws and the last frame stays up: the GPU rests. A frame is drawn on input (buttons, keys held or pressed, typed text, the wheel) or a size change; when the pointer moves onto another element or across a hover zone (`ui.hover_zone`, which rich text declares for its links), one frame per change, while moving within the same thing draws nothing; while a spring, a scroll's easing or a theme fade is moving; for `idle_after` seconds after the last of those (Clay's transitions finish in that time); when the app calls `ui.request_redraw()` (the next frame: text streaming in) or `ui.wake_at` / `ui.wake_in` (a later time: a text field asks for its caret's next blink, a pulse can run at 15 fps); and at least once a second. Drawing outside Clay follows the same rule: a still picture needs nothing, anything that moves on its own asks for its frames. Idle, the loop still wakes each display tick to look at input. `UI_IDLE_DEBUG=1` prints every two seconds how many ticks drew and why. An idle yapper with its composer focused draws about 2 frames a second.

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

Text is drawn from a glyph cache ([ui/glyphs.odin](ui/glyphs.odin)). Fonts are read with stb_truetype, and each glyph is rasterized the first time it is drawn, at `fontSize * dpi` pixels, into 1024² atlas pages. It is drawn with bilinear filtering and no mipmaps, snapped to the physical pixel grid; trilinear filtering is what softens raylib text. A character the font lacks comes from a fallback font, sized to the same em: ones added with `ui.add_fallback_font`, then system fonts (STIX for math, Greek and arrows, Apple Symbols, Arial Unicode, Hiragino for CJK on macOS; DejaVu and Noto on Linux). `ui.draw_glyph` draws by glyph id, for layouts that place glyphs themselves. There is no shaping: ligatures, Arabic and other scripts that need it draw character by character. Color emoji fonts aren't supported.

UI fills are rlgl triangles on a 1×1 white texture, which is also raylib's shapes texture, with rounded corners as triangle fans. Plain `DrawRectangle` and friends work too; rlgl turns quads into triangles on this GL 4.1 context.

The renderer sets the scissor only when something draws, and only when the box differs from the one in effect. A scissor change flushes raylib's batch, and every clipped floating element (a slider knob, a segment label) arrives as its own Clay root with its own scissor start and end. Setting them eagerly cost 4 ms a frame on the Design tab.

## Themes

`ui.theme` is a `Palette` (colors), `Metrics` (shape and spacing), `Typography` (text sizes per role) and `Motion`. Widgets read their colors through `styles`, derived from it. Change colors with `ui.set_palette(p, fade)`, which can cross-fade.

A palette usually comes from a `Theme_Base`: mode, background, foreground, accent, and optionally surface, border, text on the accent, and status colors. `ui.palette_from_base` mixes the rest from those, with contrast floors so low-contrast themes stay readable (dim text at least 3.5:1, text on the accent 4.5:1 where black or white can reach it, unless the base sets it). Hover lifts a control toward the text color. Built in: `BASE_DARK` and `BASE_LIGHT`.

`ui/omarchy` follows the active [Omarchy](https://omarchy.org) theme. It reads `~/.local/state/omarchy/current/theme/colors.toml` and notices `omarchy theme set` by polling `theme.name` twice a second. It is a separate package: the lib core never imports it, and outside Linux it compiles to a no-op. All of Omarchy's bundled themes map cleanly.

`ui/appearance` is the macOS counterpart. It reads AppKit's system colors under the app's effective appearance: window background, label text, separator, the accent picked in System Settings, and AppKit's white for text on the accent (4.0:1 on the default blue, which the 4.5:1 floor would otherwise turn black). Light/Dark and accent changes are noticed by re-reading the colors every 250 ms, since nothing in the loop receives the notification. `appearance.match_window` pins the title bar to a built-in palette's mode, or back to the system's with nil. Outside macOS it compiles to a no-op.

The demo app follows Omarchy when it is installed, the macOS appearance on a Mac, and the design's dark colors otherwise. The Showcase's Theme card switches between the system theme and the design's dark and light colors, and `--theme=omarchy|system|dark|light` picks one at startup.

## Designs

A design is the whole look and feel in one file: a font and size for each text role (title, heading, body, small, and mono for code), corner radii, padding, gaps and control sizes, motion, and colors for dark and light. Another project loads it:

```odin
ui.register_font("Inter-Medium", #load("fonts/Inter-Medium.ttf"))
d, ok := ui.load_design("look.toml")      // or ui.parse_design(string(#load("look.toml")))
defer ui.design_destroy(&d)
ui.apply_design(d, .Dark)                 // nil keeps the current colors (system themes)
```

The file is a small TOML subset ([designs/console.toml](designs/console.toml)):

- `[type]`: `font_<role>` is a name given to `ui.register_font`, or a path to a .ttf/.otf relative to the design file. An empty or unknown font falls back to the first one registered. `size_<role>` is in points.
- `[shape]`: `Metrics`.
- `[motion]`: durations in seconds, bounce, and press depth.
- `[dark]` and `[light]`: a `Theme_Base`. Background, foreground and accent are required; the rest is derived unless given.
- `[dark.palette]` and `[light.palette]`: optional palette fields set by hand, applied after the derivation.

Keys a file leaves out keep the built-in value, and unknown keys are reported and skipped. Struct tags on the token fields (`range`, `label`, `unit`) drive both the file format and the editor, so a token added to `Metrics`, `Typography` or `Motion` shows up in both without further code.

The **Design** tab edits a design live next to the showcase. It covers:

- colors, as base or single palette fields, with an HSB picker
- a font and a size for each role
- every shape and motion token

It saves to `designs/` next to the binary, and reloads the file when it changes on disk, so a text editor works too. Included: `console` (the default), `soft` and `compact`, and three serif reading designs for the yapper chat app, `yapper-ink` (Newsreader, warm), `yapper-night` (EB Garamond, cool) and `yapper-graphite` (Spectral, neutral). `--design=NAME` starts with one. Fonts in `fonts/` show up in the font menus. A design that uses one refers to it by path, so ship the font with the design. Only Inter is committed; `./fetch-fonts.sh` downloads the others from Google Fonts (curl, plus `fonttools` to cut static instances), and a design whose font is missing falls back to Inter.

### Motion

Widgets animate through `ui.anim(id, target, duration, bounce)`, a spring per widget id and channel, kept in a table because immediate-mode widgets have nowhere else to keep state. A spring retargeted mid-flight turns around from where it is, instead of restarting like a timed tween, so sweeping the pointer over a row of buttons stays smooth. Values nobody asks for during a frame are dropped.

- **Hover** eases each control toward its hover color. **Press** darkens it by the press depth. `ui.feedback` does both, for your own components too.
- **Change** slides the segmented control's pill, the tab bar's underline, the switch's knob and the slider's knob, with the design's bounce on things that move. The dropdown's chevron turns over too.
- **Enter** fades and drops menus in, and cross-fades palettes.
- **Scroll** smooths the wheel. Clay's scroll position becomes the target, and the container eases toward it.

`Button_Opts.force` shows a hover or press state without the pointer, for specimens like the Showcase's buttons card.

## Text fields

`ui.text_edit(id, &state, opts)` is a text field, one line or many (`multiline`, wrapping and growing to `lines` before it scrolls). The host owns the `ui.Text_Edit` and reads it back with `ui.edit_text`; the result says whether the text changed, Enter submitted it, or Escape cancelled.

- **Keys** follow the platform: on macOS Option moves by word and Cmd by line, elsewhere Ctrl by word and Home/End by line. Cmd (Ctrl) with A, C, X, V and Z selects all, copies, cuts, pastes and undoes; Shift+Cmd+Z (Ctrl+Y) redoes. Undo takes back a word of typing at a time.
- **The pointer** places the caret, drags a selection, double-clicks a word and triple-clicks a line, and shows the text cursor over a field.
- **Focus**: one field has the keyboard. A click focuses or blurs; `ui.focus(id)` and `ui.blur()` do it from code, and `ui.editing()` tells the host to keep bare-key shortcuts out of the way while someone types.

The field lays out its own lines with the same advances Clay measures (`ui.text_width`, `ui.rune_width`), so the caret and selection land on the glyphs. Typed text arrives in `ui.input.chars` (`ui.typed()`), as the keyboard layout produced it, and editing keys repeat while held (`ui.key_repeat`).

## Rich text

`ui.rich_text(id, spans, opts)` is a paragraph of spans in different styles, wrapped together as one text: each `ui.Span` has its text and a `Span_Style` (font slot, size, color, a rounded box behind it, underline, strikethrough, and a link id). Clay wraps each text element on its own, so the paragraph lays out its own lines at the width its element had last frame (`opts.width` before it has one, else the last paragraph's), and draws them as one Custom element. Baselines line up across fonts on a line, a span with a box (inline code) takes a few points of room on either side, a word too wide for the line breaks between characters, and spaces where a line breaks hang. `opts.align` centers or right-aligns the lines; `opts.nowrap` breaks only at newlines and makes the element as wide as its widest line (code: clip the parent to cut what overflows, and `ui.rich_content_width` says how wide it got). The result has the height, and the link under the pointer and the one clicked this frame, with the hand cursor over links.

Paragraphs are selectable together: a drag selects from one paragraph to another in the order they were declared (it follows the pointer's height, however far left or right it goes), a double click takes a word, a triple click a paragraph, Shift+click extends, a click elsewhere clears it. Cmd+C (Ctrl+C) copies the text, paragraphs joined by newlines, unless a text field has the keyboard; `ui.rich_selection()` gives it to the host, `opts.unselectable` leaves decoration (list markers) out. Layouts are kept per id while the text, fonts, sizes and width stay the same; colors and decorations can change every frame without a relayout. Italic and bold are font slots of their own: `fetch-fonts.sh` cuts Newsreader Italic, SemiBold and SemiBold Italic for this.

## Layout

```
ui/            Clay widgets, the frame loop, the raylib renderer, themes, designs, animation, macOS and Wayland hooks
ui/omarchy/    optional: follow the active Omarchy theme (Linux)
ui/appearance/ optional: follow the system appearance and accent (macOS)
app/           the demo: graph, showcase, design editor
designs/       design files: console (default), soft, compact
deps/clay/     Clay bindings + built static libs
deps/raylib/   raylib bindings + the Linux and macOS static libs and their build scripts
tools/         vsync_probe
fonts/         Inter (committed); ./fetch-fonts.sh adds the rest
```

The app owns the loop (`ui.init`, `for ui.frame()`, `ui.shutdown`). Widgets read an input snapshot and emit Clay. They do not call raylib. The graph does, in the canvas region, before `ui.render` paints the panel on top.

## License

MIT, see [LICENSE](LICENSE). Bundled third-party pieces keep their own licenses: Clay is zlib ([deps/clay/LICENSE.md](deps/clay/LICENSE.md)), and the fonts are SIL OFL 1.1, each with its license next to it in [fonts/](fonts): [Inter](https://github.com/rsms/inter), [EB Garamond](https://github.com/octaviopardo/EBGaramond12), [Cormorant Garamond](https://github.com/CatharsisFonts/Cormorant), [Spectral](https://github.com/productiontype/Spectral), [Newsreader](https://github.com/productiontype/Newsreader) and [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono). All but Inter are fetched by `./fetch-fonts.sh`, not committed. The Cormorant, EB Garamond, Newsreader and JetBrains Mono files are static instances (Regular, Medium, SemiBold) it cuts from the variable fonts on [Google Fonts](https://github.com/google/fonts) with `fonttools varLib.instancer`, because only a variable font's default instance is drawn (Cormorant's is Light). raylib is zlib ([deps/raylib/LICENSE.md](deps/raylib/LICENSE.md)).
