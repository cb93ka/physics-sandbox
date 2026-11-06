class_name Modal
extends Control
## Модальное окно поверх всего: затемнение + панель с заголовком, содержимым и кнопками.
## Пока открыто, ввод в мир заблокирован (Hud.blocks_point).

var _panel: PanelContainer
var _title: Label
var _content_slot: VBoxContainer
var _scroll: ScrollContainer
var _buttons: HBoxContainer
var _on_choice: Callable


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_panel = PanelContainer.new()
	_panel.theme_type_variation = &"ModalPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_panel)
	var v := UiKit.vbox(10)
	_panel.add_child(v)
	_title = UiKit.label("", &"TitleLabel")
	v.add_child(_title)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(_scroll)
	_content_slot = UiKit.vbox(6)
	_content_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_content_slot)
	_buttons = UiKit.hbox(8)
	_buttons.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(_buttons)


## Открыть окно. on_choice(index) вызывается с номером нажатой кнопки (−1 — закрыто тапом мимо).
func open(title: String, content: Control, buttons: PackedStringArray, on_choice: Callable = Callable()) -> void:
	for c in _content_slot.get_children():
		c.queue_free()
	for c in _buttons.get_children():
		c.queue_free()
	_title.text = title
	if content != null:
		_content_slot.add_child(content)
	for i in buttons.size():
		var b := UiKit.button(buttons[i])
		b.custom_minimum_size = Vector2(110, UiKit.TOUCH)
		b.pressed.connect(_choose.bind(i))
		_buttons.add_child(b)
	_on_choice = on_choice
	visible = true
	_fit_scroll.call_deferred()


## Окно не выше экрана: содержимое прокручивается, если не влезает (телефон).
func _fit_scroll() -> void:
	var need := _content_slot.get_combined_minimum_size()
	var vp := get_viewport().get_visible_rect().size
	var max_h := maxf(80.0, vp.y - 150.0)
	_scroll.custom_minimum_size = Vector2(need.x, minf(need.y, max_h))


func close() -> void:
	visible = false
	for c in _content_slot.get_children():
		c.queue_free()


func _choose(i: int) -> void:
	var cb := _on_choice
	close()
	if cb.is_valid():
		cb.call(i)


func _gui_input(event: InputEvent) -> void:
	# Тап по затемнению вне панели — закрыть.
	var pressed := false
	var pos := Vector2.ZERO
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		pressed = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
		pos = mb.position
	if pressed and not _panel.get_global_rect().has_point(pos):
		_choose(-1)
