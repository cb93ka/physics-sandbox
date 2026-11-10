class_name MaterialsLoader
extends RefCounted
## Грузит data/materials.json и data/reactions.json и отдаёт их в ядро.
## Если materials.json ещё нет или он битый — берёт встроенный набор из SandWorldMock.

const MATERIALS_PATH := "res://data/materials.json"
const REACTIONS_PATH := "res://data/reactions.json"

var materials: Dictionary = {}
var reactions: Dictionary = {}
var from_builtin := false


static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var json := JSON.new()
	if json.parse(text) != OK:
		push_error("%s: ошибка JSON в строке %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return {}
	if not (json.data is Dictionary):
		push_error("%s: ожидался объект в корне" % path)
		return {}
	return json.data


func load_all() -> void:
	materials = read_json(MATERIALS_PATH)
	from_builtin = materials.is_empty() or not materials.has("materials")
	if from_builtin:
		push_warning("%s не найден — используется встроенный набор материалов" % MATERIALS_PATH)
		materials = SandWorldMock.builtin_data()
		reactions = {"version": 1, "reactions": []}
	else:
		reactions = read_json(REACTIONS_PATH)
		if reactions.is_empty():
			reactions = {"version": 1, "reactions": []}


## Передаёт данные в ядро. Возвращает false, если ядро отвергло схему.
func apply_to(world: SimWorld) -> bool:
	if not world.load_materials(materials):
		push_error("Ядро отвергло materials.json — пробую встроенный набор")
		materials = SandWorldMock.builtin_data()
		reactions = {"version": 1, "reactions": []}
		from_builtin = true
		if not world.load_materials(materials):
			return false
	if not world.load_reactions(reactions):
		push_error("Ядро отвергло reactions.json")
	return true


func ambient_temp() -> float:
	return float(materials.get("ambient_temp", 20.0))


## Категории в порядке файла: [{id, name}].
func categories() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var arr: Array = materials.get("categories", [])
	for c: Variant in arr:
		if c is Dictionary:
			var d: Dictionary = c
			out.append({"id": str(d.get("id", "")), "name": str(d.get("name", d.get("id", "")))})
	return out


## Палитра для UI: [{index, key, name, category, desc, color, hidden, state}].
## key — строковый id материала (для настроек и «Недавних»).
static func build_palette(world: SimWorld) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in world.get_material_count():
		var info := world.get_material_info(i)
		if info.is_empty():
			continue
		# Ключ — строковый id материала (str_id у ядра; у старой заглушки id строкой).
		var key := str(info.get("str_id", ""))
		if key == "":
			var raw_id: Variant = info.get("id", i)
			key = str(raw_id) if raw_id is String or raw_id is StringName else str(info.get("name", i))
		var col: Color = Color.MAGENTA
		var c: Variant = info.get("color", Color.MAGENTA)
		if c is Color:
			col = c
		elif c is String:
			col = Color.from_string(str(c), Color.MAGENTA)
		out.append({
			"index": i, "key": key, "name": str(info.get("name", key)),
			"category": str(info.get("category", "")), "desc": str(info.get("desc", "")),
			"color": col, "hidden": bool(info.get("hidden", false)), "state": str(info.get("state", "")),
		})
	return out
