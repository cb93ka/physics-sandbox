class_name SandWorldMock
extends RefCounted
## Медленная GDScript-заглушка ядра SandWorld с тем же API (docs/api.md).
## Нужна, пока C++ GDExtension не собран: сыпучие, жидкости, газы, грубое тепло,
## простые фазовые переходы и игрушечные нейтроны. Гравитация — только вниз/вверх.

const FIXED_DT := 1.0 / 60.0
const MAX_STEPS_PER_CALL := 2
const MAX_NEUTRONS := 4000
const HEAT_BANDS := 4

enum St { EMPTY, SOLID, POWDER, LIQUID, GAS, FIRE }

var _w := 0
var _h := 0
var _ambient := 20.0
var _heat_mul := 1.0
var _gravity_up := false
var _acc := 0.0
var _step_no := 0
var _heat_band := 0
var _rng := RandomNumberGenerator.new()

# --- Таблицы материалов (индекс = id) ---
var _ids := PackedStringArray()
var _names := PackedStringArray()
var _cats := PackedStringArray()
var _state_names := PackedStringArray()
var _descs := PackedStringArray()
var _state := PackedInt32Array()
var _density := PackedFloat32Array()
var _heat_cap := PackedFloat32Array()
var _cond_k := PackedFloat32Array()
var _init_temp := PackedFloat32Array()
var _fixed_temp := PackedFloat32Array()
var _has_fixed := PackedByteArray()
var _hidden := PackedByteArray()
var _palette: Array[PackedByteArray] = []
var _first_color: Array[Color] = []
var _life_min := PackedFloat32Array()
var _life_max := PackedFloat32Array()
var _decay_into := PackedInt32Array()
var _fissile := PackedFloat32Array()
var _absorb := PackedFloat32Array()
# Фазовые переходы: порог и во что (−1 — нет).
var _melt_t := PackedFloat32Array()
var _melt_into := PackedInt32Array()
var _freeze_t := PackedFloat32Array()
var _freeze_into := PackedInt32Array()
var _boil_t := PackedFloat32Array()
var _boil_into := PackedInt32Array()
var _cond_t := PackedFloat32Array()
var _cond_into := PackedInt32Array()

# --- Сетка ---
var _mat := PackedByteArray()
var _temp := PackedFloat32Array()
var _life := PackedFloat32Array()
var _rgba := PackedByteArray()
var _stamp := PackedInt32Array()
var _row_active := PackedByteArray()
var _row_hot := PackedByteArray()
var _row_max := PackedFloat32Array()

# --- Нейтроны ---
var _n_pos := PackedVector2Array()
var _n_vel := PackedVector2Array()
var _n_life := PackedFloat32Array()
var _fissions_window := 0
var _fission_timer := 0.0
var _fissions_per_sec := 0.0
var _last_step_ms := 0.0


# =========================================================================
# Инициализация
# =========================================================================

