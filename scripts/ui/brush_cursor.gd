class_name BrushCursor
extends Node2D
## Превью кисти: пиксельный кружок радиуса кисти в экранных координатах.

var center := Vector2.ZERO
var radius_px := 4.0
var color := Color(1, 1, 1, 0.85)
var finger := Vector2.ZERO
var show_finger_link := false
## Прицел вокруг пальца для инструментов без смещения (нагрев, охлаждение, нейтроны, ветер).
var finger_ring := false


func set_cursor(p: Vector2, r_px: float, col: Color, finger_pos: Vector2, link: bool, ring: bool = false) -> void:
	finger_ring = ring
	center = p
	radius_px = r_px
	color = col
	finger = finger_pos
	show_finger_link = link
	visible = true
	queue_redraw()


func _draw() -> void:
	var r := maxf(radius_px, 2.0)
	draw_arc(center, r + 1.0, 0.0, TAU, 48, Color(0, 0, 0, 0.7), 3.0, false)
	draw_arc(center, r, 0.0, TAU, 48, color, 1.5, false)
	draw_rect(Rect2(center - Vector2(1, 1), Vector2(2, 2)), color)
	if finger_ring:
		# Палец закрывает точку — рисуем кольцо-прицел шире пальца с рисками к центру.
		var fr := maxf(r + 12.0, 34.0)
		draw_arc(center, fr + 1.5, 0.0, TAU, 64, Color(0, 0, 0, 0.6), 5.0, true)
		draw_arc(center, fr, 0.0, TAU, 64, Color(color, 0.95), 2.5, true)
		for k in 4:
			var d := Vector2.from_angle(float(k) * PI * 0.5)
			draw_line(center + d * (fr + 2.0), center + d * (fr + 12.0), Color(color, 0.95), 2.5, true)
	if show_finger_link:
		draw_line(finger, center + (finger - center).normalized() * r, Color(1, 1, 1, 0.35), 1.0)
