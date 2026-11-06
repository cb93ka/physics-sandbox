extends Node
## Сборка сцены: ядро (или заглушка), рендер мира, ввод, интерфейс, сохранения.
##
## Аргументы командной строки (после «--»):
##   --demo                       автосценарий: насыпать песок и налить воду
##   --demo-screenshot=<путь.png> то же + сохранить скриншот и выйти
##   --demo-frames=<N>            сколько кадров ждать до снимка (по умолчанию 600)
##   --demo-heat3                 включить «Разогрев ×3»
##   --demo-view=<0|1|2>          вид на снимке
##   --demo-modal=<saves|settings|clear>  открыть окно перед снимком
##   --demo-drawer=<open|closed>  шторка материалов на снимке
##   --ui-scale=<k>               масштаб интерфейса (на телефоне считается сам)
##   --safe-sim                   изобразить вырез iPhone (отступы безопасной зоны)
##   --touch-debug                мышь рисует через эмулированный тач (проверка жестов)

const GRID_HEIGHT := 180
const UNDO_LIMIT := 20
const HAPTIC_JUMP := 400.0

var state := AppState.new()
var sim: SimWorld
var loader := MaterialsLoader.new()
var palette: Array[Dictionary] = []
var undo := UndoStack.new(UNDO_LIMIT)

var world_view: WorldView
var cursor: BrushCursor
var hud: Hud
var input: BrushInput

var _args: Dictionary = {}
var _demo := false
var _demo_frame := 0
var _demo_frames := 180
var _demo_shot := ""
var _demo_reactor_core := Vector2i.ZERO
var _demo_probe := Vector2i.ZERO
var _last_max_temp := 20.0
var _haptic_cooldown := 0.0
var _gravity_sent := Vector2(0, 1)
var _settings_dirty := false
var _settings_timer := 0.0


func _ready() -> void:
	_args = _parse_args()
	_apply_ui_scale(float(_args.get("ui-scale", "0")))
	state.load_settings()

	sim = SimWorld.new()
	loader.load_all()
	if not loader.apply_to(sim):
		push_error("Не удалось загрузить материалы в ядро")
	sim.set_ambient_temp(loader.ambient_temp())
	palette = MaterialsLoader.build_palette(sim)
	state.material = _default_material()

	# Сначала интерфейс: размер мира зависит от свободного места между полосой и шторкой.
	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 2
	add_child(hud_layer)
	hud = Hud.new()
	hud.name = "Hud"
	hud_layer.add_child(hud)
	hud.setup(state, palette, loader.categories())
	if _args.has("safe-sim"):
		# Вырез iPhone в ландшафте: ~47 pt слева и справа, полоска «домой» снизу.
		hud.set_simulated_safe_area(Rect2(47, 0, 47, 21))
	# Размер мира считаем по области со свёрнутой шторкой — он не зависит от её состояния.
	hud.drawer.set_open(false)
	await get_tree().process_frame
	await get_tree().process_frame
	var area := hud.world_area()
	# На телефоне шторка по умолчанию свёрнута: экран низкий.
	var drawer_arg := str(_args.get("demo-drawer", ""))
	var open_drawer := not OS.has_feature("mobile")
	if drawer_arg != "":
		open_drawer = drawer_arg != "closed"
	if open_drawer:
		hud.drawer.set_open(true)
		await get_tree().process_frame
		await get_tree().process_frame
	var aspect := area.size.x / area.size.y
	if DisplayServer.get_name() == "headless" or area.size.y < 50.0:
		aspect = 16.0 / 9.0
	var w := clampi(roundi(float(GRID_HEIGHT) * aspect), GRID_HEIGHT, GRID_HEIGHT * 4)
	sim.setup(w, GRID_HEIGHT)
	print("Physics: мир %d×%d, материалов %d, ядро: %s%s" % [
		w, GRID_HEIGHT, palette.size(), "SandWorld" if sim.is_native else "заглушка",
		" (встроенный набор)" if loader.from_builtin else ""])

	world_view = WorldView.new()
	world_view.name = "WorldView"
	add_child(world_view)
	move_child(world_view, 0)
	world_view.set_area(hud.world_area(), false)
	world_view.setup(sim)
	hud.world_area_changed.connect(func(r: Rect2) -> void: world_view.set_area(r))

	var cursor_layer := CanvasLayer.new()
	cursor_layer.layer = 1
	add_child(cursor_layer)
	cursor = BrushCursor.new()
	cursor.visible = false
	cursor_layer.add_child(cursor)

	input = BrushInput.new()
	input.name = "BrushInput"
	add_child(input)
	input.setup(state, sim, world_view, hud, undo, cursor)
	input.touch_debug = _args.has("touch-debug")

	hud.undo_requested.connect(_undo)
	hud.step_requested.connect(_step)
	hud.clear_confirmed.connect(_clear)
	hud.save_requested.connect(_save_slot)
	hud.load_requested.connect(_load_slot)
	hud.reset_camera_requested.connect(world_view.fit)
	input.undo_requested.connect(_undo)
	input.step_requested.connect(_step)
	input.clear_requested.connect(hud.confirm_clear)
	state.changed.connect(_on_state_changed)
	if _args.has("demo-heat3"):
		state.fast_heat = true
	_on_state_changed()

	_demo_shot = str(_args.get("demo-screenshot", ""))
	_demo = _args.has("demo") or _demo_shot != ""
	_demo_frames = int(_args.get("demo-frames", "600"))