func load_materials(data: Dictionary) -> bool:
	var arr: Array = data.get("materials", [])
	if arr.is_empty():
		push_error("SandWorldMock: в materials нет массива materials")
		return false
	_ambient = float(data.get("ambient_temp", 20.0))
	var index := {}
	for i in arr.size():
		var m: Dictionary = arr[i]
		index[str(m.get("id", ""))] = i
	_ids.clear(); _names.clear(); _cats.clear(); _state_names.clear(); _descs.clear()
	_state.clear(); _density.clear(); _heat_cap.clear(); _cond_k.clear(); _init_temp.clear()
	_fixed_temp.clear(); _has_fixed.clear(); _hidden.clear(); _palette.clear(); _first_color.clear()
	_life_min.clear(); _life_max.clear(); _decay_into.clear(); _fissile.clear(); _absorb.clear()
	_melt_t.clear(); _melt_into.clear(); _freeze_t.clear(); _freeze_into.clear()
	_boil_t.clear(); _boil_into.clear(); _cond_t.clear(); _cond_into.clear()
	for i in arr.size():
		var m: Dictionary = arr[i]
		_ids.append(str(m.get("id", "m%d" % i)))
		_names.append(str(m.get("name", _ids[i])))
		_cats.append(str(m.get("category", "special")))
		var st_name := str(m.get("state", "solid"))
		_state_names.append(st_name)
		_descs.append(str(m.get("desc", "")))
		_state.append(_parse_state(st_name))
		_density.append(float(m.get("density", 1000.0)))
		_heat_cap.append(maxf(1.0, float(m.get("heat_capacity", 1000.0))))
		_cond_k.append(_conductivity_factor(float(m.get("conductivity", 1.0))))
		_init_temp.append(float(m.get("initial_temp", _ambient)))
		_has_fixed.append(1 if m.has("fixed_temp") else 0)
		_fixed_temp.append(float(m.get("fixed_temp", 0.0)))
		_hidden.append(1 if bool(m.get("hidden", false)) else 0)
		var cols: Array = m.get("colors", ["#ff00ff"])
		var pal := PackedByteArray()
		for c: Variant in cols:
			var col := Color.from_string(str(c), Color.MAGENTA)
			pal.append(col.r8); pal.append(col.g8); pal.append(col.b8); pal.append(255)
		if pal.is_empty():
			pal = PackedByteArray([255, 0, 255, 255])
		_palette.append(pal)
		_first_color.append(Color.from_string(str(cols[0]) if not cols.is_empty() else "#ff00ff", Color.MAGENTA))
		var lt: Array = m.get("lifetime", [])
		_life_min.append(float(lt[0]) if lt.size() >= 1 else -1.0)
		_life_max.append(float(lt[1]) if lt.size() >= 2 else _life_min[i])
		_decay_into.append(int(index.get(str(m.get("decay_into", "air")), 0)))
		var nuc: Dictionary = m.get("nuclear", {})
		_fissile.append(maxf(float(nuc.get("fissile", 0.0)), float(nuc.get("fast_fission", 0.0))))
		_absorb.append(float(nuc.get("absorb", 0.0)))
		_add_transition(m, "melt", index, _melt_t, _melt_into)
		_add_transition(m, "freeze", index, _freeze_t, _freeze_into)
		_add_transition(m, "boil", index, _boil_t, _boil_into)
		_add_transition(m, "condense", index, _cond_t, _cond_into)
	return true


func load_reactions(_data: Dictionary) -> bool:
	# Заглушка реакции не считает.
	return true


func setup(width: int, height: int) -> void:
	_w = maxi(1, width)
	_h = maxi(1, height)
	var n := _w * _h
	_mat = PackedByteArray(); _mat.resize(n)
	_temp = PackedFloat32Array(); _temp.resize(n); _temp.fill(_ambient)
	_life = PackedFloat32Array(); _life.resize(n); _life.fill(-1.0)
	_stamp = PackedInt32Array(); _stamp.resize(n)
	_rgba = PackedByteArray(); _rgba.resize(n * 4)
	_row_active = PackedByteArray(); _row_active.resize(_h)
	_row_hot = PackedByteArray(); _row_hot.resize(_h)
	_row_max = PackedFloat32Array(); _row_max.resize(_h); _row_max.fill(_ambient)
	for i in n:
		_write_color(i, 0)
	_n_pos.clear(); _n_vel.clear(); _n_life.clear()


func get_width() -> int:
	return _w


func get_height() -> int:
	return _h


func get_material_count() -> int:
	return _ids.size()


func get_material_info(id: int) -> Dictionary:
	if id < 0 or id >= _ids.size():
		return {}
	return {
		"id": _ids[id], "name": _names[id], "category": _cats[id], "state": _state_names[id],
		"desc": _descs[id], "color": _first_color[id], "hidden": _hidden[id] != 0,
	}


func find_material(str_id: String) -> int:
	return _ids.find(str_id)


# =========================================================================
# Симуляция
# =========================================================================

func step(delta: float) -> void:
	_acc += delta
	var n := 0
	var t0 := Time.get_ticks_usec()
	while _acc >= FIXED_DT and n < MAX_STEPS_PER_CALL:
		_do_step()
		_acc -= FIXED_DT
		n += 1
	if _acc > FIXED_DT * 4.0:
		_acc = 0.0
	if n > 0:
		_last_step_ms = float(Time.get_ticks_usec() - t0) / 1000.0 / float(n)


func step_once() -> void:
	var t0 := Time.get_ticks_usec()
	_do_step()
	_last_step_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func set_heat_multiplier(m: float) -> void:
	_heat_mul = maxf(0.0, m)


func set_gravity(dir: Vector2) -> void:
	_gravity_up = dir.y < -0.5
	_wake_all()


func set_ambient_temp(c: float) -> void:
	_ambient = c


func clear() -> void:
	setup(_w, _h)


