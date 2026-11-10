extends Node
## Плейтест «как играет человек»: инстанцирует настоящую scenes/main.tscn и управляет ею
## синтетическим вводом (push_input: мышь, колесо, клавиши, тач). Код игры не меняет.
##
##   godot --path <проект> --fixed-fps 60 --disable-vsync res://tests/playtest/playtest.tscn -- scen=1,2 out=/abs/dir
##
## --fixed-fps 60 даёт ровно 1/60 с игрового времени на кадр, поэтому «5 с» = 300 кадров.

var OUT := "/private/tmp/claude-501/-Users-tsurikov--project-marik-Physics/a498c0fd-4b35-447a-80ea-a00db9f31d53/scratchpad/playtest"

var main: Node
var hud: Hud
var sim: SimWorld
var core: Object
var view: WorldView
var inp: BrushInput
var state: AppState
var _mpos := Vector2.ZERO
var _mask := 0
var _log := PackedStringArray()
var _args := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var p := a.find("=")
		if p > 0 and not a.begins_with("--"):
			_args[a.substr(0, p)] = a.substr(p + 1)
	OUT = str(_args.get("out", OUT))
	DirAccess.make_dir_recursive_absolute(OUT)
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	while main.get("input") == null:
		await get_tree().process_frame
	await frames(10)
	hud = main.hud
	sim = main.sim
	core = sim._w
	view = main.world_view
	inp = main.input
	state = main.state
	lg("мир %d×%d, ядро native=%s, cell_scale=%.2f px, окно %s, OS mobile=%s" % [
		sim.get_width(), sim.get_height(), str(sim.is_native), view.cell_scale(),
		str(get_viewport().get_visible_rect().size), str(OS.has_feature("mobile"))])
	var scen := str(_args.get("scen", "1,2,3,4,5,6,7")).split(",")
	for s in scen:
		var m := "scen_" + s.strip_edges()
		if has_method(m):
			lg("\n===== %s =====" % m)
			await call(m)
	var f := FileAccess.open(OUT + "/log_%s.txt" % str(_args.get("tag", "run")), FileAccess.WRITE)
	f.store_string("\n".join(_log))
	f.close()
	get_tree().quit()


# =========================================================================
# Утилиты
# =========================================================================

func lg(s: String) -> void:
	print(s)
	_log.append(s)


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func secs(s: float) -> void:
	await frames(roundi(s * 60.0))


func shot(name: String) -> String:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var p := OUT + "/" + name + ".png"
	img.save_png(p)
	lg("  скриншот: " + p)
	return p


func mid(id: String) -> int:
	return sim.find_material(id)


func cell_px(c: Vector2) -> Vector2:
	return view.cell_to_screen(c + Vector2(0.5, 0.5))


func T(c: Vector2i) -> float:
	return float(sim.get_cell(c)["temp"])


func mean(id: String) -> float:
	return float(core.get_mean_temp(mid(id)))


func count(id: String) -> int:
	return int(core.count_material(mid(id)))


func thermo() -> String:
	return hud._thermo_label.text if hud._thermo.visible else "(термометр скрыт)"


func push(ev: InputEvent) -> void:
	get_viewport().push_input(ev, true)


