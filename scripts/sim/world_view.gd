class_name WorldView
extends Node2D
## Рендер мира и камера. Каждый кадр забирает RGBA8 из get_color_buffer в Image
## и обновляет ImageTexture. Камера — пан и зум (1×…6×) поверх базового масштаба,
## при котором весь мир вписан в «область вида» — свободное место между верхней
## полосой и шторкой. Когда область меняется (шторка открылась), вид плавно перестраивается.

const ZOOM_MIN := 1.0
const ZOOM_MAX := 6.0
const AREA_SPEED := 14.0

var sim: SimWorld
var zoom := 1.0

var _img: Image
var _tex: ImageTexture
var _sprite: Sprite2D
var _base_scale := 1.0
var _world_px := Vector2.ONE
var _offset := Vector2.ZERO
var _area := Rect2()
var _area_target := Rect2()
var _has_area := false


func setup(world: SimWorld) -> void:
	sim = world
	_world_px = Vector2(sim.get_width(), sim.get_height())
	_img = Image.create_empty(sim.get_width(), sim.get_height(), false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(_img)
	if _sprite == null:
		_sprite = Sprite2D.new()
		_sprite.centered = false
		_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_sprite)
	_sprite.texture = _tex
	if not _has_area:
		_area = Rect2(Vector2.ZERO, screen_size())
		_area_target = _area
	fit()


## Задать область вида (экранные координаты). animate=false — сразу, без анимации.
func set_area(rect: Rect2, animate: bool = true) -> void:
	if rect.size.x < 8.0 or rect.size.y < 8.0:
		return
	_has_area = true
	_area_target = rect
	if not animate or sim == null:
		_area = rect
		if sim != null:
			_refit_keep_focus()


func area() -> Rect2:
	return _area_target


func _process(delta: float) -> void:
	if sim == null or _area == _area_target:
		return
	var t := 1.0 - exp(-AREA_SPEED * delta)
	_area = Rect2(_area.position.lerp(_area_target.position, t), _area.size.lerp(_area_target.size, t))
	if _area.position.distance_to(_area_target.position) < 0.5 and _area.size.distance_to(_area_target.size) < 0.5:
		_area = _area_target
	_refit_keep_focus()


## Забрать буфер цвета из ядра и обновить текстуру.
func refresh(view_mode: int) -> void:
	var buf := sim.get_color_buffer(view_mode)
	var w := _img.get_width()
	var h := _img.get_height()
	if buf.size() != w * h * 4:
		return
	_img.set_data(w, h, false, Image.FORMAT_RGBA8, buf)
	_tex.update(_img)


## Текущий кадр мира как Image (для миниатюр сохранений).
func snapshot_image(view_mode: int = 0) -> Image:
	var buf := sim.get_color_buffer(view_mode)
	return Image.create_from_data(_img.get_width(), _img.get_height(), false, Image.FORMAT_RGBA8, buf)


func screen_size() -> Vector2:
	return get_viewport().get_visible_rect().size


## Сбросить камеру: весь мир в области вида.
func fit() -> void:
	_base_scale = _fit_scale(_area)
	zoom = ZOOM_MIN
	_offset = _area.position + (_area.size - _world_px * _base_scale) * 0.5
	_apply()


func _fit_scale(r: Rect2) -> float:
	return minf(r.size.x / _world_px.x, r.size.y / _world_px.y)


func _refit_keep_focus() -> void:
	# Точка мира в центре старой области остаётся в центре новой.
	var focus := (_area.get_center() - _offset) / cell_scale()
	_base_scale = _fit_scale(_area)
	_offset = _area.get_center() - focus * cell_scale()
	_apply()


func cell_scale() -> float:
	return _base_scale * zoom


func screen_to_cell(p: Vector2) -> Vector2i:
	var c := (p - _offset) / cell_scale()
	return Vector2i(floori(c.x), floori(c.y))


func cell_to_screen(c: Vector2) -> Vector2:
	return _offset + c * cell_scale()


func in_world(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < int(_world_px.x) and c.y < int(_world_px.y)


func pan(delta_screen: Vector2) -> void:
	_offset += delta_screen
	_apply()


func zoom_at(screen_p: Vector2, factor: float) -> void:
	var new_zoom := clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(new_zoom, zoom):
		return
	var world_p := (screen_p - _offset) / cell_scale()
	zoom = new_zoom
	_offset = screen_p - world_p * cell_scale()
	_apply()


func _apply() -> void:
	var size_px := _world_px * cell_scale()
	# Пан ограничен областью вида: мир меньше области — по центру, больше — без пустых краёв.
	for axis in 2:
		var a0: float = _area.position[axis]
		var a1: float = _area.end[axis]
		if size_px[axis] <= a1 - a0:
			_offset[axis] = a0 + (a1 - a0 - size_px[axis]) * 0.5
		else:
			_offset[axis] = clampf(_offset[axis], a1 - size_px[axis], a0)
	position = _offset
	scale = Vector2.ONE * cell_scale()
