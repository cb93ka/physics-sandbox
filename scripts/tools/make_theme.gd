extends SceneTree
## Генерирует тёмную пиксельную тему res://assets/ui/theme.tres.
## Запуск: godot --headless --path . -s res://scripts/tools/make_theme.gd

const OUT := "res://assets/ui/theme.tres"
const FONT := "res://assets/fonts/Tiny5.ttf"

const C_PANEL := Color(0.075, 0.085, 0.11, 0.92)
const C_BTN := Color(0.15, 0.165, 0.21)
const C_BTN_HOVER := Color(0.20, 0.22, 0.28)
const C_BTN_PRESSED := Color(0.20, 0.32, 0.50)
const C_EDGE := Color(0.02, 0.025, 0.035)
const C_ACCENT := Color(0.33, 0.62, 1.0)
const C_HOT := Color(1.0, 0.45, 0.10)
const C_TEXT := Color(0.90, 0.91, 0.93)


func _box(bg: Color, border: Color, bw: int = 2, pad: int = 6) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(0)
	sb.anti_aliasing = false
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad - 2
	sb.content_margin_bottom = pad - 2
	return sb


func _init() -> void:
	var th := Theme.new()
	var font: FontFile = load(FONT)
	th.default_font = font
	th.default_font_size = 16

	# Панели.
	var panel := _box(C_PANEL, C_EDGE, 2, 6)
	th.set_stylebox("panel", "PanelContainer", panel)
	th.set_stylebox("panel", "Panel", panel)
	th.set_type_variation("ModalPanel", "PanelContainer")
	th.set_stylebox("panel", "ModalPanel", _box(Color(0.10, 0.11, 0.15, 0.98), C_ACCENT, 2, 10))
	th.set_type_variation("CompactPanel", "PanelContainer")
	th.set_stylebox("panel", "CompactPanel", _box(C_PANEL, C_EDGE, 2, 5))
	th.set_type_variation("ChipPanel", "PanelContainer")
	th.set_stylebox("panel", "ChipPanel", _box(Color(0.05, 0.055, 0.075, 0.85), C_EDGE, 2, 6))

	# Кнопки.
	th.set_stylebox("normal", "Button", _box(C_BTN, C_EDGE))
	th.set_stylebox("hover", "Button", _box(C_BTN_HOVER, C_EDGE))
	th.set_stylebox("pressed", "Button", _box(C_BTN_PRESSED, C_ACCENT))
	th.set_stylebox("hover_pressed", "Button", _box(C_BTN_PRESSED.lightened(0.1), C_ACCENT))
	th.set_stylebox("disabled", "Button", _box(C_BTN.darkened(0.4), C_EDGE))
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_color("font_color", "Button", C_TEXT)
	th.set_color("font_hover_color", "Button", Color.WHITE)
	th.set_color("font_pressed_color", "Button", Color.WHITE)
	th.set_color("font_hover_pressed_color", "Button", Color.WHITE)
	th.set_color("font_disabled_color", "Button", Color(0.5, 0.5, 0.55))
	th.set_color("icon_normal_color", "Button", C_TEXT)
	th.set_color("icon_pressed_color", "Button", Color.WHITE)
	th.set_constant("h_separation", "Button", 6)

	# «Горячая» кнопка: разогрев ×3 подсвечивается оранжевым, когда включён.
	th.set_type_variation("HotButton", "Button")
	th.set_stylebox("pressed", "HotButton", _box(C_HOT.darkened(0.15), Color(1.0, 0.8, 0.3), 2))
	th.set_stylebox("hover_pressed", "HotButton", _box(C_HOT, Color(1.0, 0.85, 0.4), 2))
	th.set_stylebox("normal", "HotButton", _box(Color(0.22, 0.13, 0.08), C_HOT.darkened(0.3), 2))
	th.set_stylebox("hover", "HotButton", _box(Color(0.30, 0.17, 0.09), C_HOT, 2))
	th.set_color("font_color", "HotButton", Color(1.0, 0.75, 0.5))

	# Вкладки категорий.
	th.set_type_variation("TabButton", "Button")
	th.set_stylebox("normal", "TabButton", _box(Color(0.11, 0.12, 0.155), C_EDGE, 2, 8))
	th.set_stylebox("pressed", "TabButton", _box(Color(0.18, 0.27, 0.42), C_ACCENT, 2, 8))
	th.set_stylebox("hover_pressed", "TabButton", _box(Color(0.20, 0.30, 0.46), C_ACCENT, 2, 8))
	th.set_color("font_color", "TabButton", Color(0.72, 0.75, 0.8))

	# Плашки материалов.
	th.set_type_variation("MaterialButton", "Button")
	th.set_stylebox("normal", "MaterialButton", _box(Color(0.12, 0.13, 0.17), C_EDGE, 2, 4))
	th.set_stylebox("hover", "MaterialButton", _box(Color(0.17, 0.18, 0.23), Color(0.3, 0.33, 0.4), 2, 4))
	th.set_stylebox("pressed", "MaterialButton", _box(Color(0.16, 0.24, 0.36), Color.WHITE, 2, 4))
	th.set_stylebox("hover_pressed", "MaterialButton", _box(Color(0.18, 0.27, 0.40), Color.WHITE, 2, 4))

	# Надписи.
	th.set_color("font_color", "Label", C_TEXT)
	th.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.6))
	th.set_constant("shadow_offset_x", "Label", 1)
	th.set_constant("shadow_offset_y", "Label", 1)
	th.set_type_variation("DimLabel", "Label")
	th.set_color("font_color", "DimLabel", Color(0.6, 0.63, 0.7))
	th.set_type_variation("TitleLabel", "Label")
	th.set_font_size("font_size", "TitleLabel", 24)

	# Ползунок.
	var track := _box(Color(0.05, 0.055, 0.07), C_EDGE, 2, 0)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	th.set_stylebox("slider", "HSlider", track)
	var fill := _box(C_ACCENT.darkened(0.35), C_EDGE, 2, 0)
	fill.content_margin_top = 4
	fill.content_margin_bottom = 4
	th.set_stylebox("grabber_area", "HSlider", fill)
	th.set_stylebox("grabber_area_highlight", "HSlider", fill)
	var grab := Image.create_empty(14, 22, false, Image.FORMAT_RGBA8)
	grab.fill(C_EDGE)
	grab.fill_rect(Rect2i(2, 2, 10, 18), Color(0.85, 0.88, 0.95))
	var grab_tex := ImageTexture.create_from_image(grab)
	th.set_icon("grabber", "HSlider", grab_tex)
	th.set_icon("grabber_highlight", "HSlider", grab_tex)

	# Полосы прокрутки: тонкие.
	for sb_type: String in ["HScrollBar", "VScrollBar"]:
		th.set_stylebox("scroll", sb_type, _box(Color(0, 0, 0, 0.25), Color(0, 0, 0, 0), 0, 3))
		th.set_stylebox("grabber", sb_type, _box(Color(0.35, 0.38, 0.45), Color(0, 0, 0, 0), 0, 3))
		th.set_stylebox("grabber_highlight", sb_type, _box(Color(0.45, 0.48, 0.55), Color(0, 0, 0, 0), 0, 3))
		th.set_stylebox("grabber_pressed", sb_type, _box(C_ACCENT, Color(0, 0, 0, 0), 0, 3))

	# Флажки (CheckButton).
	th.set_color("font_color", "CheckButton", C_TEXT)
	th.set_stylebox("normal", "CheckButton", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 6))
	th.set_stylebox("hover", "CheckButton", _box(Color(1, 1, 1, 0.05), Color(0, 0, 0, 0), 0, 6))
	th.set_stylebox("pressed", "CheckButton", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 6))
	th.set_stylebox("hover_pressed", "CheckButton", _box(Color(1, 1, 1, 0.05), Color(0, 0, 0, 0), 0, 6))
	th.set_stylebox("focus", "CheckButton", StyleBoxEmpty.new())

	# Подсказки (TooltipPanel/TooltipLabel).
	th.set_stylebox("panel", "TooltipPanel", _box(Color(0.10, 0.11, 0.15, 0.97), C_ACCENT, 2, 6))
	th.set_color("font_color", "TooltipLabel", C_TEXT)

	var err := ResourceSaver.save(th, OUT)
	print("theme saved: ", OUT, " err=", err)
	quit()