# =========================================================================
# Рисование
# =========================================================================

func paint_circle(c: Vector2i, r: int, mat: int, mode: int) -> void:
	if mat < 0 or mat >= _ids.size():
		return
	var rr := r * r + r
	for dy in range(-r, r + 1):
		var y := c.y + dy
		if y < 0 or y >= _h:
			continue
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > rr:
				continue
			var x := c.x + dx
			if x < 0 or x >= _w:
				continue
			var i := y * _w + x
			if mode == 0 and _mat[i] != 0:
				continue
			_set_cell(i, mat, _init_temp[mat])
		_wake(y)


func paint_line(a: Vector2i, b: Vector2i, r: int, mat: int, mode: int) -> void:
	var d := Vector2(b - a)
	var steps := maxi(1, int(ceilf(d.length() / maxf(1.0, float(r) * 0.75))))
	for s in range(steps + 1):
		var p := Vector2(a) + d * (float(s) / float(steps))
		paint_circle(Vector2i(roundi(p.x), roundi(p.y)), r, mat, mode)


func erase_circle(c: Vector2i, r: int) -> void:
	var rr := r * r + r
	for dy in range(-r, r + 1):
		var y := c.y + dy
		if y < 0 or y >= _h:
			continue
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > rr:
				continue
			var x := c.x + dx
			if x < 0 or x >= _w:
				continue
			_set_cell(y * _w + x, 0, _ambient)
		_wake(y)


func heat_circle(c: Vector2i, r: int, watts: float, delta: float) -> void:
	var rr := r * r + r
	var joules := watts * delta * _heat_mul
	for dy in range(-r, r + 1):
		var y := c.y + dy
		if y < 0 or y >= _h:
			continue
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > rr:
				continue
			var x := c.x + dx
			if x < 0 or x >= _w:
				continue
			var i := y * _w + x
			var m := _mat[i]
			if _has_fixed[m] != 0:
				continue
			# Масса клетки 1 см³: ρ·1e-6 кг.
			var cap := _density[m] * 1.0e-6 * _heat_cap[m]
			var dt := clampf(joules / maxf(cap, 1.0e-4), -60.0, 60.0)
			_temp[i] = clampf(_temp[i] + dt, -273.0, 6000.0)
		_row_hot[y] = 1


func spawn_neutrons(c: Vector2i, r: int, count: int) -> void:
	for k in count:
		if _n_pos.size() >= MAX_NEUTRONS:
			return
		var off := Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * float(r)
		var ang := _rng.randf() * TAU
		_n_pos.append(Vector2(c) + off + Vector2(0.5, 0.5))
		_n_vel.append(Vector2(cos(ang), sin(ang)) * 1.6)
		_n_life.append(_rng.randf_range(1.0, 2.0))


# =========================================================================
# Чтение состояния
# =========================================================================

func get_color_buffer(view: int) -> PackedByteArray:
	var buf: PackedByteArray
	if view == 1:
		buf = PackedByteArray()
		buf.resize(_w * _h * 4)
		for i in _w * _h:
			var col := _thermal_color(_temp[i])
			var o := i * 4
			buf[o] = col.r8; buf[o + 1] = col.g8; buf[o + 2] = col.b8; buf[o + 3] = 255
		return buf
	buf = _rgba.duplicate()
	if view == 2:
		for o in range(0, buf.size(), 4):
			buf[o] = buf[o] >> 2
			buf[o + 1] = buf[o + 1] >> 2
			buf[o + 2] = buf[o + 2] >> 2
	for p in _n_pos:
		var x := int(p.x)
		var y := int(p.y)
		if x >= 0 and y >= 0 and x < _w and y < _h:
			var o := (y * _w + x) * 4
			buf[o] = 170; buf[o + 1] = 255; buf[o + 2] = 255
	return buf


func get_cell(p: Vector2i) -> Dictionary:
	if p.x < 0 or p.y < 0 or p.x >= _w or p.y >= _h:
		return {"mat": -1, "temp": _ambient, "name": ""}
	var i := p.y * _w + p.x
	var m := _mat[i]
	return {"mat": int(m), "temp": _temp[i], "name": _names[m]}


func get_stats() -> Dictionary:
	var active := 0
	var mx := -273.0
	for y in _h:
		active += _row_active[y]
		mx = maxf(mx, _row_max[y])
	return {
		"step_ms": _last_step_ms, "active_chunks": active, "neutrons": _n_pos.size(),
		"fissions_per_sec": _fissions_per_sec, "max_temp": mx,
	}


