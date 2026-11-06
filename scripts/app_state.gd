class_name AppState
extends RefCounted
## Общее состояние приложения: инструмент, материал, режимы, настройки.
## UI и ввод меняют поля и вызывают notify(); main реагирует на сигнал changed.

signal changed

enum Tool { BRUSH, ERASER, HEAT, COOL, NEUTRON }

const SETTINGS_PATH := "user://settings.cfg"
const RECENT_MAX := 6
const RADIUS_MIN := 0
const RADIUS_MAX := 30

var paused := false
var fast_heat := false
var view := 0
var tool: Tool = Tool.BRUSH
var material := 1
var replace_mode := false
var brush_radius := 4

# Настройки (сохраняются).
var brush_offset := true
var show_stats := true
var tilt_gravity := false
var haptics := true
var recent: Array[String] = []


func notify() -> void:
	changed.emit()


func set_radius(r: int) -> void:
	brush_radius = clampi(r, RADIUS_MIN, RADIUS_MAX)


func push_recent(key: String) -> void:
	recent.erase(key)
	recent.push_front(key)
	while recent.size() > RECENT_MAX:
		recent.pop_back()


func load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK:
		return
	brush_offset = bool(cf.get_value("input", "brush_offset", brush_offset))
	show_stats = bool(cf.get_value("ui", "show_stats", show_stats))
	tilt_gravity = bool(cf.get_value("input", "tilt_gravity", tilt_gravity))
	haptics = bool(cf.get_value("input", "haptics", haptics))
	brush_radius = clampi(int(cf.get_value("brush", "radius", brush_radius)), RADIUS_MIN, RADIUS_MAX)
	var rec: Variant = cf.get_value("brush", "recent", PackedStringArray())
	recent.clear()
	if rec is PackedStringArray or rec is Array:
		for s: Variant in rec:
			recent.append(str(s))


func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("input", "brush_offset", brush_offset)
	cf.set_value("ui", "show_stats", show_stats)
	cf.set_value("input", "tilt_gravity", tilt_gravity)
	cf.set_value("input", "haptics", haptics)
	cf.set_value("brush", "radius", brush_radius)
	cf.set_value("brush", "recent", PackedStringArray(recent))
	cf.save(SETTINGS_PATH)
