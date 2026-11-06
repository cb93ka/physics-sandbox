class_name SavesPanel
extends HBoxContainer
## Содержимое окна «Сохранения»: карточки слотов с миниатюрой и кнопками.

signal save_requested(slot: int)
signal load_requested(slot: int)

const CARD_W := 132.0


func _ready() -> void:
	add_theme_constant_override("separation", 8)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	refresh()


func refresh() -> void:
	for c in get_children():
		c.queue_free()
	for slot in range(1, SaveSlots.COUNT + 1):
		add_child(_card(slot))


func _card(slot: int) -> Control:
	var v := UiKit.vbox(4)
	v.custom_minimum_size = Vector2(CARD_W, 0)
	var frame := PanelContainer.new()
	frame.theme_type_variation = &"ChipPanel"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(frame)
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(CARD_W - 16, 60)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	thumb.texture = SaveSlots.thumbnail(slot)
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(thumb)
	v.add_child(UiKit.label("Слот %d" % slot))
	v.add_child(UiKit.label(SaveSlots.modified_text(slot), &"DimLabel"))
	var save := UiKit.button("Сохранить")
	save.pressed.connect(func() -> void:
		save_requested.emit(slot)
		refresh())
	v.add_child(save)
	var load_btn := UiKit.button("Загрузить")
	load_btn.disabled = not SaveSlots.exists(slot)
	load_btn.pressed.connect(func() -> void: load_requested.emit(slot))
	v.add_child(load_btn)
	return v