# =========================================================================
# Сохранение
# =========================================================================

func save_bytes() -> PackedByteArray:
	var d := {
		"format": "sandworld_mock", "version": 1, "w": _w, "h": _h,
		"ids": _ids, "mat": _mat, "temp": _temp,
	}
	return var_to_bytes(d)


func load_bytes(data: PackedByteArray) -> bool:
	if data.is_empty():
		return false
	var v: Variant = bytes_to_var(data)
	if not (v is Dictionary):
		return false
	var d: Dictionary = v
	if str(d.get("format", "")) != "sandworld_mock":
		return false
	var w := int(d.get("w", 0))
	var h := int(d.get("h", 0))
	var ids: PackedStringArray = d.get("ids", PackedStringArray())
	var mat: PackedByteArray = d.get("mat", PackedByteArray())
	var temp: PackedFloat32Array = d.get("temp", PackedFloat32Array())
	if w <= 0 or h <= 0 or mat.size() != w * h or temp.size() != w * h:
		return false
	var remap := PackedInt32Array()
	for s in ids:
		remap.append(maxi(0, _ids.find(s)))
	setup(w, h)
	for i in w * h:
		var src := int(mat[i])
		var m := remap[src] if src < remap.size() else 0
		_set_cell(i, m, temp[i])
	_wake_all()
	for y in _h:
		_row_hot[y] = 1
	return true


# =========================================================================
# Внутренности
# =========================================================================

static func _parse_state(s: String) -> int:
	match s:
		"empty": return St.EMPTY
		"powder": return St.POWDER
		"liquid": return St.LIQUID
		"gas": return St.GAS
		"fire": return St.FIRE
	return St.SOLID


static func _conductivity_factor(k: float) -> float:
	# Грубое отображение теплопроводности в коэффициент диффузии 0.01…0.24.
	return clampf(sqrt(maxf(k, 0.0)) / 6.0, 0.01, 0.24)


static func _add_transition(m: Dictionary, key: String, index: Dictionary,
		temps: PackedFloat32Array, intos: PackedInt32Array) -> void:
	var tr: Dictionary = m.get(key, {})
	if tr.is_empty() or not index.has(str(tr.get("into", ""))):
		temps.append(0.0)
		intos.append(-1)
		return
	temps.append(float(tr.get("temp", 0.0)))
	intos.append(int(index[str(tr.get("into", ""))]))


func _write_color(i: int, m: int) -> void:
	var pal := _palette[m]
	var k := (_rng.randi() % (pal.size() / 4)) * 4
	var o := i * 4
	_rgba[o] = pal[k]; _rgba[o + 1] = pal[k + 1]; _rgba[o + 2] = pal[k + 2]; _rgba[o + 3] = 255


func _set_cell(i: int, m: int, t: float) -> void:
	_mat[i] = m
	_temp[i] = t
	if _life_min[m] > 0.0:
		_life[i] = _rng.randf_range(_life_min[m], _life_max[m])
	else:
		_life[i] = -1.0
	_write_color(i, m)
	if absf(t - _ambient) > 0.3 or _has_fixed[m] != 0:
		@warning_ignore("integer_division")
		_row_hot[i / _w] = 1


func _swap(i: int, j: int) -> void:
	var m := _mat[i]; _mat[i] = _mat[j]; _mat[j] = m
	var t := _temp[i]; _temp[i] = _temp[j]; _temp[j] = t
	var l := _life[i]; _life[i] = _life[j]; _life[j] = l
	var oi := i * 4
	var oj := j * 4
	for k in 3:
		var c := _rgba[oi + k]; _rgba[oi + k] = _rgba[oj + k]; _rgba[oj + k] = c
	_stamp[i] = _step_no
	_stamp[j] = _step_no


func _wake(y: int) -> void:
	for yy in range(maxi(0, y - 1), mini(_h, y + 2)):
		_row_active[yy] = 1


func _wake_all() -> void:
	for y in _h:
		_row_active[y] = 1


func _can_enter(mover: int, target_i: int) -> bool:
	var tm := _mat[target_i]
	var ts := _state[tm]
	if ts == St.EMPTY:
		return true
	if ts == St.GAS or ts == St.FIRE:
		return _state[mover] != St.GAS and _state[mover] != St.FIRE
	if ts == St.LIQUID:
		return _density[mover] > _density[tm] and _stamp[target_i] != _step_no
	return false


