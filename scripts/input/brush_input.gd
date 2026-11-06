class_name BrushInput
extends Node
## Ввод в мир (только то, что не забрал интерфейс — _unhandled_input).
## ПК: ЛКМ рисует, ПКМ стирает, колесо — размер, Ctrl+колесо — зум, СКМ/пробел+мышь — пан,
## клавиши Space/F/H/1/2/3/Ctrl+Z/C. Тач: один палец рисует, два — пан и пинч-зум,
## тап двумя пальцами — отмена.

signal undo_requested
signal step_requested
signal clear_requested

const HEAT_WATTS := 900.0
const NEUTRONS_PER_SEC := 400.0
const FINGER_OFFSET := 56.0
const TWO_FINGER_TAP_MS := 300
const TWO_FINGER_TAP_MOVE := 14.0
const CANCEL_STROKE_MS := 220
const ZOOM_STEP := 1.15
const WIND_MAX := 120.0       # клеток/с
const WIND_GAIN := 1.0

var state: AppState
var sim: SimWorld
var view: WorldView
var hud: Hud
var undo: UndoStack
var cursor: BrushCursor
## Отладка тача на ПК: мышь рисует через эмулированные touch-события.
var touch_debug := false

## Где сейчас кисть (экранные координаты) и есть ли она вообще.
var pointer_pos := Vector2.ZERO
var pointer_valid := false

# Штрих.
var _stroke := false
var _stroke_erase := false
var _stroke_touch := false
var _stroke_index := -1
var _stroke_t0 := 0
var _last_cell := Vector2i.ZERO
var _finger_pos := Vector2.ZERO
var _neutron_acc := 0.0
var _wind_prev := Vector2.ZERO
var _wind_vel := Vector2.ZERO

# Пан мышью.
var _mouse_pan := false
var _space_held := false
var _space_dragged := false

# Тач.
var _touches: Dictionary = {}
var _gesture := false
var _g_dist := 1.0
var _g_center := Vector2.ZERO
var _g_t0 := 0
var _g_moved := 0.0
var _suppress_touch := false


func setup(app_state: AppState, world: SimWorld, world_view: WorldView, ui: Hud,
		undo_stack: UndoStack, brush_cursor: BrushCursor) -> void:
	state = app_state
	sim = world
	view = world_view
	hud = ui
	undo = undo_stack
	cursor = brush_cursor


func _process(delta: float) -> void:
	if _stroke:
		_apply_continuous(delta)
	_update_cursor()


# =========================================================================
# Маршрутизация
# =========================================================================

func _unhandled_input(event: InputEvent) -> void:
	if hud.modal.visible:
		return
	if event is InputEventKey:
		_on_key(event as InputEventKey)
		return
	var emulated := event.device == InputEvent.DEVICE_ID_EMULATION
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		# Эмулированный тач с мыши — только в режиме отладки тача.
		if emulated and not touch_debug:
			return
		if event is InputEventScreenTouch:
			_on_touch(event as InputEventScreenTouch)
		else:
			_on_drag(event as InputEventScreenDrag)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouse:
		# Мышь, эмулированная с тача, — дубль; в режиме отладки тача мышь тоже не рисует.
		if emulated or touch_debug:
			return
		if event is InputEventMouseButton:
			_on_mouse_button(event as InputEventMouseButton)
		elif event is InputEventMouseMotion:
			_on_mouse_motion(event as InputEventMouseMotion)
		return
	if event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		view.zoom_at(mg.position, mg.factor)
	elif event is InputEventPanGesture:
		var pg := event as InputEventPanGesture
		view.pan(-pg.delta * 8.0)


# =========================================================================
# Клавиатура
# =========================================================================

func _on_key(k: InputEventKey) -> void:
	if k.keycode == KEY_SPACE:
		if k.pressed and not k.echo:
			_space_held = true
			_space_dragged = false
		elif not k.pressed:
			_space_held = false
			if not _space_dragged:
				state.paused = not state.paused
				state.notify()
			_mouse_pan = false
		get_viewport().set_input_as_handled()
		return
	if not k.pressed or k.echo:
		return
	var handled := true
	if k.keycode == KEY_Z and k.is_command_or_control_pressed():
		undo_requested.emit()
	elif k.keycode == KEY_F:
		step_requested.emit()
	elif k.keycode == KEY_H:
		state.fast_heat = not state.fast_heat
		state.notify()
	elif k.keycode == KEY_1 or k.keycode == KEY_KP_1:
		state.view = 0
		state.notify()
	elif k.keycode == KEY_2 or k.keycode == KEY_KP_2:
		state.view = 1
		state.notify()
	elif k.keycode == KEY_3 or k.keycode == KEY_KP_3:
		state.view = 2
		state.notify()
	elif k.keycode == KEY_4 or k.keycode == KEY_KP_4:
		state.view = 3
		state.notify()
	elif k.keycode == KEY_C and not k.is_command_or_control_pressed():
		clear_requested.emit()
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()


