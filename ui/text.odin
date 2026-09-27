package ui

import clay "../deps/clay"

text :: proc(s: string, font_id: u16, size: u16, color: Color) {
	clay.TextDynamic(s, clay.TextElementConfig{
		fontId    = font_id,
		fontSize  = size,
		textColor = color,
	})
}

title :: proc(s: string, color: Color = theme.text) {
	text(s, theme.font_title, theme.size_title, color)
}

heading :: proc(s: string, color: Color = theme.text) {
	text(s, theme.font_heading, theme.size_heading, color)
}

body :: proc(s: string, color: Color = theme.text) {
	text(s, theme.font_body, theme.size_body, color)
}

dim :: proc(s: string) {
	text(s, theme.font_small, theme.size_small, theme.text_dim)
}

section :: proc(s: string) {
	text(s, theme.font_small, theme.size_small, theme.accent)
}
