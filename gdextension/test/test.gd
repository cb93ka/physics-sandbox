extends SceneTree
# Headless smoke/physics test for SandWorld.
#   godot --headless --path <project with bin/ and fixture_materials.json> -s test.gd
# Optional user args (after "--"): tts=<thermal_time_scale>, only=<sand|pot|nuke|perf|save>

var w
var M := {}
var args := {}

func _init() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=")
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	w = ClassDB.instantiate("SandWorld")
	if w == null:
		push_error("SandWorld class not found (extension not loaded)")
		quit(1)
		return
	var f := FileAccess.open("res://fixture_materials.json", FileAccess.READ)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	if args.has("tts"):
		data["thermal_time_scale"] = float(args["tts"])
	if not w.load_materials(data):
		quit(1)
		return
	w.load_reactions({"version": 1, "reactions": []})
	for i in w.get_material_count():
		var info: Dictionary = w.get_material_info(i)
		M[info["str_id"]] = i
	print("materials: ", w.get_material_count(), "  thermal_time_scale=", w.get_thermal_time_scale())
	var only: String = args.get("only", "")
	if only == "" or only == "sand": test_sand_water()
	if only == "" or only == "pot":
		test_pot(1.0)
		test_pot(3.0)
	if only == "" or only == "nuke": test_nuclear()
	if only == "" or only == "save": test_save()
	if only == "" or only == "misc": test_misc()
	if only == "" or only == "perf": test_perf()
	quit(0)

func region_stats(id: int) -> Dictionary:
	var minx := 99999; var maxx := -1; var miny := 99999; var maxy := -1; var sy := 0.0; var n := 0
	for y in w.get_height():
		for x in w.get_width():
			if w.get_cell(Vector2i(x, y))["mat"] == id:
				minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
				sy += y; n += 1
	return {"n": n, "minx": minx, "maxx": maxx, "miny": miny, "maxy": maxy, "meany": sy / max(n, 1)}

func test_sand_water() -> void:
	print("\n== sand & water ==")
	w.setup(320, 180)
	w.set_heat_multiplier(1.0)
	w.paint_circle(Vector2i(80, 40), 15, M.sand, 1)
	w.paint_circle(Vector2i(230, 40), 20, M.water, 1)
	var s0: Dictionary = region_stats(M.sand)
	var w0: Dictionary = region_stats(M.water)
	for i in 600:
		w.step_once()
	var s1: Dictionary = region_stats(M.sand)
	var w1: Dictionary = region_stats(M.water)
	print("sand  before: ", s0)
	print("sand  after : ", s1)
	print("water before: ", w0)
	print("water after : ", w1)
	var sand_ok: bool = s1.maxy == 179 and s1.miny > 140 and s1.n == s0.n
	var water_ok: bool = w1.maxy == 179 and (w1.maxx - w1.minx) > 2 * (w0.maxx - w0.minx) and w1.n == w0.n
	print("sand settled on the floor: ", sand_ok, "   water spread: ", water_ok, " (width ", w0.maxx - w0.minx + 1, " -> ", w1.maxx - w1.minx + 1, ", height ", w1.maxy - w1.miny + 1, ")")
	print("stats: ", w.get_stats())

func build_pot() -> void:
	w.setup(320, 180)
	# heater 24 wide, 3 thick, at the floor
	for y in range(177, 180):
		for x in range(148, 172):
			w.paint_circle(Vector2i(x, y), 0, M.heater, 1)
	# steel bottom (2 thick) and walls (2 thick, 12 high)
	for y in range(175, 177):
		for x in range(148, 172):
			w.paint_circle(Vector2i(x, y), 0, M.steel, 1)
	for y in range(163, 175):
		for x in [148, 149, 170, 171]:
			w.paint_circle(Vector2i(x, y), 0, M.steel, 1)
	# water 20x10
	for y in range(165, 175):
		for x in range(150, 170):
			w.paint_circle(Vector2i(x, y), 0, M.water, 1)

func steel_bottom_mean() -> float:
	var s := 0.0; var n := 0
	for y in range(175, 177):
		for x in range(150, 170):
			s += w.get_cell(Vector2i(x, y))["temp"]; n += 1
	return s / n

