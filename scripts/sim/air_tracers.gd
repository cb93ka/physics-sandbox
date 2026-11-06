class_name AirTracers
extends Node2D
## Вид «Потоки воздуха»: трассеры как на карте ветра. Частицы переносятся по
## get_air_velocity() (билинейно), каждую секунду кадр рисует только короткие
## отрезки «было → стало» в SubViewport, который не очищается, а гаснет умножением
## (буфер HDR, без 8-битных «призраков»).
## Так получаются плавные затухающие хвосты в экранном разрешении за один draw-вызов.

const COUNT_DESKTOP := 2400
const COUNT_MOBILE := 1600
const SPEED_REF := 30.0      # |v| (клеток/с), при которой трассер самый яркий
const FADE := 0.90           # доля яркости хвоста, остающаяся через кадр (при 60 FPS)
const SPEED_MUL := 1.3       # трассеры чуть быстрее воздуха — нагляднее

var sim: SimWorld
var view: WorldView
var active := false

var _vp: SubViewport
var _painter: _Painter
var _fader: _Fader
var _display: Sprite2D
var _pos := PackedVector2Array()
var _life := PackedFloat32Array()
var _rng := RandomNumberGenerator.new()
var _px_scale := 1.0
var _last_cam := Vector3.ZERO


class _Painter extends Node2D:
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	var width := 1.5

	func _draw() -> void:
		if points.size() >= 2:
			draw_multiline_colors(points, colors, width, true)


class _Fader extends Node2D:
	var size_px := Vector2.ONE
	var keep := 0.9

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size_px), Color(keep, keep, keep, keep))


func setup(world: SimWorld, world_view: WorldView) -> void:
	sim = world
	view = world_view
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.disable_3d = true
	_vp.use_hdr_2d = true
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	_fader = _Fader.new()
	var sub := CanvasItemMaterial.new()
	sub.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	_fader.material = sub
	_vp.add_child(_fader)
	_painter = _Painter.new()
	_vp.add_child(_painter)
	_display = Sprite2D.new()
	_display.centered = false
	_display.texture = _vp.get_texture()
	_display.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var pm := CanvasItemMaterial.new()
	pm.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	_display.material = pm
	add_child(_display)
	var n := COUNT_MOBILE if OS.has_feature("mobile") else COUNT_DESKTOP
	_pos.resize(n)
	_life.resize(n)
	for k in n:
		_respawn(k)
	_resize()
	get_viewport().size_changed.connect(_resize)
	set_active(false)


func set_active(on: bool) -> void:
	on = on and sim != null and sim.has_air
	active = on
	visible = on
	if _vp != null:
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
		if on:
			_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE


func _resize() -> void:
	var logical := get_viewport().get_visible_rect().size
	var win := Vector2(DisplayServer.window_get_size())
	if DisplayServer.get_name() == "headless" or win.x <= 0.0:
		win = logical
	# Буфер хвостов — в физическом разрешении окна (гладко на ретине), но не больше 2560.
	_px_scale = clampf(win.x / maxf(logical.x, 1.0), 1.0, 2560.0 / maxf(logical.x, 1.0))
	_vp.size = Vector2i(ceili(logical.x * _px_scale), ceili(logical.y * _px_scale))
	_fader.size_px = Vector2(_vp.size)
	_painter.width = 1.4 * _px_scale
	_display.scale = Vector2.ONE / _px_scale
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE


func _respawn(k: int) -> void:
	_pos[k] = Vector2(_rng.randf() * float(sim.get_width()), _rng.randf() * float(sim.get_height()))
	_life[k] = _rng.randf_range(1.0, 4.0)


func _process(delta: float) -> void:
	if not active:
		return
	var grid := sim.get_air_grid_size()
	var vel := sim.get_air_velocity()
	var gw := grid.x
	var gh := grid.y
	if gw < 2 or gh < 2 or vel.size() < gw * gh * 2:
		_painter.points = PackedVector2Array()
		_painter.queue_redraw()
		return
	# Камера сдвинулась — старые хвосты стираем, иначе они «смазываются».
	var cam := Vector3(view.position.x, view.position.y, view.cell_scale())
	if cam.distance_to(_last_cam) > 0.5:
		_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
		_last_cam = cam
	var inv := 1.0 / float(sim.get_air_cell_scale())
	var w := float(sim.get_width())
	var h := float(sim.get_height())
	var off := view.position * _px_scale
	var cs := view.cell_scale() * _px_scale
	var dt := minf(delta, 0.05) * SPEED_MUL
	var n := _pos.size()
	var pts := PackedVector2Array()
	pts.resize(n * 2)
	var cols := PackedColorArray()
	cols.resize(n)
	var seg := 0
	var gmax_x := float(gw) - 1.001
	var gmax_y := float(gh) - 1.001
	for k in n:
		var p := _pos[k]
		# Билинейная выборка скорости (центры ячеек поля — в +0.5).
		var gx := clampf(p.x * inv - 0.5, 0.0, gmax_x)
		var gy := clampf(p.y * inv - 0.5, 0.0, gmax_y)
		var x0 := int(gx)
		var y0 := int(gy)
		var fx := gx - float(x0)
		var fy := gy - float(y0)
		var i := (y0 * gw + x0) * 2
		var j := i + gw * 2
		var vx := lerpf(lerpf(vel[i], vel[i + 2], fx), lerpf(vel[j], vel[j + 2], fx), fy)
		var vy := lerpf(lerpf(vel[i + 1], vel[i + 3], fx), lerpf(vel[j + 1], vel[j + 3], fx), fy)
		var np := Vector2(p.x + vx * dt, p.y + vy * dt)
		var l := _life[k] - delta
		if l <= 0.0 or np.x < 0.0 or np.y < 0.0 or np.x >= w or np.y >= h:
			_respawn(k)
			continue
		_life[k] = l
		_pos[k] = np
		var sp2 := vx * vx + vy * vy
		if sp2 < 0.09:
			continue
		var a := clampf(sqrt(sp2) / SPEED_REF, 0.12, 1.0)
		pts[seg * 2] = off + p * cs
		pts[seg * 2 + 1] = off + np * cs
		cols[seg] = Color(0.78, 0.95, 1.0, a)
		seg += 1
	pts.resize(seg * 2)
	cols.resize(seg)
	_painter.points = pts
	_painter.colors = cols
	_painter.queue_redraw()
	# Затухание не зависит от FPS: за 1/60 с остаётся FADE.
	_fader.keep = pow(FADE, minf(delta, 0.1) * 60.0)
	_fader.queue_redraw()
