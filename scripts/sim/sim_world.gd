class_name SimWorld
extends RefCounted
## Типизированная обёртка над ядром. Если GDExtension загружен (класс SandWorld есть
## в ClassDB) — работает с ним, иначе с GDScript-заглушкой SandWorldMock.
## Методы повторяют docs/api.md один в один.

var is_native := false
## Ядро умеет поле воздуха (v0.1.1). Без него вид «Воздух» работает без трассеров.
var has_air := false
var has_air_layer := false
## Ядро должно было быть, но не загрузилось (не редактор, не --mock).
var core_failed := false
var _w: Variant


func _init(force_mock: bool = false) -> void:
	if ClassDB.class_exists("SandWorld") and not force_mock:
		_w = ClassDB.instantiate("SandWorld")
		is_native = true
	else:
		push_warning("SandWorld (GDExtension) не найден — работает медленная заглушка SandWorldMock")
		_w = SandWorldMock.new()
		if not force_mock:
			core_failed = true
			print("Physics: ядро не загружено")
	var obj := _w as Object
	has_air = obj.has_method("get_air_velocity") and obj.has_method("get_air_grid_size")
	has_air_layer = obj.has_method("get_air_layer")
	if not has_air:
		push_warning("Ядро без поля воздуха (get_air_*) — вид «Воздух» без трассеров, ветер выключен")


func load_materials(data: Dictionary) -> bool:
	return bool(_w.load_materials(data))


func load_reactions(data: Dictionary) -> bool:
	return bool(_w.load_reactions(data))


func setup(width: int, height: int) -> void:
	_w.setup(width, height)


func get_width() -> int:
	return int(_w.get_width())


func get_height() -> int:
	return int(_w.get_height())


func get_material_count() -> int:
	return int(_w.get_material_count())


func get_material_info(id: int) -> Dictionary:
	return _w.get_material_info(id)


func find_material(str_id: String) -> int:
	return int(_w.find_material(str_id))


func step(delta: float) -> void:
	_w.step(delta)


func step_once() -> void:
	_w.step_once()


func set_heat_multiplier(m: float) -> void:
	_w.set_heat_multiplier(m)


func set_gravity(dir: Vector2) -> void:
	_w.set_gravity(dir)


func set_ambient_temp(c: float) -> void:
	_w.set_ambient_temp(c)


func clear() -> void:
	_w.clear()


func paint_circle(c: Vector2i, r: int, mat: int, mode: int) -> void:
	_w.paint_circle(c, r, mat, mode)


func paint_line(a: Vector2i, b: Vector2i, r: int, mat: int, mode: int) -> void:
	_w.paint_line(a, b, r, mat, mode)


func erase_circle(c: Vector2i, r: int) -> void:
	_w.erase_circle(c, r)


func heat_circle(c: Vector2i, r: int, watts: float, delta: float) -> void:
	_w.heat_circle(c, r, watts, delta)


func spawn_neutrons(c: Vector2i, r: int, count: int) -> void:
	_w.spawn_neutrons(c, r, count)


func get_color_buffer(view: int) -> PackedByteArray:
	return _w.get_color_buffer(view)


func get_cell(p: Vector2i) -> Dictionary:
	return _w.get_cell(p)


func get_stats() -> Dictionary:
	return _w.get_stats()


func save_bytes() -> PackedByteArray:
	return _w.save_bytes()


func load_bytes(data: PackedByteArray) -> bool:
	return bool(_w.load_bytes(data))


## Стирание вдоль отрезка: в API есть только erase_circle, поэтому шагаем сами.
func erase_line(a: Vector2i, b: Vector2i, r: int) -> void:
	var d := Vector2(b - a)
	var steps := maxi(1, int(ceilf(d.length() / maxf(1.0, float(r) * 0.75))))
	for s in range(steps + 1):
		var p := Vector2(a) + d * (float(s) / float(steps))
		erase_circle(Vector2i(roundi(p.x), roundi(p.y)), r)


# --- Поле воздуха (v0.1.1). Если ядро старое — безопасные заглушки. ---

func get_air_grid_size() -> Vector2i:
	return _w.get_air_grid_size() if has_air else Vector2i.ZERO


func get_air_velocity() -> PackedFloat32Array:
	return _w.get_air_velocity() if has_air else PackedFloat32Array()


func get_air_cell_scale() -> int:
	if has_air and (_w as Object).has_method("get_air_cell_scale"):
		return int(_w.get_air_cell_scale())
	return 4


func add_air_impulse(c: Vector2i, r: int, v: Vector2) -> void:
	if has_air and (_w as Object).has_method("add_air_impulse"):
		_w.add_air_impulse(c, r, v)


func set_air_enabled(on: bool) -> void:
	if has_air and (_w as Object).has_method("set_air_enabled"):
		_w.set_air_enabled(on)


func get_air_layer(view: int) -> PackedByteArray:
	return _w.get_air_layer(view) if has_air_layer else PackedByteArray()