func mouse_move(p: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	e.relative = p - _mpos
	e.button_mask = _mask
	_mpos = p
	push(e)


func mouse_btn(p: Vector2, idx: int, pressed: bool, ctrl := false) -> void:
	var e := InputEventMouseButton.new()
	e.position = p
	e.global_position = p
	e.button_index = idx
	e.pressed = pressed
	e.ctrl_pressed = ctrl
	if idx <= 3:
		var bit := 1 << (idx - 1)
		_mask = (_mask | bit) if pressed else (_mask & ~bit)
	e.button_mask = _mask
	_mpos = p
	push(e)


func click(p: Vector2) -> void:
	mouse_move(p)
	await frames(1)
	mouse_btn(p, MOUSE_BUTTON_LEFT, true)
	await frames(1)
	mouse_btn(p, MOUSE_BUTTON_LEFT, false)
	await frames(2)


func click_control(c: Control) -> void:
	await click(c.get_global_rect().get_center())


func key(k: Key, ctrl := false) -> void:
	for pr in [true, false]:
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.pressed = pr
		e.ctrl_pressed = ctrl
		e.command_or_control_autoremap = ctrl
		push(e)
		await frames(1)


func wheel(up: bool, n: int, at: Vector2) -> void:
	for i in n:
		mouse_btn(at, MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN, true)
		mouse_btn(at, MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN, false)
	await frames(1)


## Радиус кисти колесом над миром (как игрок).
func set_radius(r: int) -> void:
	var at := cell_px(Vector2(sim.get_width() * 0.5, sim.get_height() * 0.5))
	var d := r - state.brush_radius
	if d != 0:
		await wheel(d > 0, absi(d), at)


## Выбор материала кликом по шторке: открыть, вкладка категории, прокрутить ряд, кликнуть.
func pick(key_id: String) -> bool:
	var d := hud.drawer
	if not d.is_open:
		await click_control(d._chip)
	var e := d.entry_for(mid(key_id))
	if e.is_empty():
		lg("  !! материала %s нет в палитре" % key_id)
		return false
	var cat := str(e["category"])
	await click_control(d._tab_buttons[cat])
	await frames(2)
	if d._current_tab != cat:
		lg("  !! клик по вкладке %s не сработал (текущая %s, кадр %d) — повтор" % [cat, d._current_tab, Engine.get_process_frames()])
		await click_control(d._tab_buttons[cat])
		await frames(2)
	var btn: MaterialButton = null
	for b in d._buttons:
		if int(b.entry["index"]) == int(e["index"]):
			btn = b
	if btn == null:
		var tb: Button = d._tab_buttons[cat]
		lg("  !! кнопки %s нет во вкладке %s (текущая %s, вкладка rect %s, видимая область вкладок %s, open=%s)" % [key_id, cat, d._current_tab, str(tb.get_global_rect()), str(tb.get_parent().get_parent().get_global_rect()), str(d.is_open)])
		return false
	var vis := d._row_scroll.get_global_rect()
	var r := btn.get_global_rect()
	if not vis.encloses(r):
		# Игрок прокрутил бы ряд — прокручиваем так же, как ScrollContainer колесом/свайпом.
		d._row_scroll.scroll_horizontal = int(btn.position.x - 20)
		await frames(2)
	await click_control(btn)
	if state.material != int(e["index"]):
		lg("  !! клик по %s не выбрал материал (state.material=%d)" % [key_id, state.material])
		return false
	return true


const TOOL_IDX := {"brush": 0, "eraser": 1, "heat": 2, "cool": 3, "neutron": 4, "wind": 5}

func tool(name: String) -> void:
	await click_control(hud.tool_bar._buttons[TOOL_IDX[name]])
	if int(state.tool) != TOOL_IDX[name]:
		lg("  !! инструмент %s не выбран" % name)


func toggle_heat3(on: bool) -> void:
	if state.fast_heat != on:
		await click_control(hud.top_bar._heat)
	if state.fast_heat != on:
		lg("  !! кнопка ×3 не переключилась")


func set_view(i: int) -> void:
	await click_control(hud.top_bar._views[i])


## Нарисовать прямоугольник клеток мышью: радиус 0, построчные штрихи слева направо.
func paint_rect(key_id: String, x0: int, y0: int, x1: int, y1: int) -> void:
	if not await pick(key_id):
		return
	if state.tool != AppState.Tool.BRUSH:
		await tool("brush")
	await set_radius(0)
	for y in range(y1, y0 - 1, -1):  # снизу вверх: жидкость не мешает следующему ряду
		var a := cell_px(Vector2(x0, y))
		var b := cell_px(Vector2(x1, y))
		mouse_move(a)
		mouse_btn(a, MOUSE_BUTTON_LEFT, true)
		await frames(1)
		mouse_move(b)
		await frames(1)
		mouse_btn(b, MOUSE_BUTTON_LEFT, false)
	await frames(1)


## Держать ЛКМ с текущим инструментом в клетке c n секунд, без движения.
func hold(c: Vector2i, s: float, sample_cb: Callable = Callable()) -> void:
	var p := cell_px(Vector2(c))
	mouse_move(p)
	await frames(1)
	mouse_btn(p, MOUSE_BUTTON_LEFT, true)
	var n := roundi(s * 60.0)
	for i in n:
		await frames(1)
		if sample_cb.is_valid() and (i + 1) % 60 == 0:
			sample_cb.call((i + 1) / 60)
	mouse_btn(p, MOUSE_BUTTON_LEFT, false)
	await frames(1)


## Чистый мир (через ядро, это подготовка, не замер) и стандартное состояние.
func reset_world() -> void:
	if hud.modal.visible:
		hud.modal.close()
	sim.clear()
	state.paused = false
	state.fast_heat = false
	state.view = 0
	state.tool = AppState.Tool.BRUSH
	state.replace_mode = false
	state.notify()
	await frames(3)


func rect_core(x0: int, y0: int, x1: int, y1: int, id: String) -> void:
	var m := 0 if id == "air" else mid(id)
	for y in range(y0, y1 + 1):
		sim.paint_line(Vector2i(x0, y), Vector2i(x1, y), 0, m, 1)


func block_mean(x0: int, y0: int, x1: int, y1: int, id: String) -> float:
	var m := mid(id)
	var s := 0.0
	var n := 0
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var c := sim.get_cell(Vector2i(x, y))
			if int(c["mat"]) == m:
				s += float(c["temp"])
				n += 1
	return s / maxf(1.0, float(n))


func stats() -> Dictionary:
	return sim.get_stats()


func scen_0() -> void:
	# Первый клик после старта: вкладка «Металлы».
	var d := hud.drawer
	var tb: Button = d._tab_buttons["metal"]
	await click_control(tb)
	await frames(2)
	lg("первый клик по вкладке metal: текущая %s (кадр %d)" % [d._current_tab, Engine.get_process_frames()])
	await click_control(d._tab_buttons["liquid"])
	await frames(2)
	lg("второй клик по вкладке liquid: текущая %s" % d._current_tab)


# =========================================================================
# 1. Инструмент «Нагрев» на блоках
# =========================================================================

func scen_1() -> void:
	var w := sim.get_width()
	var h := sim.get_height()
	var x0 := roundi(w * 0.45)
	var y0 := h - 20
	for id: String in ["steel", "stone", "copper", "glass", "uranium235", "water", "ice"]:
		await reset_world()
		var bx0 := x0
		var by0 := y0
		var bx1 := x0 + 19
		var by1 := y0 + 19
		if id == "water":
			# Стенки чаши — стеной (подготовка), воду наливает игрок кистью.
			rect_core(x0 - 2, y0 - 2, x0 - 1, h - 1, "wall")
			rect_core(x0 + 20, y0 - 2, x0 + 21, h - 1, "wall")
			bx0 = x0
			by0 = h - 20
			bx1 = x0 + 19
			by1 = h - 1
		await paint_rect(id, bx0, by0, bx1, by1)
		await frames(30)
		var c := Vector2i(bx0 + 10, by0 + 10)
		var n0 := count(id)
		var t0 := T(c)
		var m0 := block_mean(bx0, by0, bx1, by1, id)
		await set_radius(4)
		await tool("heat")
		var samples: Array = []
		await hold(c, 5.0, func(sec: int) -> void:
			samples.append("%dс:%.0f" % [sec, T(c)]))
		var t1 := T(c)
		var m1 := block_mean(bx0, by0, bx1, by1, id)
		lg("%-11s UI-нагрев r=%d 5 с: центр %.1f→%.1f °C [%s], средн. блока %.1f→%.1f, клеток %d→%d, термометр «%s»" % [
			id, state.brush_radius, t0, t1, ", ".join(PackedStringArray(samples)), m0, m1, n0, count(id), thermo()])
		if id in ["steel", "water"]:
			await set_view(1)
			await frames(2)
			await shot("s1_heat_%s" % id)
			await set_view(0)
		# Прямой вызов heat_circle тем же стендом.
		await reset_world()
		if id == "water":
			rect_core(x0 - 2, y0 - 2, x0 - 1, h - 1, "wall")
			rect_core(x0 + 20, y0 - 2, x0 + 21, h - 1, "wall")
		rect_core(bx0, by0, bx1, by1, id)
		await frames(30)
		var d0 := T(c)
		for i in 300:
			sim.heat_circle(c, 4, BrushInput.HEAT_WATTS, 1.0 / 60.0)
			await frames(1)
		lg("%-11s прямой heat_circle r=4 5 с: центр %.1f→%.1f, средн. %.1f" % [id, d0, T(c), block_mean(bx0, by0, bx1, by1, id)])


# =========================================================================
# 2. Сталь/камень на нагревателе, на лаве, в огне; ×1 и ×3
# =========================================================================

func scen_2() -> void:
	var w := sim.get_width()
	var h := sim.get_height()
	for fast in [false, true]:
		for src: String in ["heater", "lava", "fire"]:
			for id: String in ["steel", "stone"]:
				await reset_world()
				var x0 := roundi(w * 0.4)
				# Источник (подготовка ядром), блок 10×10 рисует игрок.
				if src == "heater":
					rect_core(x0 - 5, h - 4, x0 + 14, h - 1, "heater")
				elif src == "lava":
					rect_core(x0 - 8, h - 30, x0 - 7, h - 1, "wall")
					rect_core(x0 + 16, h - 30, x0 + 17, h - 1, "wall")
					rect_core(x0 - 6, h - 6, x0 + 15, h - 1, "lava")
				else:
					rect_core(x0 - 5, h - 2, x0 + 14, h - 1, "wall")
				var by1 := h - 5 if src == "heater" else (h - 7 if src == "lava" else h - 3)
				await paint_rect(id, x0, by1 - 9, x0 + 9, by1)
				await toggle_heat3(fast)
				var line := PackedStringArray()
				var c := Vector2i(x0 + 5, by1 - 5)
				var top := Vector2i(x0 + 5, by1 - 9)
				if src == "fire":
					# Игрок держит кисть с огнём у блока: огонь рисуется только в пустоту.
					await pick("fire")
					await set_radius(4)
					var p := cell_px(Vector2(x0 + 5, by1 - 12))
					mouse_move(p)
					mouse_btn(p, MOUSE_BUTTON_LEFT, true)
				for k in 3:
					await secs(10.0)
					line.append("%dс: средн %.0f центр %.0f верх %.0f" % [(k + 1) * 10, block_mean(x0, by1 - 9, x0 + 9, by1, id), T(c), T(top)])
				if src == "fire":
					mouse_btn(_mpos, MOUSE_BUTTON_LEFT, false)
					await frames(1)
				lg("%-6s на %-6s ×%d: %s; клеток %s=%d" % [id, src, 3 if fast else 1, " | ".join(line), id, count(id)])
				if id == "steel" and not fast:
					await set_view(1)
					await shot("s2_%s_on_%s" % [id, src])
	await toggle_heat3(false)


# =========================================================================
# 3. Вода и пар
# =========================================================================

func scen_3() -> void:
	var w := sim.get_width()
	var h := sim.get_height()
	for fast in [false, true]:
		var dur := 20.0 if fast else 60.0
		for src: String in ["heater", "super_heater", "lava", "pot"]:
			await reset_world()
			var x0 := roundi(w * 0.4)
			var wx0 := x0
			var wx1 := x0 + 19
			if src == "pot":
				rect_core(x0 - 3, h - 4, x0 + 22, h - 1, "heater")
				rect_core(x0 - 3, h - 6, x0 + 22, h - 5, "steel")
				rect_core(x0 - 3, h - 30, x0 - 1, h - 7, "steel")
				rect_core(x0 + 20, h - 30, x0 + 22, h - 7, "steel")
			else:
				rect_core(x0 - 3, h - 4, x0 + 22, h - 1, src if src != "lava" else "wall")
				if src == "lava":
					rect_core(x0, h - 7, x0 + 19, h - 5, "lava")
				rect_core(x0 - 3, h - 30, x0 - 1, h - 5, "wall")
				rect_core(x0 + 20, h - 30, x0 + 22, h - 5, "wall")
			var wy1 := h - 7 if src == "pot" else (h - 8 if src == "lava" else h - 5)
			await paint_rect("water", wx0, wy1 - 9, wx1, wy1)
			await toggle_heat3(fast)
			var water0 := count("water")
			var first_steam := -1.0
			var max_steam := 0
			var made := 0
			var prev_steam := 0
			var samples := PackedStringArray()
			var n := roundi(dur * 60.0)
			var steam_id := mid("steam")
			for i in n:
				await frames(1)
				var s := count("steam")
				if s > 0 and first_steam < 0.0:
					first_steam = float(i + 1) / 60.0
				max_steam = maxi(max_steam, s)
				if (i + 1) % roundi(dur * 6.0) == 0:
					# Высота пара: средний y клеток пара (меньше — выше).
					var ys := 0.0
					var ny := 0
					var top := h
					for y in range(0, h):
						for x in range(x0 - 25, x0 + 45):
							if int(sim.get_cell(Vector2i(x, y))["mat"]) == steam_id:
								ys += y
								ny += 1
								top = mini(top, y)
					samples.append("%.0fс: вода %d пар %d (ср.y %.0f, верх %d) Tводы %.0f" % [
						float(i + 1) / 60.0, count("water"), s, ys / maxf(1, ny), top, mean("water")])
			lg("вода на %-12s ×%d за %.0f с: первый пар %.1f с, макс. пара %d, вода %d→%d (убыль %d)" % [
				src, 3 if fast else 1, dur, first_steam, max_steam, water0, count("water"), water0 - count("water")])
			for s in samples:
				lg("    " + s)
			if src in ["heater", "pot"]:
				await shot("s3_water_%s_x%d" % [src, 3 if fast else 1])
	await toggle_heat3(false)


# =========================================================================
# 4. Уран
# =========================================================================

func scen_4() -> void:
	var w := sim.get_width()
	var h := sim.get_height()
	for cfg: String in ["air", "water", "graphite", "neutron_tool", "water+tool"]:
		await reset_world()
		var x0 := roundi(w * 0.45)
		var y0 := h - 25
		rect_core(x0 - 15, h - 3, x0 + 34, h - 1, "wall")
		if cfg.begins_with("water"):
			rect_core(x0 - 15, h - 50, x0 - 14, h - 4, "wall")
			rect_core(x0 + 33, h - 50, x0 + 34, h - 4, "wall")
		if cfg == "graphite":
			rect_core(x0 - 6, y0 - 6, x0 + 25, h - 4, "graphite")
			rect_core(x0, y0 - 2, x0 + 19, y0 + 17, "air")
		await paint_rect("uranium235", x0, y0 - 2, x0 + 19, y0 + 17)
		if cfg.begins_with("water"):
			await paint_rect("water", x0 - 13, y0 - 22, x0 + 32, h - 4)
		var u0 := mean("uranium235")
		var line := PackedStringArray()
		var fps_max := 0.0
		if cfg.contains("tool"):
			await tool("neutron")
			await set_radius(6)
			var p := cell_px(Vector2(x0 + 10, y0 + 8))
			mouse_move(p)
			mouse_btn(p, MOUSE_BUTTON_LEFT, true)
		for k in 30:
			await secs(1.0)
			var st := stats()
			fps_max = maxf(fps_max, float(st["fissions_per_sec"]))
			if cfg.contains("tool") and k == 4:
				mouse_btn(_mpos, MOUSE_BUTTON_LEFT, false)  # 5 с источника нейтронов
			if (k + 1) % 5 == 0:
				line.append("%dс: U %.2f°C дел/с %d n %d" % [k + 1, mean("uranium235"), roundi(float(st["fissions_per_sec"])), int(st["neutrons"])])
		lg("U-235 20×20 [%s]: старт %.2f °C; %s; макс дел/с %.0f, max_temp %.0f" % [cfg, u0, " | ".join(line), fps_max, float(stats()["max_temp"])])
		await set_view(2 if cfg != "air" else 1)
		await shot("s4_uranium_%s" % cfg.replace("+", "_"))
	# Минимальная конфигурация «греется сам»: демо-реактор — U в воде внутри графита.
	await reset_world()


# =========================================================================
# 5. Пауза/шаг/×3/вид/шторка/undo/загрузка
# =========================================================================

func _hot_setup() -> Dictionary:
	await reset_world()
	var w := sim.get_width()
	var h := sim.get_height()
	var x0 := roundi(w * 0.4)
	rect_core(x0 - 5, h - 4, x0 + 14, h - 1, "heater")
	rect_core(x0, h - 14, x0 + 9, h - 5, "steel")
	return {"x0": x0, "y1": h - 5}


func scen_5() -> void:
	var g := await _hot_setup()
	var x0: int = g["x0"]
	var y1: int = g["y1"]
	var c := Vector2i(x0 + 5, y1 - 7)
	await secs(5.0)
	var ref := T(c)
	lg("сталь на нагревателе, 5 с: верх %.1f" % ref)
	# Пауза кнопкой
	await click_control(hud.top_bar._pause)
	var tp := T(c)
	await secs(3.0)
	lg("пауза 3 с: %.2f→%.2f (ожидаем без изменений), paused=%s" % [tp, T(c), str(state.paused)])
	# Шаг кадра
	await click_control(hud.top_bar.get_child(0).get_child(1))
	lg("шаг: %.4f→%.4f" % [tp, T(c)])
	# Нагрев на паузе инструментом
	await tool("heat")
	var air_c := Vector2i(x0 + 5, y1 - 12)
	var tpa := T(c)
	await hold(c, 2.0)
	lg("инструмент нагрев 2 с на паузе: сталь %.1f→%.1f (тепло вливается без шага?)" % [tpa, T(c)])
	await click_control(hud.top_bar._pause)
	await tool("brush")
	# ×3 + смена вида + шторка
	await _hot_setup()
	await toggle_heat3(true)
	await set_view(1)
	await click_control(hud.drawer._chip)  # закрыть шторку
	await frames(30)
	await click_control(hud.drawer._chip)  # открыть
	await set_view(3)
	await set_view(0)
	await secs(5.0)
	var t3 := T(c)
	lg("×3 + виды + шторка, 5 с: верх %.1f (×1 было %.1f); state.fast_heat=%s" % [t3, ref, str(state.fast_heat)])
	# Клавиша H, клавиши видов
	await key(KEY_2)
	await key(KEY_1)
	lg("после клавиш 2/1: fast_heat=%s view=%d" % [str(state.fast_heat), state.view])
	# Undo: нарисовать сталь игроком, подождать, отменить
	await _hot_setup()
	await toggle_heat3(false)
	await secs(5.0)
	var before_undo := T(c)
	await paint_rect("sand", x0 + 30, 20, x0 + 32, 22)
	await click_control(hud.top_bar.get_child(0).get_child(hud.top_bar.get_child(0).get_child_count() - 4))
	var after_undo := T(c)
	await secs(5.0)
	lg("undo: сталь %.1f до, %.1f сразу после, %.1f через 5 с (ожидаем рост, песок=%d)" % [before_undo, after_undo, T(c), count("sand")])
	# Двухпальцевый тап — undo (тач). Проверяем, что отменяет и мир живой.
	# Сохранение/загрузка слота 5 через окно
	await _hot_setup()
	await secs(3.0)
	main._save_slot(5)
	var t_saved := T(c)
	await secs(5.0)
	await click_control(hud.top_bar.get_child(0).get_child(hud.top_bar.get_child(0).get_child_count() - 2))
	await frames(5)
	var loaded := false
	if hud.modal.visible:
		var btns := _find_buttons(hud.modal, "Загрузить")
		if btns.size() >= 5 and not btns[4].disabled:
			await click_control(btns[4])
			loaded = true
	await frames(2)
	var t_l := T(c)
	await secs(5.0)
	lg("загрузка слота 5 через окно (%s): сохранено %.1f, сразу %.1f, через 5 с %.1f" % [str(loaded), t_saved, t_l, T(c)])
	SaveSlots_delete(5)


func _find_buttons(n: Node, text: String) -> Array[Button]:
	var out: Array[Button] = []
	for ch in n.find_children("*", "Button", true, false):
		if (ch as Button).text == text:
			out.append(ch)
	return out


func SaveSlots_delete(slot: int) -> void:
	for ext in [".sand", ".png"]:
		var p := "user://saves/slot_%d%s" % [slot, ext]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


# =========================================================================
# 6. Сон чанков
# =========================================================================

func scen_6() -> void:
	var h := sim.get_height()
	# (а) сталь через границу чанка x=64, ждём сна, лава рядом в соседнем чанке
	await reset_world()
	rect_core(40, h - 2, 140, h - 1, "wall")
	await paint_rect("steel", 54, h - 22, 73, h - 3)
	await secs(20.0)
	var st := stats()
	lg("сталь 54..73 (через x=64) 20 с: heat_chunks=%d active_chunks=%d" % [int(st["pass_ms"]["heat_chunks"]), int(st["active_chunks"])])
	var far := Vector2i(55, h - 12)
	var near := Vector2i(72, h - 12)
	var tf0 := T(far)
	# лава справа, в чанке x>=64 (сосед правого чанка стали — тот же чанк 1)
	rect_core(74, h - 30, 75, h - 3, "air")
	await paint_rect("heater", 74, h - 22, 76, h - 3)
	var ln := PackedStringArray()
	for k in 4:
		await secs(5.0)
		ln.append("%dс: ближний %.0f дальний(x=55) %.0f" % [(k + 1) * 5, T(near), T(far)])
	lg("нагреватель вплотную справа: " + " | ".join(ln))
	# (б) сталь целиком в чанке 0, источник тепла в чанке 2 через длинный стальной мост
	await reset_world()
	rect_core(0, h - 2, 200, h - 1, "wall")
	await paint_rect("steel", 10, h - 6, 140, h - 3)
	await secs(20.0)
	rect_core(141, h - 6, 143, h - 3, "heater")
	ln.clear()
	for k in 6:
		await secs(10.0)
		ln.append("%dс: x=130 %.0f x=100 %.0f x=70 %.0f x=40 %.0f" % [(k + 1) * 10, T(Vector2i(130, h - 4)), T(Vector2i(100, h - 4)), T(Vector2i(70, h - 4)), T(Vector2i(40, h - 4))])
	lg("стальной мост 10..140 после сна, нагреватель на x=141: " + " | ".join(ln))
	# (в) уснувшая сталь + инструмент «Нагрев» в соседнем чанке
	await reset_world()
	rect_core(40, h - 2, 140, h - 1, "wall")
	await paint_rect("steel", 54, h - 22, 73, h - 3)
	await secs(20.0)
	await tool("heat")
	await set_radius(3)
	await hold(Vector2i(70, h - 12), 3.0)
	var a := T(Vector2i(70, h - 12))
	await secs(3.0)
	lg("нагрев 3 с в x=70 после сна: сразу %.0f, через 3 с x=70 %.0f x=60 %.0f x=55 %.0f" % [a, T(Vector2i(70, h - 12)), T(Vector2i(60, h - 12)), T(Vector2i(55, h - 12))])
	await tool("brush")
	await shot("s6_chunks")


# =========================================================================
# 7. Прочее: термометр при зуме, тач со смещением, ластик, загрузка чужого размера
# =========================================================================

func scen_7() -> void:
	var w := sim.get_width()
	var h := sim.get_height()
	await reset_world()
	rect_core(100, h - 30, 119, h - 11, "steel")
	rect_core(110, h - 20, 119, h - 11, "copper")
	# зум Ctrl+колесо в точке, потом термометр
	var p := cell_px(Vector2(110, h - 20))
	await wheel(true, 0, p)
	for i in 8:
		mouse_btn(p, MOUSE_BUTTON_WHEEL_UP, true, true)
		mouse_btn(p, MOUSE_BUTTON_WHEEL_UP, false, true)
	await frames(2)
	lg("зум %.2f, cell_scale %.2f, радиус после Ctrl+колесо %d" % [view.zoom, view.cell_scale(), state.brush_radius])
	for c: Vector2i in [Vector2i(105, h - 25), Vector2i(115, h - 15), Vector2i(109, h - 21)]:
		mouse_move(cell_px(Vector2(c)))
		await frames(2)
		lg("  курсор над %s (%s): термометр «%s», pointer_cell %s" % [str(c), str(sim.get_cell(c)["name"]), thermo(), str(inp.pointer_cell())])
	view.fit()
	await frames(2)
	# Тач со смещением кисти: палец на блоке → куда идёт нагрев?
	await reset_world()
	rect_core(100, h - 30, 119, h - 11, "steel")
	await tool("heat")
	await set_radius(4)
	var fc := Vector2i(110, h - 20)
	var fp := cell_px(Vector2(fc))
	var t := InputEventScreenTouch.new()
	t.index = 0
	t.position = fp
	t.pressed = true
	push(t)
	var thermo_during := ""
	for i in 180:
		await frames(1)
		if i == 170:
			thermo_during = thermo()
	t = InputEventScreenTouch.new()
	t.index = 0
	t.position = fp
	t.pressed = false
	push(t)
	await frames(2)
	var off_cells := BrushInput.FINGER_OFFSET / view.cell_scale()
	lg("тач-нагрев 3 с, палец на центре блока (brush_offset=%s): сталь под пальцем %.0f, средн. стали %.0f, air над блоком max: %.0f; смещение %.1f клеток; термометр во время «%s», после «%s»" % [
		str(state.brush_offset), T(fc), mean("steel"), T(Vector2i(110, roundi(h - 20 - off_cells))), off_cells, thermo_during, thermo()])
	await tool("brush")
	# Загрузка сохранения с другим размером мира (другое окно/устройство)
	await reset_world()
	var other: Object = ClassDB.instantiate("SandWorld")
	other.load_materials(main.loader.materials)
	other.load_reactions(main.loader.reactions)
	other.setup(w + 40, 180)
	other.paint_circle(Vector2i(50, 100), 10, mid("sand"), 1)
	var data: PackedByteArray = other.save_bytes()
	main.undo.push(sim.save_bytes())
	var ok := sim.load_bytes(data)
	await frames(3)
	var img_w := view._img.get_width()
	lg("загрузка сейва мира %d×180 в окно с миром %d: ok=%s, ядро теперь %d×%d, текстура вида %d — %s" % [
		w + 40, w, str(ok), sim.get_width(), sim.get_height(), img_w,
		"КАРТИНКА ЗАМЕРЗАЕТ (refresh пропускает кадр)" if img_w != sim.get_width() else "ок"])
	await shot("s7_load_other_size")
	main._undo()
	await frames(2)
	# Ластик ПКМ
	await reset_world()
	rect_core(100, h - 30, 119, h - 11, "steel")
	var ep := cell_px(Vector2(110, h - 20))
	mouse_move(ep)
	mouse_btn(ep, MOUSE_BUTTON_RIGHT, true)
	await frames(5)
	mouse_btn(ep, MOUSE_BUTTON_RIGHT, false)
	await frames(2)
	lg("ПКМ-ластик r=%d: стали %d из 400" % [state.brush_radius, count("steel")])


# =========================================================================
# 8. Уран: минимальная конфигурация, которая греется сама
# =========================================================================

func scen_8() -> void:
	var w := sim.get_width()
	var h := sim.get_height()
	for cfg: String in ["bare30", "bare40", "bare60", "stripes_water", "demo_reactor", "stripes_water_x3"]:
		await reset_world()
		var x0 := roundi(w * 0.35)
		rect_core(0, h - 2, w - 1, h - 1, "wall")
		if cfg.begins_with("bare"):
			var n := int(cfg.substr(4))
			rect_core(x0, h - 2 - n, x0 + n - 1, h - 3, "uranium235")
		elif cfg.begins_with("stripes"):
			# Ванна воды 50×50, в ней 8 полос U 24×2 через 3 клетки воды.
			rect_core(x0 - 2, h - 56, x0 - 1, h - 3, "wall")
			rect_core(x0 + 50, h - 56, x0 + 51, h - 3, "wall")
			rect_core(x0, h - 54, x0 + 49, h - 3, "water")
			for k in 8:
				var y := h - 50 + k * 5
				rect_core(x0 + 13, y, x0 + 36, y + 1, "uranium235")
			if cfg.ends_with("x3"):
				await toggle_heat3(true)
		else:
			var rx := x0 + 26
			rect_core(rx - 26, h - 62, rx + 26, h - 4, "graphite")
			rect_core(rx - 22, h - 58, rx + 22, h - 8, "water")
			rect_core(rx - 22, h - 62, rx + 22, h - 59, "air")
			var yb := h - 38
			for layer in 3:
				rect_core(rx - 5, yb + layer * 3, rx + 4, yb + layer * 3 + 1, "uranium235")
		var u0 := mean("uranium235")
		var w0 := mean("water")
		var line := PackedStringArray()
		var fmax := 0.0
		for k in 30:
			await secs(1.0)
			var st := stats()
			fmax = maxf(fmax, float(st["fissions_per_sec"]))
			if (k + 1) % 5 == 0:
				line.append("%dс: U %.1f вода %.1f дел/с %d n %d пар %d" % [k + 1, mean("uranium235"), mean("water"), roundi(float(st["fissions_per_sec"])), int(st["neutrons"]), count("steam")])
		lg("%s (U клеток %d): U %.1f, вода %.1f → %s; макс дел/с %.0f" % [cfg, count("uranium235"), u0, w0, " | ".join(line), fmax])
		if cfg in ["bare40", "stripes_water", "demo_reactor"]:
			await set_view(2)
			await shot("s8_%s" % cfg)


func scen_9() -> void:
	var h := sim.get_height()
	for wait in [0.0, 20.0]:
		await reset_world()
		rect_core(0, h - 2, 200, h - 1, "wall")
		rect_core(10, h - 6, 140, h - 3, "steel")
		await secs(wait)
		rect_core(141, h - 6, 143, h - 3, "heater")
		await secs(60.0)
		lg("мост, ожидание %.0f с перед нагревателем, через 60 с: x=130 %.2f x=110 %.2f x=100 %.2f x=64 %.3f x=63 %.3f" % [wait, T(Vector2i(130, h - 4)), T(Vector2i(110, h - 4)), T(Vector2i(100, h - 4)), T(Vector2i(64, h - 4)), T(Vector2i(63, h - 4))])


func scen_10() -> void:
	var w := sim.get_width()
	var h := sim.get_height()
	for fuel: String in ["fire", "wood"]:
		await reset_world()
		var x0 := roundi(w * 0.4)
		rect_core(x0 - 10, h - 2, x0 + 20, h - 1, "wall")
		rect_core(x0 - 2, h - 14, x0 - 1, h - 3, "wall")
		rect_core(x0 + 10, h - 14, x0 + 11, h - 3, "wall")
		rect_core(x0 - 2, h - 24, x0 + 11, h - 15, "steel")  # сталь на опорах, под ней 12 клеток пустоты
		if fuel == "wood":
			rect_core(x0, h - 6, x0 + 9, h - 3, "wood")
		await pick("fire")
		await set_radius(3)
		var p := cell_px(Vector2(x0 + 4, h - 8))
		mouse_move(p)
		mouse_btn(p, MOUSE_BUTTON_LEFT, true)
		var line := PackedStringArray()
		for k in 6:
			await secs(5.0)
			if k == 1 and fuel == "wood":
				mouse_btn(p, MOUSE_BUTTON_LEFT, false)  # поджёг и отпустил
			line.append("%dс: низ стали %.0f средн %.0f" % [(k + 1) * 5, T(Vector2i(x0 + 4, h - 15)), block_mean(x0 - 2, h - 24, x0 + 11, h - 15, "steel")])
		mouse_btn(p, MOUSE_BUTTON_LEFT, false)
		await frames(2)
		lg("сталь над огнём (%s, кисть огня держим под блоком): %s" % [fuel, " | ".join(line)])
		await set_view(1)
		await shot("s10_steel_over_%s" % fuel)
