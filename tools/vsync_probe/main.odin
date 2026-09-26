package main

// Measures what EGL's own vsync (swap interval 1) delivers: a bare raylib loop,
// no frame callbacks of ours. On a healthy stack it matches the refresh.
//
//   odin run tools/vsync_probe
//   odin run tools/vsync_probe -- novsync     same loop, swap interval 0
//
// It runs the loop for 4s and prints the rate and the worst frame after the
// first second. Useful for checking whether a driver update fixed the
// egl-wayland2 half-rate bug. See the Linux section of the README.

import "core:fmt"
import "core:os"
import "core:time"
import rl "../../deps/raylib"

main :: proc() {
	vsync := !(len(os.args) > 1 && os.args[1] == "novsync")
	flags: rl.ConfigFlags = {.WINDOW_HIGHDPI}
	if vsync do flags += {.VSYNC_HINT}
	rl.SetTraceLogLevel(.ERROR)
	rl.SetConfigFlags(flags)
	rl.InitWindow(640, 400, "vsync probe")
	defer rl.CloseWindow()

	start := time.now()
	frames := 0
	worst: f32
	for !rl.WindowShouldClose() && time.since(start) < 4 * time.Second {
		rl.BeginDrawing()
		rl.ClearBackground(rl.DARKBLUE)
		rl.DrawCircle(i32(frames * 4 % 640), 200, 40, rl.RAYWHITE)
		rl.EndDrawing()
		frames += 1
		if time.since(start) > time.Second {
			worst = max(worst, rl.GetFrameTime())
		}
	}
	secs := time.duration_seconds(time.since(start))
	fmt.printfln("%s: %.1f fps, worst frame %.1f ms", "vsync" if vsync else "no vsync", f64(frames) / secs, worst * 1000)
}
