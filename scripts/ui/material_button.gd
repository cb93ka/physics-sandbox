class_name MaterialButton
extends Button
## Плашка материала: цвет + название. Подсказка desc — при наведении мышью
## или при долгом нажатии пальцем.

signal hint_requested(button: MaterialButton)
signal hint_hidden

const HOVER_DELAY := 0.5
const LONG_PRESS := 0.45

var entry: Dictionary = {}
var _timer: Timer
var _hint_shown := false
var _holding := false


func setup(e: Dictionary, group: ButtonGroup) -> void:
	entry = e
	text = str(e.get("name", "?"))
	icon = PixelIcons.swatch(e.get("color", Color.MAGENTA), 18)
	toggle_mode = true
	button_group = group
	focus_mode = Control.FOCUS_NONE
	theme_type_variation = &"MaterialButton"
	# Одна строка, ширина по названию: ряд прокручивается по горизонтали.
	custom_minimum_size = Vector2(88, UiKit.TOUCH)
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_theme_font_size_override("font_size", 16)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_timer)
	add_child(_timer)
	mouse_entered.connect(_on_enter)
	mouse_exited.connect(_on_exit)
	button_down.connect(_on_down)
	button_up.connect(_on_up)


func hint_text() -> String:
	var d := str(entry.get("desc", ""))
	return str(entry.get("name", "")) + ("\n" + d if d != "" else "")


func _on_enter() -> void:
	if not UiKit.last_input_touch:
		_timer.start(HOVER_DELAY)


func _on_down() -> void:
	_holding = true
	_timer.start(LONG_PRESS)


func _on_up() -> void:
	_holding = false
	_on_exit()


func _on_exit() -> void:
	_timer.stop()
	if _hint_shown:
		_hint_shown = false
		hint_hidden.emit()


func _on_timer() -> void:
	var over := get_global_rect().has_point(get_global_mouse_position())
	if _holding or (over and not UiKit.last_input_touch):
		_hint_shown = true
		hint_requested.emit(self)