func _do_step() -> void:
	_step_no += 1
	_move_pass()
	_heat_pass()
	_neutron_pass()
	_fission_timer += FIXED_DT
	if _fission_timer >= 1.0:
		_fissions_per_sec = float(_fissions_window) / _fission_timer
		_fissions_window = 0
		_fission_timer = 0.0


func _move_pass() -> void:
	var w := _w
	var down := -1 if _gravity_up else 1
	var y0 := _h - 1 if down > 0 else 0
	var y1 := -1 if down > 0 else _h
	for y in range(y0, y1, -down):
		if _row_active[y] == 0:
			continue
		var any := false
		var ltr := ((y + _step_no) & 1) == 0
		for k in w:
			var x := k if ltr else w - 1 - k
			var i := y * w + x
			if _stamp[i] == _step_no:
				continue
			var m := _mat[i]
			var st := _state[m]
			if st <= St.SOLID:
				continue
			if st == St.GAS or st == St.FIRE:
				if _life[i] > 0.0:
					_life[i] -= FIXED_DT
					any = true
					if _life[i] <= 0.0:
						_set_cell(i, _decay_into[m], _temp[i])
						continue
				if _move_gas(i, x, y, -down):
					any = true
			elif _move_fall(i, x, y, st, down):
				any = true
		if not any:
			_row_active[y] = 0


func _move_fall(i: int, x: int, y: int, st: int, down: int) -> bool:
	var ny := y + down
	var m := int(_mat[i])
	if ny >= 0 and ny < _h:
		var j := ny * _w + x
		if _can_enter(m, j):
			_swap(i, j); _wake(y); _wake(ny)
			return true
		var dir := 1 if _rng.randf() < 0.5 else -1
		for s in 2:
			var nx := x + (dir if s == 0 else -dir)
			if nx < 0 or nx >= _w:
				continue
			var jd := ny * _w + nx
			if _can_enter(m, jd) and (st == St.LIQUID or _can_enter(m, y * _w + nx)):
				_swap(i, jd); _wake(y); _wake(ny)
				return true
	if st == St.LIQUID:
		# Растекание: идём в случайную сторону до 4 клеток по пустоте, встаём в самую дальнюю.
		var dir2 := 1 if _rng.randf() < 0.5 else -1
		for s in 2:
			var d := dir2 if s == 0 else -dir2
			var best := -1
			for dist in range(1, 5):
				var nx := x + d * dist
				if nx < 0 or nx >= _w:
					break
				var jl := y * _w + nx
				if not _can_enter(m, jl):
					break
				best = jl
				# Есть куда падать — дальше не идём.
				if ny >= 0 and ny < _h and _can_enter(m, ny * _w + nx):
					break
			if best >= 0:
				_swap(i, best); _wake(y)
				return true
	return false


func _move_gas(i: int, x: int, y: int, up: int) -> bool:
	var ny := y + up
	if ny >= 0 and ny < _h:
		var j := ny * _w + x
		if _state[_mat[j]] == St.EMPTY:
			_swap(i, j); _wake(y); _wake(ny)
			return true
		var nx := x + (1 if _rng.randf() < 0.5 else -1)
		if nx >= 0 and nx < _w:
			var jd := ny * _w + nx
			if _state[_mat[jd]] == St.EMPTY:
				_swap(i, jd); _wake(y); _wake(ny)
				return true
	var sx := x + (1 if _rng.randf() < 0.5 else -1)
	if sx >= 0 and sx < _w and _rng.randf() < 0.5:
		var js := y * _w + sx
		if _state[_mat[js]] == St.EMPTY:
			_swap(i, js)
			return true
	return false