func test_pot(mult: float) -> void:
	print("\n== pot, heat_multiplier=", mult, " ==")
	build_pot()
	w.set_heat_multiplier(mult)
	var t_steel := -1.0
	var t_water50 := -1.0
	var t_steam := -1.0
	var water_at_steel := -1.0
	var steps := int(200.0 * 60.0 / mult)
	var steam_peak := 0
	var water0: int = w.count_material(M.water)
	for i in steps:
		w.step_once()
		var t := (i + 1) / 60.0
		if t_steel < 0 and steel_bottom_mean() > 100.0:
			t_steel = t
			water_at_steel = w.get_mean_temp(M.water)
		if t_water50 < 0 and w.get_mean_temp(M.water) >= 50.0:
			t_water50 = t
		var sc: int = w.count_material(M.steam)
		steam_peak = max(steam_peak, sc)
		if t_steam < 0 and sc > 0:
			t_steam = t
			print("  first steam at t=%.1f s: water mean %.1f C, steel bottom %.1f C" % [t, w.get_mean_temp(M.water), steel_bottom_mean()])
		if t_steam > 0 and t > t_steam + 10.0 / mult:
			break
		if i % int(600 / mult) == 0:
			print("  t=%5.1f  steel_bottom=%6.1f  water_mean=%5.1f  steam=%d" % [t, steel_bottom_mean(), w.get_mean_temp(M.water), sc])
	print("steel bottom > 100 C at t=%.1f s (water mean then %.1f C); water mean >= 50 C at t=%.1f s" % [t_steel, water_at_steel, t_water50])
	print("first steam at t=%.1f s; water cells %d -> %d after %.0f s more (latent heat: not all at once)" % [t_steam, water0, w.count_material(M.water), 10.0 / mult])
	print("RESULT pot mult=%.0f steam=%.1f steel100=%.1f water50=%.1f" % [mult, t_steam, t_steel, t_water50])

func lattice(fuel: int, other: int, cx: int, cy: int, size: int, period: int, fuel_w: int) -> void:
	for y in range(cy - size / 2, cy + size / 2):
		for x in range(cx - size / 2, cx + size / 2):
			var m := fuel if ((x - cx + size) % period) < fuel_w else other
			w.paint_circle(Vector2i(x, y), 0, m, 1)

func run_nuke(label: String, fuel_w: int, other: int, size: int) -> void:
	w.setup(320, 180)
	w.set_heat_multiplier(1.0)
	if other < 0:
		for y in range(90 - size / 2, 90 + size / 2):
			for x in range(160 - size / 2, 160 + size / 2):
				w.paint_circle(Vector2i(x, y), 0, M.uranium235, 1)
	else:
		lattice(M.uranium235, other, 160, 90, size, 6, fuel_w)
		# stone floor under the lattice keeps liquid moderators in place (stone is transparent to neutrons)
		for x in range(160 - size / 2, 160 + size / 2):
			w.paint_circle(Vector2i(x, 90 + size / 2), 0, M.stone, 1)
	w.spawn_neutrons(Vector2i(160, 90), 4, 50)
	var line := ""
	for s in 10:
		for i in 30:
			w.step_once()
		var st: Dictionary = w.get_stats()
		line += "%d " % int(st.fissions_per_sec)
	var st2: Dictionary = w.get_stats()
	print("%-34s fissions/s every 0.5 s: %s | neutrons=%d max_temp=%.0f corium=%d step_ms=%.2f" % [label, line, st2.neutrons, st2.max_temp, w.count_material(M.corium), st2.step_ms])

func test_nuclear() -> void:
	print("\n== nuclear (5 s each) ==")
	run_nuke("bare U-235 10x10", 0, -1, 10)
	run_nuke("bare U-235 40x40", 0, -1, 40)
	run_nuke("U-235 + graphite lattice 40x40", 3, M.graphite, 40)
	run_nuke("U-235 + water lattice 40x40", 3, M.water, 40)
	run_nuke("U-235 + boron carbide 40x40", 3, M.boron_carbide, 40)

func test_save() -> void:
	print("\n== save/load ==")
	w.setup(64, 48)
	w.paint_circle(Vector2i(20, 20), 6, M.sand, 1)
	w.paint_circle(Vector2i(40, 20), 6, M.water, 1)
	w.heat_circle(Vector2i(40, 20), 3, 500.0, 1.0)
	w.spawn_neutrons(Vector2i(10, 10), 2, 5)
	var b: PackedByteArray = w.save_bytes()
	var c1: Dictionary = w.get_cell(Vector2i(40, 20))
	w.clear()
	var ok: bool = w.load_bytes(b)
	var c2: Dictionary = w.get_cell(Vector2i(40, 20))
	print("bytes=", b.size(), " load ok=", ok, " cell before=", c1, " after=", c2, " neutrons=", w.get_stats().neutrons)