func _process(delta: float) -> void:
	if input == null:
		return  # ещё строится (ждём раскладку интерфейса)
	if not state.paused:
		sim.step(delta)
	world_view.refresh(state.view)
	_update_info()
	_update_tilt()
	if _settings_dirty:
		_settings_timer -= delta
		if _settings_timer <= 0.0:
			_settings_dirty = false
			state.save_settings()
	if _demo:
		_demo_tick()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		state.save_settings()


# =========================================================================
# Действия
# =========================================================================

func _on_state_changed() -> void:
	sim.set_heat_multiplier(3.0 if state.fast_heat else 1.0)
	if not state.tilt_gravity and _gravity_sent != Vector2(0, 1):
		_gravity_sent = Vector2(0, 1)
		sim.set_gravity(_gravity_sent)
	hud.sync()
	_settings_dirty = true
	_settings_timer = 1.0


func _undo() -> void:
	var snap := undo.pop()
	if snap.is_empty():
		return
	sim.load_bytes(snap)


func _step() -> void:
	if not state.paused:
		state.paused = true
		state.notify()
	sim.step_once()


func _clear() -> void:
	undo.push(sim.save_bytes())
	sim.clear()


func _save_slot(slot: int) -> void:
	SaveSlots.save(slot, sim.save_bytes(), world_view.snapshot_image(0))


func _load_slot(slot: int) -> void:
	var data := SaveSlots.load_data(slot)
	if data.is_empty():
		return
	undo.push(sim.save_bytes())
	if not sim.load_bytes(data):
		undo.pop()
		push_warning("Слот %d не читается этим ядром" % slot)


# =========================================================================
# Термометр, счётчики, наклон, хаптика
# =========================================================================

