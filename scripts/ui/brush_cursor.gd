class_name BrushCursor
extends Node2D
## Превью кисти: пиксельный кружок радиуса кисти в экранных координатах.

var center := Vector2.ZERO
var radius_px := 4.0
var color := Color(1, 1, 1, 0.85)
var finger := Vector2.ZERO
var show_finger_link := false


func set_cursor(p: Vector2, r_px: float, col: Color, finger_pos: Vector2, link: bool) -> void:
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
	if show_finger_link:
		draw_line(finger, center + (finger - center).normalized() * r, Color(1, 1, 1, 0.35), 1.0)