# =========================================================================
# Мышь
# =========================================================================

func _on_mouse_button(mb: InputEventMouseButton) -> void:
	pointer_pos = mb.position
	pointer_valid = true
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if not mb.pressed:
				return
			var up := mb.button_index == MOUSE_BUTTON_WHEEL_UP
			if mb.is_command_or_control_pressed():
				view.zoom_at(mb.position, ZOOM_STEP if up else 1.0 / ZOOM_STEP)
			else:
				state.set_radius(state.brush_radius + (1 if up else -1))
				state.notify()
		MOUSE_BUTTON_MIDDLE:
			_mouse_pan = mb.pressed
		MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _space_held:
					_mouse_pan = true
					_space_dragged = true
				elif not hud.blocks_point(mb.position):
					_begin_stroke(mb.position, false, false, -1)
			else:
				if _space_held or _mouse_pan:
					_mouse_pan = false
				if _stroke and not _stroke_erase:
					_end_stroke()
		MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				if not hud.blocks_point(mb.position):
					_begin_stroke(mb.position, true, false, -1)
			elif _stroke and _stroke_erase:
				_end_stroke()


func _on_mouse_motion(mm: InputEventMouseMotion) -> void:
	pointer_pos = mm.position
	pointer_valid = not hud.blocks_point(mm.position) or _stroke
	if _mouse_pan:
		view.pan(mm.relative)
		if _space_held:
			_space_dragged = true
		return
	if _stroke:
		_move_stroke(mm.position)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_EXIT:
		if not _stroke:
			pointer_valid = false


# =========================================================================
# Тач
# =========================================================================

func _on_touch(t: InputEventScreenTouch) -> void:
	if t.pressed:
		if _touches.is_empty():
			_suppress_touch = false
		_touches[t.index] = t.position
		if _touches.size() == 1:
			if hud.blocks_point(t.position):
				_suppress_touch = true
				return
			_begin_stroke(t.position, false, true, t.index)
		elif _touches.size() == 2 and not _suppress_touch:
			# Второй палец: если штрих только начался — откатить его, это жест.
			if _stroke:
				if Time.get_ticks_msec() - _stroke_t0 < CANCEL_STROKE_MS:
					_cancel_stroke()
				else:
					_end_stroke()
			_begin_gesture()
		return
	# Отпускание.
	var was_gesture := _gesture
	_touches.erase(t.index)
	if was_gesture:
		var dt := Time.get_ticks_msec() - _g_t0
		if dt <= TWO_FINGER_TAP_MS and _g_moved < TWO_FINGER_TAP_MOVE:
			undo_requested.emit()
		_gesture = false
		_suppress_touch = true  # оставшийся палец не рисует до полного отпускания
	if _stroke and _stroke_touch and t.index == _stroke_index:
		_end_stroke()
	if _touches.is_empty():
		_suppress_touch = false
		pointer_valid = false


func _on_drag(d: InputEventScreenDrag) -> void:
	if not _touches.has(d.index):
		return
	_touches[d.index] = d.position
	if _gesture and _touches.size() >= 2:
		var pts := _two_points()
		var center := (pts[0] + pts[1]) * 0.5
		var dist := maxf(pts[0].distance_to(pts[1]), 1.0)
		view.pan(center - _g_center)
		view.zoom_at(center, dist / _g_dist)
		_g_moved += (center - _g_center).length() + absf(dist - _g_dist)
		_g_center = center
		_g_dist = dist
		return
	if _stroke and _stroke_touch and d.index == _stroke_index:
		_move_stroke(d.position)


func _begin_gesture() -> void:
	_gesture = true
	var pts := _two_points()
	_g_center = (pts[0] + pts[1]) * 0.5
	_g_dist = maxf(pts[0].distance_to(pts[1]), 1.0)
	_g_t0 = Time.get_ticks_msec()
	_g_moved = 0.0
	pointer_valid = false


func _two_points() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for k: Variant in _touches.keys():
		out.append(_touches[k])
		if out.size() == 2:
			break
	while out.size() < 2:
		out.append(out[0] if not out.is_empty() else Vector2.ZERO)
	return out


# =========================================================================
# Штрих
# =========================================================================

func _brush_point(screen_p: Vector2, from_touch: bool) -> Vector2:
	if from_touch and state.brush_offset:
		return screen_p + Vector2(0, -FINGER_OFFSET)
	return screen_p