func _update_info() -> void:
	var c := input.pointer_cell()
	if world_view.in_world(c):
		var cell := sim.get_cell(c)
		var t := float(cell.get("temp", 0.0))
		var t_text := ("%.1f" % t) if absf(t) < 1000.0 else ("%d" % roundi(t))
		hud.set_cell_info("%s  %s °C" % [str(cell.get("name", "?")), t_text])
	else:
		hud.set_cell_info("")
	var st := sim.get_stats()
	var max_t := float(st.get("max_temp", 0.0))
	if state.show_stats:
		var lines := PackedStringArray([
			"FPS %d" % Engine.get_frames_per_second(),
			"шаг %.2f мс" % float(st.get("step_ms", 0.0)),
			"нейтроны %d" % int(st.get("neutrons", 0)),
			"делений/с %d" % roundi(float(st.get("fissions_per_sec", 0.0))),
			"макс. T %d °C" % roundi(max_t),
		])
		if not sim.is_native:
			lines.append("ядро: заглушка")
		hud.set_stats_text("\n".join(lines))
	# Хаптика: резкий скачок максимальной температуры ≈ взрыв.
	_haptic_cooldown = maxf(0.0, _haptic_cooldown - get_process_delta_time())
	if state.haptics and OS.has_feature("mobile") and _haptic_cooldown <= 0.0 \
			and max_t - _last_max_temp > HAPTIC_JUMP:
		Input.vibrate_handheld(40)
		_haptic_cooldown = 0.4
	_last_max_temp = max_t


func _update_tilt() -> void:
	if not state.tilt_gravity:
		return
	var acc := Input.get_accelerometer()
	var g := Vector2(acc.x, -acc.y)
	if g.length() < 2.0:
		return
	# Ядро всё равно округляет к 8 направлениям — шлём только при смене октанта.
	var ang := snappedf(g.angle(), PI / 4.0)
	var dir := Vector2.from_angle(ang)
	if dir.distance_to(_gravity_sent) > 0.1:
		_gravity_sent = dir
		sim.set_gravity(dir)


# =========================================================================
# Запуск
# =========================================================================

func _default_material() -> int:
	var sand := sim.find_material("sand")
	if sand > 0:
		return sand
	for e in palette:
		if not bool(e["hidden"]) and int(e["index"]) != 0:
			return int(e["index"])
	return 0


func _parse_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return out


## На телефоне делаем 1 логический px интерфейса ≈ 1 pt, чтобы кнопки 44 px были 44 pt.
func _apply_ui_scale(override: float) -> void:
	var k := override
	if k <= 0.0:
		if not OS.has_feature("mobile"):
			return
		var win := Vector2(DisplayServer.window_get_size())
		if win.x <= 0.0 or win.y <= 0.0:
			return
		var scr := maxf(DisplayServer.screen_get_scale(), float(DisplayServer.screen_get_dpi()) / 163.0)
		var stretch := minf(win.x / 1280.0, win.y / 720.0)
		k = scr / stretch
	get_window().content_scale_factor = clampf(k, 1.0, 4.0)


# =========================================================================
# Демо-сценарий (--demo / --demo-screenshot=…)
# =========================================================================

func _demo_tick() -> void:
	_demo_frame += 1
	var w := sim.get_width()
	var h := sim.get_height()
	if _demo_frame == 2:
		_demo_build(w, h)
	if _demo_frame > 2:
		# Термометр демо смотрит на воду в кастрюле, даже если мышь двигали.
		input.pointer_pos = world_view.cell_to_screen(Vector2(_demo_probe) + Vector2(0.5, 0.5))
		input.pointer_valid = true
	if _demo_frame > 2 and _demo_frame < int(_demo_frames * 0.4):
		# Струя песка в центре.
		sim.paint_circle(Vector2i(roundi(w * 0.36), 6), 1, _mat("sand"), 0)
	if _demo_frame == 5 or (_demo_frame < int(_demo_frames * 0.5) and _demo_frame % 30 == 0):
		# Затравочные нейтроны в реактор.
		sim.spawn_neutrons(_demo_reactor_core, 3, 30 if _demo_frame == 5 else 8)
	if _demo_frame == _demo_frames - 10:
		var modal := str(_args.get("demo-modal", ""))
		match modal:
			"saves": hud.open_saves()
			"settings": hud.open_settings()
			"clear": hud.confirm_clear()
	if _demo_frame >= _demo_frames:
		_demo = false
		_demo_finish()


