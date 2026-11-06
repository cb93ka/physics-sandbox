class_name MaterialDrawer
extends PanelContainer
## Нижняя шторка, компактная:
##   строка 1 — текущий материал (открыть/закрыть), вкладки категорий (прокрутка),
##              режим замены, размер кисти;
##   строка 2 (когда открыта) — один ряд материалов с горизонтальной прокруткой.
## Скрытые материалы не показываются, «Недавние» — последние 6.

signal hint_requested(text: String, rect: Rect2)
signal hint_hidden
signal open_changed(is_open: bool)

const RECENT_TAB := "__recent"
const WIDE_SCREEN := 1000.0

var state: AppState
var palette: Array[Dictionary] = []
var categories: Array[Dictionary] = []
var is_open := true

var _chip: Button
var _tab_buttons: Dictionary = {}
var _current_tab := ""
var _row_scroll: ScrollContainer
var _row: HBoxContainer
var _replace: Button
var _slider: HSlider
var _size_label: Label
var _size_caption: Label
var _mat_group := ButtonGroup.new()
var _tab_group := ButtonGroup.new()
var _buttons: Array[MaterialButton] = []


func setup(app_state: AppState, pal: Array[Dictionary], cats: Array[Dictionary]) -> void:
	state = app_state
	palette = pal
	categories = _visible_categories(cats)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme_type_variation = &"CompactPanel"

	var root := UiKit.vbox(UiKit.GAP)
	add_child(root)
	var header := UiKit.hbox(UiKit.GAP)
	root.add_child(header)

	_chip = UiKit.button("", "", false, "Показать / скрыть материалы")
	_chip.custom_minimum_size = Vector2(120, UiKit.TOUCH)
	_chip.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_chip.clip_text = true
	_chip.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_chip.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_chip.pressed.connect(func() -> void: set_open(not is_open))
	header.add_child(_chip)

	var tabs_scroll := _hscroll()
	tabs_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(tabs_scroll)
	var tabs := UiKit.hbox(UiKit.GAP)
	tabs_scroll.add_child(tabs)
	_add_tab(tabs, RECENT_TAB, "Недавние")
	for c in categories:
		_add_tab(tabs, str(c["id"]), str(c["name"]))

	_replace = UiKit.button("Заменять", "replace", true, "Вкл: кисть заменяет всё. Выкл: рисует только в пустоту")
	_replace.toggled.connect(_on_replace)
	header.add_child(_replace)
	_size_caption = UiKit.label("Размер", &"DimLabel")
	header.add_child(_size_caption)
	_slider = HSlider.new()
	_slider.min_value = AppState.RADIUS_MIN
	_slider.max_value = AppState.RADIUS_MAX
	_slider.step = 1
	_slider.custom_minimum_size = Vector2(110, UiKit.TOUCH)
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.value_changed.connect(_on_size)
	header.add_child(_slider)
	_size_label = UiKit.label("0")
	_size_label.custom_minimum_size = Vector2(24, 0)
	header.add_child(_size_label)

	_row_scroll = _hscroll()
	root.add_child(_row_scroll)
	_row = UiKit.hbox(UiKit.GAP)
	_row_scroll.add_child(_row)

	get_viewport().size_changed.connect(_on_resized)
	_on_resized()
	_select_tab(_tab_for_material(state.material))
	sync()


func set_open(v: bool) -> void:
	if is_open == v and _row_scroll.visible == v:
		return
	is_open = v
	_row_scroll.visible = v
	sync()
	reset_size()
	open_changed.emit(v)


func sync() -> void:
	var e := entry_for(state.material)
	_chip.text = str(e.get("name", "—"))
	_chip.icon = PixelIcons.swatch(e.get("color", Color.BLACK), 18)
	_replace.set_pressed_no_signal(state.replace_mode)
	_slider.set_value_no_signal(state.brush_radius)
	_size_label.text = str(state.brush_radius + 1)
	for b in _buttons:
		b.set_pressed_no_signal(int(b.entry["index"]) == state.material)


