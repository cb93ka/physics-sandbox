class_name SettingsPanel
extends VBoxContainer
## Содержимое окна «Настройки».

signal reset_camera_requested

var state: AppState


func setup(app_state: AppState) -> void:
	state = app_state
	add_theme_constant_override("separation", 2)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_check("Смещение кисти над пальцем", state.brush_offset, func(on: bool) -> void: state.brush_offset = on)
	_check("Счётчики (FPS, нейтроны, T)", state.show_stats, func(on: bool) -> void: state.show_stats = on)
	var tilt_text := "Гравитация от наклона" + ("" if OS.has_feature("mobile") else " (только телефон)")
	_check(tilt_text, state.tilt_gravity, func(on: bool) -> void: state.tilt_gravity = on)
	_check("Вибрация", state.haptics, func(on: bool) -> void: state.haptics = on)
	var cam := UiKit.button("Сбросить камеру")
	cam.pressed.connect(func() -> void: reset_camera_requested.emit())
	add_child(cam)
	add_child(UiKit.label("ПК: ЛКМ рисует, ПКМ стирает, колесо — размер,\nCtrl+колесо — зум, СКМ или пробел+мышь — пан.\nТач: один палец рисует, два — пан и зум,\nтап двумя — отмена.", &"DimLabel"))


func _check(text: String, value: bool, on_toggle: Callable) -> void:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = value
	c.focus_mode = Control.FOCUS_NONE
	c.custom_minimum_size = Vector2(0, UiKit.TOUCH)
	c.toggled.connect(func(on: bool) -> void:
		on_toggle.call(on)
		state.save_settings()
		state.notify())
	add_child(c)