func test_perf() -> void:
	print("\n== performance 320x180, 50% filled ==")
	w.setup(320, 180)
	w.set_heat_multiplier(3.0)
	# lower half: sand, water, stone, steel blocks; upper area: falling sand/water rain
	for x in range(0, 320, 1):
		for y in range(92, 180):
			var m: int = M.water if (x / 40) % 2 == 0 else M.sand
			w.paint_circle(Vector2i(x, y), 0, m, 1)
	w.paint_circle(Vector2i(60, 60), 14, M.sand, 1)
	w.paint_circle(Vector2i(160, 50), 16, M.water, 1)
	w.paint_circle(Vector2i(260, 60), 14, M.sand, 1)
	for y in range(100, 120):
		for x in range(130, 190):
			w.paint_circle(Vector2i(x, y), 0, M.steel, 1)
	for x in range(150, 170):
		w.paint_circle(Vector2i(x, 99), 0, M.heater, 1)
	var filled := 0
	for i in w.get_material_count():
		if i != 0: filled += w.count_material(i)
	print("filled: %.0f %%" % (100.0 * filled / (320 * 180)))
	var t0 := Time.get_ticks_usec()
	var worst := 0.0
	for i in 600:
		var a := Time.get_ticks_usec()
		w.step_once()
		worst = max(worst, (Time.get_ticks_usec() - a) / 1000.0)
	var avg := (Time.get_ticks_usec() - t0) / 1000.0 / 600.0
	var t1 := Time.get_ticks_usec()
	for i in 60:
		w.get_color_buffer(0)
	var cb := (Time.get_ticks_usec() - t1) / 1000.0 / 60.0
	print("RESULT perf avg_step_ms=%.3f worst_ms=%.3f stats.step_ms=%.3f color_buffer_ms=%.3f active_chunks=%d" % [avg, worst, w.get_stats().step_ms, cb, w.get_stats().active_chunks])
	# active scene with neutrons too
	lattice(M.uranium235, M.graphite, 160, 40, 30, 6, 3)
	w.spawn_neutrons(Vector2i(160, 40), 4, 100)
	t0 = Time.get_ticks_usec()
	for i in 300:
		w.step_once()
	avg = (Time.get_ticks_usec() - t0) / 1000.0 / 300.0
	print("RESULT perf+reactor avg_step_ms=%.3f neutrons=%d fissions/s=%d" % [avg, w.get_stats().neutrons, int(w.get_stats().fissions_per_sec)])

func test_misc() -> void:
	print("\n== misc: burning, convection, gravity, views ==")
	w.setup(160, 90)
	w.set_heat_multiplier(1.0)
	for x in range(60, 100):
		w.paint_circle(Vector2i(x, 89), 0, M.heater, 1)
	for y in range(80, 89):
		for x in range(70, 90):
			w.paint_circle(Vector2i(x, y), 0, M.wood, 1)
	var seen_fire := 0
	var air_above := 0.0
	for i in 60 * 90:
		w.step_once()
		seen_fire = max(seen_fire, w.count_material(M.fire))
		if i == 60 * 5:
			air_above = w.get_cell(Vector2i(65, 70))["temp"]
	print("wood on 400 C heater, 90 s: wood %d/180 left, peak fire cells %d, ash %d, smoke %d; air 19 cells above heater edge at 5 s: %.1f C" % [w.count_material(M.wood), seen_fire, w.count_material(M.ash), w.count_material(M.smoke), air_above])
	# gravity to the right
	w.setup(64, 32)
	w.paint_circle(Vector2i(10, 16), 5, M.sand, 1)
	w.set_gravity(Vector2(1, 0))
	for i in 300:
		w.step_once()
	var st: Dictionary = region_stats(M.sand)
	print("gravity (1,0): sand maxx=%d (wall at 63), minx=%d" % [st.maxx, st.minx])
	w.set_gravity(Vector2(0, 1))
	# views
	for v in 3:
		var b: PackedByteArray = w.get_color_buffer(v)
		print("view %d: %d bytes (expected %d)" % [v, b.size(), 64 * 32 * 4])
	# heat tool
	w.setup(32, 32)
	w.paint_circle(Vector2i(16, 16), 3, M.stone, 1)
	w.heat_circle(Vector2i(16, 16), 0, 1000.0, 1.0)
	print("heat_circle 1000 W x 1 s into one stone cell: %.1f C (expected %.1f)" % [w.get_cell(Vector2i(16, 16))["temp"], 20.0 + 1000.0 / (2600.0 * 790.0 * 1e-6)])
