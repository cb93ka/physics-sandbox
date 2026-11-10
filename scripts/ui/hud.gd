class_name Hud
extends Control
## Весь интерфейс поверх мира: верхняя полоса, инструменты, шторка материалов,
## термометр, счётчики, подсказки и модальные окна. Учитывает безопасную зону экрана.

signal undo_requested
signal step_requested
signal clear_confirmed
signal save_requested(slot: int)
signal load_requested(slot: int)
signal reset_camera_requested
## Свободная область для мира (между верхней полосой и шторкой) изменилась.
signal world_area_changed(rect: Rect2)

var state: AppState
var top_bar: TopBar
var tool_bar: ToolBar
var drawer: MaterialDrawer
var modal: Modal

var _margin: MarginContainer
var _middle: Control
var _right: VBoxContainer
var _thermo: PanelContainer
var _thermo_label: Label
var _stats: PanelContainer
var _stats_label: Label
var _hint: PanelContainer
var _hint_label: Label
var _safe_extra := Rect2()
var _banner: PanelContainer
var _toast: PanelContainer
var _toast_label: Label
var _toast_timer := 0.0


func setup(app_state: AppState, palette: Array[Dictionary], categories: Array[Dictionary]) -> void:
	state = app_state
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_margin = MarginContainer.new()
	_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_margin)
	var col := UiKit.vbox(UiKit.MARGIN)
	_margin.add_child(col)

	top_bar = TopBar.new()
	col.add_child(top_bar)
	top_bar.setup(state)
	top_bar.step_pressed.connect(func() -> void: step_requested.emit())
	top_bar.undo_pressed.connect(func() -> void: undo_requested.emit())
	top_bar.clear_pressed.connect(confirm_clear)
	top_bar.saves_pressed.connect(open_saves)
	top_bar.settings_pressed.connect(open_settings)

	_middle = Control.new()
	_middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_middle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_middle.resized.connect(_on_middle_resized)
	col.add_child(_middle)

	tool_bar = ToolBar.new()
	tool_bar.setup(state)
	tool_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_middle.add_child(tool_bar)

	_right = UiKit.vbox(UiKit.GAP)
	_right.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_right.alignment = BoxContainer.ALIGNMENT_BEGIN
	_middle.add_child(_right)
	_thermo = _chip_panel()
	_thermo_label = UiKit.label("")
	_thermo.add_child(_thermo_label)
	_right.add_child(_thermo)
	_stats = _chip_panel()
	_stats_label = UiKit.label("", &"DimLabel")
	_stats.add_child(_stats_label)
	_right.add_child(_stats)

	drawer = MaterialDrawer.new()
	col.add_child(drawer)
	drawer.setup(state, palette, categories)
	drawer.hint_requested.connect(show_hint)
	drawer.hint_hidden.connect(hide_hint)

	_hint = PanelContainer.new()
	_hint.theme_type_variation = &"ModalPanel"
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.visible = false
	_hint.top_level = true
	_hint_label = UiKit.label("")
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.custom_minimum_size = Vector2(260, 0)
	_hint.add_child(_hint_label)
	add_child(_hint)

	_toast = _make_note(Color(0.10, 0.13, 0.20, 0.95), Color(0.35, 0.62, 1.0))
	_toast_label = _toast.get_child(0) as Label
	add_child(_toast)

	modal = Modal.new()
	add_child(modal)

	get_viewport().size_changed.connect(apply_safe_area)
	apply_safe_area()
	sync()


## Дополнительные отступы для проверки вёрстки на ПК (флаг --safe-sim), в px интерфейса.
func set_simulated_safe_area(extra: Rect2) -> void:
	_safe_extra = extra
	apply_safe_area()


func apply_safe_area() -> void:
	var l := 0.0
	var t := 0.0
	var r := 0.0
	var b := 0.0
	if OS.has_feature("mobile"):
		var safe := DisplayServer.get_display_safe_area()
		var win := Vector2(DisplayServer.window_get_size())
		var vp := get_viewport().get_visible_rect().size
		if win.x > 0.0 and win.y > 0.0 and safe.size.x > 0:
			var k := vp / win
			l = float(safe.position.x) * k.x
			t = float(safe.position.y) * k.y
			r = (win.x - float(safe.end.x)) * k.x
			b = (win.y - float(safe.end.y)) * k.y
	l += _safe_extra.position.x
	t += _safe_extra.position.y
	r += _safe_extra.size.x
	b += _safe_extra.size.y
	var m := float(UiKit.MARGIN)
	_margin.add_theme_constant_override("margin_left", roundi(maxf(l, m)))
	_margin.add_theme_constant_override("margin_top", roundi(maxf(t, m)))
	_margin.add_theme_constant_override("margin_right", roundi(maxf(r, m)))
	# Снизу у iPhone полоска «домой» — шторке хватает половины отступа.
	_margin.add_theme_constant_override("margin_bottom", roundi(maxf(b * 0.5, m)))


func sync() -> void:
	top_bar.sync()
	tool_bar.sync()
	drawer.sync()
	_stats.visible = state.show_stats


## Точка занята интерфейсом — в мир не рисовать.
func blocks_point(p: Vector2) -> bool:
	if modal.visible:
		return true
	for c: Control in [top_bar, tool_bar, drawer]:
		if c.is_visible_in_tree() and c.get_global_rect().has_point(p):
			return true
	return false


