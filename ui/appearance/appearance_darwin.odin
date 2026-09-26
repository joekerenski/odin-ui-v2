package appearance

// Colors come from AppKit's dynamic system colors, resolved against the
// app's effective appearance, which follows System Settings unless the app
// overrides it. match_window overrides only the window, so it never hides a
// system change from load.
//
//   background  windowBackgroundColor
//   foreground  labelColor, flattened over the background (it is translucent)
//   accent      controlAccentColor, the System Settings accent
//   on accent   alternateSelectedControlTextColor (white, as AppKit draws it,
//               even where black would measure higher contrast)
//   border      separatorColor, flattened
//   status      systemOrange, systemRed, systemGreen
//
// Nothing here signals a change, so changed() re-reads the colors at most
// every 250ms and compares. That is a few Objective-C calls, cheap to run
// every frame.

import ui ".."
import rl "../../deps/raylib"
import "base:intrinsics"
import "core:strings"
import "core:time"
import NS "core:sys/darwin/Foundation"

@(private)
CHECK_EVERY :: 250 * time.Millisecond

@(private)
s_checked: time.Tick

@(private)
s_last: ui.Theme_Base

load :: proc() -> (t: Theme, ok: bool) {
	t.base, ok = read_base()
	if !ok {
		return
	}
	s_last = t.base
	t.name = "Dark" if t.base.mode == .Dark else "Light"
	return
}

// True once each time the appearance or accent changes.
changed :: proc() -> bool {
	if s_checked != {} && time.tick_since(s_checked) < CHECK_EVERY {
		return false
	}
	s_checked = time.tick_now()
	b, ok := read_base()
	if !ok || b == s_last {
		return false
	}
	return true
}

// Give the window's title bar and controls a fixed mode, to match a built-in
// palette, or nil to follow the system again.
match_window :: proc(mode: Maybe(ui.Theme_Mode)) {
	NS.scoped_autoreleasepool()
	win := cast(^NS.Object)rl.GetWindowHandle()
	if win == nil {
		return
	}
	ap: ^NS.Object
	if m, ok := mode.?; ok {
		name := cstring("NSAppearanceNameDarkAqua") if m == .Dark else cstring("NSAppearanceNameAqua")
		str := intrinsics.objc_send(^NS.Object, class("NSString"), "stringWithUTF8String:", name)
		ap = intrinsics.objc_send(^NS.Object, class("NSAppearance"), "appearanceNamed:", str)
	}
	intrinsics.objc_send(nil, win, "setAppearance:", ap)
}

@(private)
read_base :: proc() -> (b: ui.Theme_Base, ok: bool) {
	NS.scoped_autoreleasepool()
	app := intrinsics.objc_send(^NS.Object, class("NSApplication"), "sharedApplication")
	if app == nil {
		return
	}
	ap := intrinsics.objc_send(^NS.Object, app, "effectiveAppearance")
	if ap == nil {
		return
	}
	// "NSAppearanceNameDarkAqua", or its high-contrast variant.
	name := intrinsics.objc_send(^NS.String, ap, "name")
	b.mode = .Dark if name != nil && strings.contains(NS.String_odinString(name), "Dark") else .Light

	// Dynamic colors resolve against the current drawing appearance, which
	// outside a draw call is not the app's. Set it for the reads.
	ap_class := class("NSAppearance")
	prev := intrinsics.objc_send(^NS.Object, ap_class, "currentAppearance")
	intrinsics.objc_send(nil, ap_class, "setCurrentAppearance:", ap)
	defer intrinsics.objc_send(nil, ap_class, "setCurrentAppearance:", prev)

	c := class("NSColor")
	b.background = resolve(intrinsics.objc_send(^NS.Object, c, "windowBackgroundColor"), {})
	b.foreground = resolve(intrinsics.objc_send(^NS.Object, c, "labelColor"), b.background)
	b.accent = resolve(intrinsics.objc_send(^NS.Object, c, "controlAccentColor"), b.background)
	b.text_on_accent = resolve(intrinsics.objc_send(^NS.Object, c, "alternateSelectedControlTextColor"), b.accent)
	b.border = resolve(intrinsics.objc_send(^NS.Object, c, "separatorColor"), b.background)
	b.warning = resolve(intrinsics.objc_send(^NS.Object, c, "systemOrangeColor"), b.background)
	b.danger = resolve(intrinsics.objc_send(^NS.Object, c, "systemRedColor"), b.background)
	b.success = resolve(intrinsics.objc_send(^NS.Object, c, "systemGreenColor"), b.background)
	ok = b.background.a > 0 && b.foreground.a > 0 && b.accent.a > 0
	return
}

// sRGB, 0..255. A translucent color is flattened over `over` when given, so
// the palette math sees what the eye does.
@(private)
resolve :: proc(color: ^NS.Object, over: ui.Color) -> ui.Color {
	if color == nil {
		return {}
	}
	srgb := intrinsics.objc_send(^NS.Object, class("NSColorSpace"), "sRGBColorSpace")
	rgb := intrinsics.objc_send(^NS.Object, color, "colorUsingColorSpace:", srgb)
	if rgb == nil {
		return {}
	}
	ch :: proc(v: f64) -> f32 {
		return f32(clamp(v, 0, 1) * 255)
	}
	out := ui.Color{
		ch(intrinsics.objc_send(f64, rgb, "redComponent")),
		ch(intrinsics.objc_send(f64, rgb, "greenComponent")),
		ch(intrinsics.objc_send(f64, rgb, "blueComponent")),
		255,
	}
	a := f32(clamp(intrinsics.objc_send(f64, rgb, "alphaComponent"), 0, 1))
	if a < 1 && over.a > 0 {
		out = ui.mix(over, out, a)
		out.a = 255
	}
	return out
}

@(private)
class :: proc(name: cstring) -> ^NS.Object {
	return cast(^NS.Object)NS.objc_lookUpClass(name)
}
