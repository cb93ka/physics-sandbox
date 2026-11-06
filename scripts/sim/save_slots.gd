class_name SaveSlots
extends RefCounted
## Слоты сохранений в user://saves/: slot_N.sand (save_bytes) и slot_N.png (миниатюра).

const DIR := "user://saves"
const COUNT := 5
const THUMB_W := 160


static func _base(slot: int) -> String:
	return "%s/slot_%d" % [DIR, slot]


static func save(slot: int, data: PackedByteArray, preview: Image) -> bool:
	DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open(_base(slot) + ".sand", FileAccess.WRITE)
	if f == null:
		push_error("Не удалось открыть слот %d: %s" % [slot, error_string(FileAccess.get_open_error())])
		return false
	f.store_buffer(data)
	f.close()
	if preview != null and not preview.is_empty():
		var img := preview.duplicate() as Image
		var th := maxi(1, roundi(float(THUMB_W) * float(img.get_height()) / float(img.get_width())))
		img.resize(THUMB_W, th, Image.INTERPOLATE_NEAREST)
		img.save_png(_base(slot) + ".png")
	return true


static func load_data(slot: int) -> PackedByteArray:
	var path := _base(slot) + ".sand"
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


static func exists(slot: int) -> bool:
	return FileAccess.file_exists(_base(slot) + ".sand")


static func modified_text(slot: int) -> String:
	var path := _base(slot) + ".sand"
	if not FileAccess.file_exists(path):
		return "пусто"
	var t := FileAccess.get_modified_time(path)
	var d := Time.get_datetime_dict_from_unix_time(int(t) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60)
	return "%02d.%02d %02d:%02d" % [int(d["day"]), int(d["month"]), int(d["hour"]), int(d["minute"])]


static func thumbnail(slot: int) -> Texture2D:
	var path := _base(slot) + ".png"
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)
