class_name UiKit
extends RefCounted
## Общие размеры и фабрики виджетов. Размеры — в логических пикселях интерфейса;
## на телефоне main подбирает content_scale_factor так, что 1 px ≈ 1 pt.

const TOUCH := 44.0
const GAP := 4
const MARGIN := 6

## true, если последний ввод пришёл с настоящего тач-экрана (не с мыши).
static var last_input_touch := false


static func button(text: String, icon_name: String = "", toggle: bool = false, tip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	if icon_name != "":
		b.icon = PixelIcons.get_icon(icon_name)
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(TOUCH, TOUCH)
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	return b


static func icon_button(icon_name: String, tip: String, toggle: bool = false) -> Button:
	var b := button("", icon_name, toggle, tip)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return b


static func label(text: String, variation: StringName = &"") -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if variation != &"":
		l.theme_type_variation = variation
	return l


static func hbox(sep: int = GAP) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h


static func vbox(sep: int = GAP) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func separator_v() -> Control:
	var c := ColorRect.new()
	c.color = Color(1, 1, 1, 0.08)
	c.custom_minimum_size = Vector2(2, 28)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c