func set_cell_info(text: String) -> void:
	if text == _thermo_label.text and _thermo.visible == (text != ""):
		return
	_thermo.visible = text != ""
	_thermo_label.text = text
	_relayout_right()


func set_stats_text(text: String) -> void:
	if text == _stats_label.text:
		return
	_stats_label.text = text
	_relayout_right()


## Красный баннер «ядро не загрузилось» вверху, под полосой.
## short — вариант для узкого экрана.
func show_core_banner(text: String, short: String = "") -> void:
	if _banner == null:
		_banner = _make_note(Color(0.55, 0.08, 0.08, 0.95), Color(1.0, 0.45, 0.4))
		add_child(_banner)
		move_child(_banner, modal.get_index())
	_banner.set_meta("long", text)
	_banner.set_meta("short", short if short != "" else text)
	(_banner.get_child(0) as Label).text = text
	_banner.visible = true
	_place_notes.call_deferred()


## Короткая плашка над шторкой, гаснет сама (не модальная). Переносы строк — в тексте.
func show_toast(text: String, seconds: float = 8.0) -> void:
	_toast_label.text = text
	_toast.visible = true
	_toast_timer = seconds
	_place_notes.call_deferred()


func _make_note(bg: Color, border: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.visible = false
	p.top_level = true
	var l := UiKit.label("")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


## Плашки — по центру свободной полосы между колонкой инструментов и правой колонкой.
func _place_notes() -> void:
	if top_bar == null or drawer == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var x0 := tool_bar.get_global_rect().end.x + 8.0
	var x1 := vp.x - 8.0
	if _right.visible and _right.get_combined_minimum_size().x > 0.0:
		x1 = _right.get_global_rect().position.x - 8.0
	if _banner != null and _banner.visible:
		var l := _banner.get_child(0) as Label
		l.text = str(_banner.get_meta("long"))
		if _banner.get_combined_minimum_size().x > x1 - x0:
			l.text = str(_banner.get_meta("short"))
		_banner.reset_size()
		var sz := _banner.get_combined_minimum_size()
		_banner.position = Vector2(x0 + maxf(0.0, (x1 - x0 - sz.x) * 0.5), top_bar.get_global_rect().end.y + 8.0)
	if _toast != null and _toast.visible:
		_toast.reset_size()
		var tz := _toast.get_combined_minimum_size()
		_toast.position = Vector2(x0 + maxf(0.0, (x1 - x0 - tz.x) * 0.5), drawer.get_global_rect().position.y - tz.y - 10.0)


func show_hint(text: String, anchor: Rect2) -> void:
	_hint_label.text = text
	_hint.visible = true
	_hint.reset_size()
	var vp := get_viewport().get_visible_rect().size
	var sz := _hint.get_combined_minimum_size()
	var pos := Vector2(anchor.position.x, anchor.position.y - sz.y - 6.0)
	pos.x = clampf(pos.x, 4.0, vp.x - sz.x - 4.0)
	pos.y = maxf(4.0, pos.y)
	_hint.position = pos


func hide_hint() -> void:
	_hint.visible = false


func confirm_clear() -> void:
	var l := UiKit.label("Всё станет воздухом. Отменить можно кнопкой «Отмена».")
	modal.open("Очистить мир?", l, PackedStringArray(["Нет", "Очистить"]), func(i: int) -> void:
		if i == 1:
			clear_confirmed.emit())


func open_saves() -> void:
	var p := SavesPanel.new()
	p.save_requested.connect(func(slot: int) -> void: save_requested.emit(slot))
	p.load_requested.connect(func(slot: int) -> void:
		load_requested.emit(slot)
		modal.close())
	modal.open("Сохранения", p, PackedStringArray(["Закрыть"]))


func open_settings() -> void:
	var p := SettingsPanel.new()
	p.setup(state)
	p.reset_camera_requested.connect(func() -> void:
		reset_camera_requested.emit()
		modal.close())
	modal.open("Настройки", p, PackedStringArray(["Закрыть"]))


func _chip_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = &"ChipPanel"
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## Область для мира: вся ширина экрана, по высоте — между верхней полосой и шторкой.
func world_area() -> Rect2:
	var vp := get_viewport().get_visible_rect().size
	var top := top_bar.get_global_rect().end.y + 2.0
	var bottom := drawer.get_global_rect().position.y - 2.0
	return Rect2(0.0, top, vp.x, maxf(8.0, bottom - top))


func _on_middle_resized() -> void:
	world_area_changed.emit(world_area())
	_relayout_right()
	_place_notes()
	tool_bar.fit_height(_middle.size.y)
	tool_bar.position = Vector2.ZERO
	_right.position = Vector2(_middle.size.x - _right.size.x, 0)


func _process(delta: float) -> void:
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			_toast.visible = false


## Правая колонка меняет ширину вместе с текстом — держим её у правого края.
func _relayout_right() -> void:
	var w := _right.get_combined_minimum_size().x
	_right.size.x = w
	_right.position.x = _middle.size.x - w


func _input(event: InputEvent) -> void:
	# Запоминаем, чем пользуются: от этого зависят подсказки при наведении.
	if event is InputEventScreenTouch and event.device != InputEvent.DEVICE_ID_EMULATION:
		UiKit.last_input_touch = true
	elif event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION:
		UiKit.last_input_touch = false