func _heat_pass() -> void:
	# За шаг обрабатывается 1/HEAT_BANDS строк, поэтому коэффициенты умножены на HEAT_BANDS.
	var w := _w
	var band_h := int(ceilf(float(_h) / float(HEAT_BANDS)))
	var ya := _heat_band * band_h
	var yb := mini(_h, ya + band_h)
	_heat_band = (_heat_band + 1) % HEAT_BANDS
	var mul := minf(_heat_mul, 3.0)
	for y in range(ya, yb):
		var hot := _row_hot[y] != 0 or (y > 0 and _row_hot[y - 1] != 0) or (y < _h - 1 and _row_hot[y + 1] != 0)
		if not hot:
			_row_max[y] = _ambient
			continue
		var row_hot := false
		var row_max := -273.0
		for x in w:
			var i := y * w + x
			var m := int(_mat[i])
			var t := _temp[i]
			if _has_fixed[m] != 0:
				t = _fixed_temp[m]
			else:
				var tl := _temp[i - 1] if x > 0 else _ambient
				var tr := _temp[i + 1] if x < w - 1 else _ambient
				var tu := _temp[i - w] if y > 0 else _ambient
				var td := _temp[i + w] if y < _h - 1 else _ambient
				var k := minf(0.24, _cond_k[m] * mul)
				t += k * ((tl + tr + tu + td) * 0.25 - t) * 0.9
				t = _phase(i, m, t)
			_temp[i] = t
			if absf(t - _ambient) > 0.3:
				row_hot = true
			row_max = maxf(row_max, t)
		_row_hot[y] = 1 if row_hot else 0
		_row_max[y] = row_max


func _phase(i: int, m: int, t: float) -> float:
	var into := -1
	if _melt_into[m] >= 0 and t >= _melt_t[m]:
		into = _melt_into[m]
	elif _freeze_into[m] >= 0 and t <= _freeze_t[m]:
		into = _freeze_into[m]
	elif _boil_into[m] >= 0 and t >= _boil_t[m]:
		into = _boil_into[m]
	elif _cond_into[m] >= 0 and t <= _cond_t[m]:
		into = _cond_into[m]
	if into >= 0:
		_set_cell(i, into, t)
		@warning_ignore("integer_division")
		_wake(i / _w)
	return t


func _neutron_pass() -> void:
	if _n_pos.is_empty():
		return
	var pos := PackedVector2Array()
	var vel := PackedVector2Array()
	var life := PackedFloat32Array()
	for k in _n_pos.size():
		var p := _n_pos[k] + _n_vel[k]
		var l := _n_life[k] - FIXED_DT
		var x := int(p.x)
		var y := int(p.y)
		if l <= 0.0 or p.x < 0.0 or p.y < 0.0 or x >= _w or y >= _h:
			continue
		var i := y * _w + x
		var m := int(_mat[i])
		if _fissile[m] > 0.0 and _rng.randf() < _fissile[m] * 0.12:
			_fissions_window += 1
			_temp[i] = minf(_temp[i] + 40.0 * _heat_mul, 6000.0)
			@warning_ignore("integer_division")
			_row_hot[i / _w] = 1
			for s in 2 + (_rng.randi() & 1):
				if pos.size() < MAX_NEUTRONS:
					var ang := _rng.randf() * TAU
					pos.append(p)
					vel.append(Vector2(cos(ang), sin(ang)) * 1.6)
					life.append(_rng.randf_range(1.0, 2.0))
			continue
		if _absorb[m] > 0.0 and _rng.randf() < _absorb[m]:
			continue
		pos.append(p)
		vel.append(_n_vel[k])
		life.append(l)
	_n_pos = pos
	_n_vel = vel
	_n_life = life


static func _thermal_color(t: float) -> Color:
	# Шкала −50…3000 °C, логарифмическая выше 100 °C.
	var u: float
	if t <= 100.0:
		u = clampf((t + 50.0) / 150.0, 0.0, 1.0) * 0.4
	else:
		u = 0.4 + 0.6 * clampf(log(t / 100.0) / log(30.0), 0.0, 1.0)
	var stops: Array[Color] = [
		Color(0.02, 0.0, 0.15), Color(0.1, 0.1, 0.6), Color(0.0, 0.6, 0.7),
		Color(0.2, 0.8, 0.2), Color(1.0, 0.85, 0.1), Color(1.0, 0.3, 0.0), Color(1.0, 1.0, 1.0),
	]
	var f := u * float(stops.size() - 1)
	var a := int(floorf(f))
	if a >= stops.size() - 1:
		return stops[stops.size() - 1]
	return stops[a].lerp(stops[a + 1], f - float(a))


# =========================================================================
# Встроенный набор материалов (если data/materials.json ещё нет)
# =========================================================================

