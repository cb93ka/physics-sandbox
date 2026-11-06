class_name TopBar
extends PanelContainer
## Верхняя полоса: пауза, шаг, разогрев ×3, виды, отмена, очистка, слоты, настройки.

signal step_pressed
signal undo_pressed
signal clear_pressed
signal saves_pressed
signal settings_pressed

const VIEW_NAMES: Array[String] = ["Обычный", "Тепло", "Нейтроны", "Воздух"]
const VIEW_TIPS: Array[String] = ["Обычный вид (1)", "Тепловизор (2)", "Нейтроны и радиация (3)", "Потоки воздуха (4)"]
const WIDE_SCREEN := 1000.0

var state: AppState
var _pause: Button
var _heat: Button
var _views: Array[Button] = []


func setup(app_state: AppState) -> void:
	state = app_state
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme_type_variation = &"CompactPanel"
	var row := UiKit.hbox(UiKit.GAP)
	add_child(row)

	_pause = UiKit.icon_button("pause", "Пауза / пуск (пробел)")
	_pause.pressed.connect(_on_pause)
	row.add_child(_pause)
	var step := UiKit.icon_button("step", "Шаг кадра (F)")
	step.pressed.connect(func() -> void: step_pressed.emit())
	row.add_child(step)
	_heat = UiKit.button("Разогрев ×3", "heat", true, "Тепло идёт в 3 раза быстрее (H)")
	_heat.theme_type_variation = &"HotButton"
	_heat.toggled.connect(_on_heat)
	row.add_child(_heat)

	row.add_child(UiKit.spacer())
	var group := ButtonGroup.new()
	for i in VIEW_NAMES.size():
		var b := UiKit.button(VIEW_NAMES[i], "", true, VIEW_TIPS[i])
		b.theme_type_variation = &"TabButton"
		b.button_group = group
		b.pressed.connect(_on_view.bind(i))
		row.add_child(b)
		_views.append(b)
	row.add_child(UiKit.spacer())

	var undo := UiKit.icon_button("undo", "Отменить (Ctrl+Z)")
	undo.pressed.connect(func() -> void: undo_pressed.emit())
	row.add_child(undo)
	var clr := UiKit.icon_button("trash", "Очистить (C)")
	clr.pressed.connect(func() -> void: clear_pressed.emit())
	row.add_child(clr)
	var saves := UiKit.icon_button("save", "Сохранить / загрузить")
	saves.pressed.connect(func() -> void: saves_pressed.emit())
	row.add_child(saves)
	var settings := UiKit.icon_button("gear", "Настройки")
	settings.pressed.connect(func() -> void: settings_pressed.emit())
	row.add_child(settings)
	get_viewport().size_changed.connect(_on_resized)
	_on_resized()
	sync()


## На узком экране кнопка разогрева короче: «×3».
func _on_resized() -> void:
	var wide := get_viewport().get_visible_rect().size.x >= WIDE_SCREEN
	_heat.text = "Разогрев ×3" if wide else "×3"


func sync() -> void:
	_pause.icon = PixelIcons.get_icon("play" if state.paused else "pause")
	_heat.set_pressed_no_signal(state.fast_heat)
	for i in _views.size():
		_views[i].set_pressed_no_signal(i == state.view)


func _on_pause() -> void:
	state.paused = not state.paused
	state.notify()


func _on_heat(on: bool) -> void:
	state.fast_heat = on
	state.notify()


func _on_view(i: int) -> void:
	state.view = i
	state.notify()