## Демо-стенд: слева «кастрюля» на нагревателе, в центре песок и стакан с маслом
## под водой (масло всплывает), справа маленький реактор в графите.
func _demo_build(w: int, h: int) -> void:
	state.view = clampi(int(_args.get("demo-view", "0")), 0, 2)
	state.material = _mat("water")
	for k: String in ["uranium235", "boron_carbide", "graphite", "steel", "water", "sand"]:
		state.push_recent(k)
	state.notify()
	var wall := _mat("wall") if _mat("wall") > 0 else _mat("stone")
	var steel := _mat("steel")
	var water := _mat("water")
	_rect(0, h - 3, w - 1, h - 1, wall)

	# Кастрюля: нагреватель 56×4, стальное дно и стенки по 3, вода 50×30.
	# Не под колонкой инструментов.
	var tools_edge := world_view.screen_to_cell(Vector2(hud.tool_bar.get_global_rect().end.x + 12.0, 0.0)).x
	var px := maxi(roundi(w * 0.05), tools_edge)
	_rect(px, h - 7, px + 55, h - 4, _mat("heater"))
	_rect(px, h - 10, px + 55, h - 8, steel)
	_rect(px, h - 46, px + 2, h - 11, steel)
	_rect(px + 53, h - 46, px + 55, h - 11, steel)
	_rect(px + 3, h - 40, px + 52, h - 11, water)
	_demo_probe = Vector2i(px + 28, h - 20)

	# Песок: готовая горка, сверху на неё сыплется струя.
	var sx := roundi(w * 0.34)
	for i in 7:
		sim.paint_circle(Vector2i(sx - 15 + i * 5, h - 7 - (3 - absi(i - 3)) * 3), 6, _mat("sand"), 0)

	# Стакан из стекла: масло снизу, вода сверху — масло легче и всплывает.
	var gx := roundi(w * 0.54)
	var glass := _mat("glass")
	_rect(gx - 20, h - 66, gx - 19, h - 4, glass)
	_rect(gx + 19, h - 66, gx + 20, h - 4, glass)
	_rect(gx - 18, h - 5, gx + 18, h - 4, glass)
	_rect(gx - 18, h - 26, gx + 18, h - 6, _mat("oil"))
	_rect(gx - 18, h - 54, gx + 18, h - 27, water)

	# Реактор: графитовая рамка, вода-замедлитель, блок U-235 10×8 с водяными
	# прослойками и два стержня карбида бора по бокам.
	var rx := w - roundi(w * 0.14)
	var graphite := _mat("graphite")
	_rect(rx - 26, h - 62, rx + 26, h - 4, graphite)
	_rect(rx - 22, h - 58, rx + 22, h - 8, water)
	_rect(rx - 22, h - 62, rx + 22, h - 59, 0)
	var u := _mat("uranium235")
	var yb := h - 38
	for layer in 3:
		_rect(rx - 5, yb + layer * 3, rx + 4, yb + layer * 3 + 1, u)
	var boron := _mat("boron_carbide")
	_rect(rx - 16, h - 50, rx - 14, h - 24, boron)
	_rect(rx + 14, h - 50, rx + 16, h - 24, boron)
	_demo_reactor_core = Vector2i(rx, yb + 4)



## Прямоугольник клеток (включительно), режим «заменять».
func _rect(x0: int, y0: int, x1: int, y1: int, mat: int) -> void:
	for y in range(y0, y1 + 1):
		sim.paint_line(Vector2i(x0, y), Vector2i(x1, y), 0, mat, 1)


func _demo_finish() -> void:
	if _demo_shot == "":
		print("Physics demo: готово")
		return
	if DisplayServer.get_name() == "headless":
		print("Physics demo: headless — скриншот пропущен")
		get_tree().quit()
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_demo_shot.get_base_dir())
	var err := img.save_png(_demo_shot)
	print("Physics demo: скриншот %s (%dx%d) err=%d" % [_demo_shot, img.get_width(), img.get_height(), err])
	get_tree().quit()


func _mat(id: String) -> int:
	return maxi(0, sim.find_material(id))