static func builtin_data() -> Dictionary:
	return {
		"version": 1, "cell_size_m": 0.01, "ambient_temp": 20.0, "thermal_time_scale": 1.0,
		"categories": [
			{"id": "powder", "name": "Сыпучие"}, {"id": "liquid", "name": "Жидкости"},
			{"id": "gas", "name": "Газы"}, {"id": "solid", "name": "Твёрдые"},
			{"id": "nuclear", "name": "Ядерные"}, {"id": "energy", "name": "Огонь и взрывчатка"},
			{"id": "special", "name": "Особые"},
		],
		"materials": [
			{"id": "air", "name": "Воздух", "category": "special", "state": "empty", "density": 1.2,
				"conductivity": 0.026, "heat_capacity": 1005, "colors": ["#0b0d13"], "hidden": true},
			{"id": "sand", "name": "Песок", "category": "powder", "state": "powder", "density": 1600,
				"conductivity": 0.3, "heat_capacity": 830, "colors": ["#e3c27a", "#d9b56a", "#ecd08c", "#cfa95e"],
				"melt": {"temp": 1700, "into": "lava", "latent": 150000},
				"desc": "Сыплется горкой и тонет в воде."},
			{"id": "water", "name": "Вода", "category": "liquid", "state": "liquid", "density": 1000,
				"conductivity": 0.6, "heat_capacity": 4186, "colors": ["#2f6fd6", "#3478de", "#2a66c9"],
				"boil": {"temp": 100, "into": "steam", "latent": 2257000},
				"freeze": {"temp": 0, "into": "ice", "latent": 334000},
				"nuclear": {"moderate": 0.3, "absorb": 0.01},
				"desc": "Течёт, кипит при 100 °C, замерзает при 0 °C."},
			{"id": "steam", "name": "Пар", "category": "gas", "state": "gas", "density": 0.6,
				"conductivity": 0.02, "heat_capacity": 2010, "initial_temp": 110,
				"colors": ["#c8d2e0", "#b9c4d4"],
				"condense": {"temp": 95, "into": "water", "latent": 2257000},
				"desc": "Поднимается вверх и конденсируется в воду."},
			{"id": "ice", "name": "Лёд", "category": "solid", "state": "solid", "density": 917,
				"conductivity": 2.2, "heat_capacity": 2100, "initial_temp": -10,
				"colors": ["#a9d8f5", "#bfe3f8"], "melt": {"temp": 0, "into": "water", "latent": 334000},
				"desc": "Тает при 0 °C."},
			{"id": "stone", "name": "Камень", "category": "solid", "state": "solid", "density": 2600,
				"conductivity": 2.5, "heat_capacity": 790, "colors": ["#6d6f78", "#7a7c85", "#62646c"],
				"melt": {"temp": 1200, "into": "lava", "latent": 400000},
				"desc": "Неподвижный. Плавится в лаву."},
			{"id": "lava", "name": "Лава", "category": "liquid", "state": "liquid", "density": 2800,
				"conductivity": 1.5, "heat_capacity": 1000, "initial_temp": 1200, "glow": true,
				"viscosity": 0.85, "colors": ["#ff5a1a", "#ff7a22", "#e8400f"],
				"freeze": {"temp": 900, "into": "stone", "latent": 400000},
				"desc": "Раскалённая жидкость, остывает в камень."},
			{"id": "steel", "name": "Сталь", "category": "solid", "state": "solid", "density": 7850,
				"conductivity": 50, "heat_capacity": 490, "colors": ["#9aa3ad", "#a7b0ba"],
				"desc": "Быстро проводит тепло."},
			{"id": "heater", "name": "Нагреватель", "category": "special", "state": "solid", "density": 7000,
				"conductivity": 50, "heat_capacity": 500, "fixed_temp": 400, "colors": ["#b03a2e"],
				"desc": "Всегда держит 400 °C."},
			{"id": "uranium235", "name": "Уран-235", "category": "nuclear", "state": "solid",
				"density": 19100, "conductivity": 27, "heat_capacity": 116,
				"colors": ["#4fdc4a", "#45c940"],
				"nuclear": {"fissile": 0.35, "fast_fission": 0.03, "absorb": 0.02},
				"desc": "Делится от нейтронов и греется."},
			{"id": "fire", "name": "Огонь", "category": "energy", "state": "fire", "density": 0.3,
				"conductivity": 0.05, "heat_capacity": 1000, "initial_temp": 800,
				"lifetime": [0.4, 1.0], "colors": ["#ffb02e", "#ff7a1a", "#ffd34d"], "hidden": true},
		],
	}