func _begin_stroke(screen_p: Vector2, erase: bool, from_touch: bool, index: int) -> void:
	undo.push(sim.save_bytes())
	_stroke = true
	_stroke_erase = erase or state.tool == AppState.Tool.ERASER
	_stroke_touch = from_touch
	_stroke_index = index
	_stroke_t0 = Time.get_ticks_msec()
	_finger_pos = screen_p
	pointer_pos = _brush_point(screen_p, from_touch)
	pointer_valid = true
	_last_cell = view.screen_to_cell(pointer_pos)
	_neutron_acc = 0.0
	_wind_prev = _pointer_cell_f()
	_wind_vel = Vector2.ZERO
	_apply_at(_last_cell, _last_cell)


func _move_stroke(screen_p: Vector2) -> void:
	_finger_pos = screen_p
	pointer_pos = _brush_point(screen_p, _stroke_touch)
	var c := view.screen_to_cell(pointer_pos)
	if c != _last_cell:
		_apply_at(_last_cell, c)
		_last_cell = c


func _end_stroke() -> void:
	_stroke = false
	_stroke_index = -1
	if _stroke_touch:
		pointer_valid = false


## Откат только что начатого штриха (второй палец пришёл почти сразу).
func _cancel_stroke() -> void:
	_stroke = false
	_stroke_index = -1
	var snap := undo.pop()
	if not snap.is_empty():
		sim.load_bytes(snap)


func _paint_mode() -> int:
	return 1 if state.replace_mode else 0


func _apply_at(a: Vector2i, b: Vector2i) -> void:
	var r := state.brush_radius
	if _stroke_erase:
		sim.erase_line(a, b, r)
		return
	match state.tool:
		AppState.Tool.BRUSH:
			sim.paint_line(a, b, r, state.material, _paint_mode())


## Действия, которые идут, пока палец/кнопка зажаты (даже без движения).
func _apply_continuous(delta: float) -> void:
	var c := _last_cell
	var r := state.brush_radius
	if _stroke_erase:
		sim.erase_circle(c, r)
		return
	match state.tool:
		AppState.Tool.BRUSH:
			sim.paint_circle(c, r, state.material, _paint_mode())
		AppState.Tool.HEAT:
			sim.heat_circle(c, r, HEAT_WATTS, delta)
		AppState.Tool.COOL:
			sim.heat_circle(c, r, -HEAT_WATTS, delta)
		AppState.Tool.WIND:
			_apply_wind(delta)
		AppState.Tool.NEUTRON:
			_neutron_acc += NEUTRONS_PER_SEC * delta
			var n := int(_neutron_acc)
			if n > 0:
				_neutron_acc -= float(n)
				sim.spawn_neutrons(c, maxi(r, 1), n)


## Ветер: скорость штриха (клеток/с), сглаженная, уходит в add_air_impulse.
func _apply_wind(delta: float) -> void:
	var cur := _pointer_cell_f()
	if delta <= 0.0:
		return
	var v := (cur - _wind_prev) / delta
	_wind_prev = cur
	_wind_vel = _wind_vel.lerp(v, 0.5)
	if _wind_vel.length() < 2.0:
		return
	var vv := _wind_vel.limit_length(WIND_MAX) * WIND_GAIN
	sim.add_air_impulse(Vector2i(roundi(cur.x), roundi(cur.y)), maxi(state.brush_radius, 4), vv)


func _pointer_cell_f() -> Vector2:
	return (pointer_pos - view.position) / view.cell_scale()


func _update_cursor() -> void:
	if cursor == null:
		return
	if not pointer_valid or _gesture:
		cursor.visible = false
		return
	var r_px := (float(state.brush_radius) + 0.5) * view.cell_scale()
	var col := Color(1, 1, 1, 0.85)
	if _stroke_erase or state.tool == AppState.Tool.ERASER:
		col = Color(1.0, 0.45, 0.45, 0.9)
	elif state.tool == AppState.Tool.HEAT:
		col = Color(1.0, 0.6, 0.2, 0.9)
	elif state.tool == AppState.Tool.COOL:
		col = Color(0.5, 0.8, 1.0, 0.9)
	elif state.tool == AppState.Tool.NEUTRON:
		col = Color(0.6, 1.0, 1.0, 0.9)
	elif state.tool == AppState.Tool.WIND:
		col = Color(0.75, 0.95, 1.0, 0.9)
	cursor.set_cursor(pointer_pos, r_px, col, _finger_pos, _stroke and _stroke_touch and state.brush_offset)


## Клетка под кистью (для термометра) или (−1, −1).
func pointer_cell() -> Vector2i:
	if not pointer_valid:
		return Vector2i(-1, -1)
	return view.screen_to_cell(pointer_pos)