func entry_for(index: int) -> Dictionary:
	for e in palette:
		if int(e["index"]) == index:
			return e
	return {}


func entry_for_key(key: String) -> Dictionary:
	for e in palette:
		if str(e["key"]) == key:
			return e
	return {}


func _hscroll() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	s.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.mouse_filter = Control.MOUSE_FILTER_PASS
	s.follow_focus = false
	return s


## На узком экране подписи «Заменять» и «Размер» убираем — остаются иконка и ползунок.
func _on_resized() -> void:
	var wide := get_viewport().get_visible_rect().size.x >= WIDE_SCREEN
	_replace.text = "Заменять" if wide else ""
	_size_caption.visible = wide


func _visible_categories(cats: Array[Dictionary]) -> Array[Dictionary]:
	var used := {}
	for e in palette:
		if not bool(e["hidden"]):
			used[str(e["category"])] = true
	var out: Array[Dictionary] = []
	for c in cats:
		if used.has(str(c["id"])):
			out.append(c)
			used.erase(str(c["id"]))
	# Категории, которых нет в списке categories, — в конец под своим id.
	for k: Variant in used.keys():
		out.append({"id": str(k), "name": str(k)})
	return out


func _add_tab(parent: Control, id: String, title: String) -> void:
	var b := UiKit.button(title, "", true)
	b.theme_type_variation = &"TabButton"
	b.button_group = _tab_group
	b.pressed.connect(_on_tab.bind(id))
	parent.add_child(b)
	_tab_buttons[id] = b


func _tab_for_material(index: int) -> String:
	var cat := str(entry_for(index).get("category", ""))
	if _tab_buttons.has(cat):
		return cat
	return str(categories[0]["id"]) if not categories.is_empty() else RECENT_TAB


func _on_tab(id: String) -> void:
	_select_tab(id)
	if not is_open:
		set_open(true)


func _select_tab(id: String) -> void:
	_current_tab = id
	for k: Variant in _tab_buttons.keys():
		var b: Button = _tab_buttons[k]
		b.set_pressed_no_signal(str(k) == id)
	_fill()


func _fill() -> void:
	for c in _row.get_children():
		_row.remove_child(c)
		c.queue_free()
	_buttons.clear()
	var entries: Array[Dictionary] = []
	if _current_tab == RECENT_TAB:
		for key in state.recent:
			var e := entry_for_key(key)
			if not e.is_empty() and not bool(e["hidden"]):
				entries.append(e)
	else:
		for e in palette:
			if str(e["category"]) == _current_tab and not bool(e["hidden"]):
				entries.append(e)
	for e in entries:
		var b := MaterialButton.new()
		b.setup(e, _mat_group)
		b.pressed.connect(_on_material.bind(int(e["index"])))
		b.hint_requested.connect(_on_hint)
		b.hint_hidden.connect(func() -> void: hint_hidden.emit())
		_row.add_child(b)
		_buttons.append(b)
	if entries.is_empty() and _current_tab == RECENT_TAB:
		var l := UiKit.label("Здесь появятся последние материалы", &"DimLabel")
		l.custom_minimum_size = Vector2(0, UiKit.TOUCH)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_row.add_child(l)
	_row_scroll.scroll_horizontal = 0
	sync()


func _on_material(index: int) -> void:
	state.material = index
	if state.tool != AppState.Tool.BRUSH:
		state.tool = AppState.Tool.BRUSH
	var e := entry_for(index)
	if not e.is_empty():
		state.push_recent(str(e["key"]))
	state.notify()


func _on_hint(b: MaterialButton) -> void:
	hint_requested.emit(b.hint_text(), b.get_global_rect())


func _on_replace(on: bool) -> void:
	state.replace_mode = on
	state.notify()


func _on_size(v: float) -> void:
	state.set_radius(int(v))
	state.notify()
