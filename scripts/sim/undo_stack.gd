class_name UndoStack
extends RefCounted
## Стек снимков мира (save_bytes) для отмены. Хранит не больше limit снимков.

var limit := 20
var _items: Array[PackedByteArray] = []


func _init(max_items: int = 20) -> void:
	limit = max_items


func push(snapshot: PackedByteArray) -> void:
	if snapshot.is_empty():
		return
	_items.append(snapshot)
	while _items.size() > limit:
		_items.pop_front()


func pop() -> PackedByteArray:
	if _items.is_empty():
		return PackedByteArray()
	return _items.pop_back()


func size() -> int:
	return _items.size()


func is_empty() -> bool:
	return _items.is_empty()
