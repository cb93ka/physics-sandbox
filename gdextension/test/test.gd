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
	var f := FileAccess.open(args.get("data", "res://fixture_materials.json"), FileAccess.READ)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	if args.has("tts"):
		data["thermal_time_scale"] = float(args["tts"])
	if not w.load_materials(data):
		quit(1)
		return
	if args.has("reactions"):
		w.load_reactions(JSON.parse_string(FileAccess.open(args["reactions"], FileAccess.READ).get_as_text()))
	else:
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
	if only == "" or only == "ice": test_ice()
	if only == "" or only == "float": test_float()
	if only == "" or only == "air": test_air()
	if only == "" or only == "boron": test_boron()
	if only == "" or only == "perf": test_perf()
	if only == "" or only == "perf": test_perf_wide()
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
	# v1 save (no air field): patch the version and cut the air block off
	var gs: Vector2i = w.get_air_grid_size()
	var v1 := b.duplicate()
	v1.encode_u32(4, 1)
	v1.resize(v1.size() - (8 + gs.x * gs.y * 8))
	w.clear()
	var ok1: bool = w.load_bytes(v1)
	var vel: PackedFloat32Array = w.get_air_velocity()
	var vmax := 0.0
	for k in vel.size(): vmax = max(vmax, abs(vel[k]))
	print("RESULT save v2 ok=%s, v1 (no air) ok=%s, cell after v1 load=%s, air |v|max=%.1f" % [ok, ok1, w.get_cell(Vector2i(40, 20)), vmax])

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


# ---------------------------------------------------------------- v0.1.1: air field, sources
func air_at(vel: PackedFloat32Array, aw: int, ax: int, ay: int) -> Vector2:
	var i := (ay * aw + ax) * 2
	return Vector2(vel[i], vel[i + 1])

func mean_x(id: int) -> float:
	return region_stats(id).get("minx", 0) * 0.0 + _mean_coord(id).x

func _mean_coord(id: int) -> Vector2:
	var s := Vector2.ZERO; var n := 0
	for y in w.get_height():
		for x in w.get_width():
			if w.get_cell(Vector2i(x, y))["mat"] == id:
				s += Vector2(x, y); n += 1
	return s / max(n, 1)

func test_air() -> void:
	print("\n== air field ==")
	# 1. plume over a heater
	w.setup(320, 180)
	w.set_heat_multiplier(1.0)
	for y in range(176, 180):
		for x in range(140, 180):
			w.paint_circle(Vector2i(x, y), 0, M.heater, 1)
	for i in 600:
		w.step_once()
	var gs: Vector2i = w.get_air_grid_size()
	var vel: PackedFloat32Array = w.get_air_velocity()
	var vy := 0.0; var n := 0
	for ay in range(20, 42):
		for ax in range(36, 44):
			vy += air_at(vel, gs.x, ax, ay).y; n += 1
	vy /= n
	var vx_left := 0.0; var vx_right := 0.0
	for ay in range(36, 44):
		for ax in range(24, 34): vx_left += air_at(vel, gs.x, ax, ay).x
		for ax in range(46, 56): vx_right += air_at(vel, gs.x, ax, ay).x
	vx_left /= 80.0; vx_right /= 80.0
	var maxs := 0.0
	for k in range(0, vel.size(), 2): maxs = max(maxs, Vector2(vel[k], vel[k + 1]).length())
	print("plume over heater (10 s): grid %s scale %d, mean vy above heater %.1f cells/s (up < 0), inflow near floor: left vx %.1f, right vx %.1f, max |v| %.1f" % [gs, w.get_air_cell_scale(), vy, vx_left, vx_right, maxs])
	print("RESULT air plume_vy=%.1f ok=%s" % [vy, vy < -3.0])
	# 1b. closed box with one heater: narrow plume, slow return flow, still air far away
	w.setup(320, 180)
	for y in range(176, 180):
		for x in range(150, 170):
			w.paint_circle(Vector2i(x, y), 0, M.heater, 1)
	for i in 1200:
		w.step_once()
	gs = w.get_air_grid_size()
	vel = w.get_air_velocity()
	var fast := 0; var cells := 0; var vy_all := 0.0; var vy_out := 0.0; var n_out := 0
	var far_speed := 0.0; var n_far := 0; var vy_col := 0.0; var n_col := 0; var vmax_col := 0.0
	for ay in gs.y:
		for ax in gs.x:
			var v := air_at(vel, gs.x, ax, ay)
			cells += 1
			vy_all += v.y
			if v.length() > 10.0: fast += 1
			if abs(ax - 40) > 10:
				vy_out += v.y; n_out += 1
			if abs(ax - 40) > 25:
				far_speed += v.length(); n_far += 1
			if abs(ax - 40) <= 3:
				vy_col += v.y; n_col += 1; vmax_col = max(vmax_col, -v.y)
	var frac := float(fast) / cells
	vy_all /= cells; vy_out /= n_out; vy_col /= n_col; far_speed /= n_far
	print("closed box, 20 s: |v|>10 in %.1f %% of cells; plume mean vy %.1f (peak up %.1f); outside |dx|>10 mean vy %.2f (return flow); far |dx|>25 mean |v| %.1f; whole-box mean vy %.2f" % [frac * 100.0, vy_col, vmax_col, vy_out, far_speed, vy_all])
	print("RESULT air box fast_frac=%.3f ok=%s box_mean_vy=%.2f ok=%s far_speed=%.1f ok=%s" % [frac, frac < 0.25, vy_all, abs(vy_all) < 2.0, far_speed, far_speed < 5.0])
	# 2. fan blows smoke
	var dx := []
	for with_fan in [false, true]:
		w.setup(320, 180)
		# horizontal channel (stone floor and ceiling) keeps the light smoke in the jet
		for x in range(0, 320):
			w.paint_circle(Vector2i(x, 78), 0, M.stone, 1)
			w.paint_circle(Vector2i(x, 101), 0, M.stone, 1)
		if with_fan:
			for y in range(80, 100):
				for x in range(20, 23):
					w.paint_circle(Vector2i(x, y), 0, M.fan_right, 1)
		w.paint_circle(Vector2i(40, 90), 6, M.smoke, 1)
		var x0: float = _mean_coord(M.smoke).x
		for i in 120:
			w.step_once()
		dx.append(_mean_coord(M.smoke).x - x0)
	print("smoke drift in 2 s: without fan %.1f cells, with fan_right %.1f cells" % [dx[0], dx[1]])
	print("RESULT air fan ok=%s" % [dx[1] > dx[0] + 10.0])
	# 3. explosion ring
	w.setup(320, 180)
	w.paint_circle(Vector2i(160, 90), 2, M.tnt, 1)
	w.heat_circle(Vector2i(160, 90), 2, 1e6, 1.0)
	for i in 3:
		w.step_once()
	gs = w.get_air_grid_size()
	vel = w.get_air_velocity()
	var pos := 0; var tot := 0; var vr_sum := 0.0
	var c := Vector2(160.0 / 4.0 - 0.5, 90.0 / 4.0 - 0.5)
	for k in 16:
		var a := TAU * k / 16.0
		for rr in [6, 8, 10]:
			var p: Vector2 = c + Vector2(cos(a), sin(a)) * rr
			var v := air_at(vel, gs.x, int(round(p.x)), int(round(p.y)))
			var vr := v.dot(Vector2(cos(a), sin(a)))
			vr_sum += vr; tot += 1
			if vr > 1.0: pos += 1
	print("explosion (3 steps): %d/%d samples on rings r=6,8,10 air cells move outwards, mean radial %.1f cells/s" % [pos, tot, vr_sum / tot])
	print("RESULT air ring ok=%s" % [pos >= tot * 0.8])
	# 4. tap fills, 5. void drains
	w.setup(160, 90)
	w.paint_circle(Vector2i(80, 10), 1, M.tap_water, 1)
	for i in 300:
		w.step_once()
	var filled: int = w.count_material(M.water)
	var taps: int = w.count_material(M.tap_water)
	w.setup(160, 90)
	for y in range(70, 89):
		for x in range(40, 120):
			w.paint_circle(Vector2i(x, y), 0, M.water, 1)
	for x in range(40, 120):
		w.paint_circle(Vector2i(x, 89), 0, M.void, 1)
	var before: int = w.count_material(M.water)
	for i in 120:
		w.step_once()
	var after: int = w.count_material(M.water)
	print("tap_water (%d cells) 5 s: %d water cells; void line under %d water cells, 2 s later %d" % [taps, filled, before, after])
	print("RESULT tap=%d void %d->%d" % [filled, before, after])
	# layers
	var t0 := Time.get_ticks_usec()
	for v in [0, 1, 3]:
		var b: PackedByteArray = w.get_air_layer(v)
		if b.size() != w.get_air_grid_size().x * w.get_air_grid_size().y * 4:
			print("air layer size mismatch")
	print("air layers: %d bytes each, 3 views in %.3f ms" % [w.get_air_layer(0).size(), (Time.get_ticks_usec() - t0) / 1000.0])
	var cb: PackedByteArray = w.get_color_buffer(0)
	print("air alpha in color buffer (top-left cell): %d" % cb[3])

func build_front_reactor(rods: int) -> Vector2i:
	# replica of scripts/main.gd demo reactor
	var W2: int = w.get_width(); var h: int = w.get_height()
	var rx := W2 - roundi(W2 * 0.14)
	var _r := func(x0: int, y0: int, x1: int, y1: int, m: int) -> void:
		for y in range(y0, y1 + 1):
			w.paint_line(Vector2i(x0, y), Vector2i(x1, y), 0, m, 1)
	_r.call(rx - 26, h - 62, rx + 26, h - 4, M.graphite)
	_r.call(rx - 22, h - 58, rx + 22, h - 8, M.water)
	_r.call(rx - 22, h - 62, rx + 22, h - 59, 0)
	var yb := h - 38
	for layer in 3:
		_r.call(rx - 5, yb + layer * 3, rx + 4, yb + layer * 3 + 1, M.uranium235)
	if rods == 1:
		_r.call(rx - 16, h - 50, rx - 14, h - 24, M.boron_carbide)
		_r.call(rx + 14, h - 50, rx + 16, h - 24, M.boron_carbide)
	elif rods == 2:
		# rods inserted into the core: between fuel columns
		_r.call(rx - 1, h - 50, rx, h - 24, M.boron_carbide)
		_r.call(rx - 8, h - 50, rx - 7, h - 24, M.boron_carbide)
		_r.call(rx + 6, h - 50, rx + 7, h - 24, M.boron_carbide)
	return Vector2i(rx, yb + 4)

func test_boron() -> void:
	print("\n== boron rods, front demo reactor (570x180) ==")
	for rods in [0, 1, 2]:
		w.setup(570, 180)
		w.set_heat_multiplier(1.0)
		var core := build_front_reactor(rods)
		w.spawn_neutrons(core, 3, 30)
		var line := ""
		for s in 10:
			for i in 60:
				w.step_once()
			line += "%d " % int(w.get_stats().neutrons)
		var label: String = ["no rods", "2 rods at the sides (front)", "3 rods inside the core"][rods]
		print("%-30s neutrons every 1 s: %s| fissions/s %d" % [label, line, int(w.get_stats().fissions_per_sec)])
	# rod leak test: neutrons crossing a 1-cell boron wall (flux shows up in view 2 as alpha of air cells)
	for wall in [false, true]:
		w.setup(200, 60)
		if wall:
			for y in 60:
				w.paint_circle(Vector2i(100, y), 0, M.boron_carbide, 1)
		var right := 0
		for k in 20:
			w.spawn_neutrons(Vector2i(60, 30), 3, 400)
			w.step_once()
			var b: PackedByteArray = w.get_color_buffer(2)
			for y in 60:
				for x in range(102, 200):
					right += b[(y * 200 + x) * 4 + 3]
		print("flux behind x=100 %s: %d" % ["with a 1-cell boron wall" if wall else "without wall", right])

func perf_scene(width: int) -> void:
	w.setup(width, 180)
	w.set_heat_multiplier(3.0)
	for x in range(0, width):
		for y in range(92, 180):
			var m: int = M.water if (x / 40) % 2 == 0 else M.sand
			w.paint_circle(Vector2i(x, y), 0, m, 1)
	w.paint_circle(Vector2i(60, 60), 14, M.sand, 1)
	w.paint_circle(Vector2i(160, 50), 16, M.water, 1)
	for y in range(100, 120):
		for x in range(130, 190):
			w.paint_circle(Vector2i(x, y), 0, M.steel, 1)
	for x in range(150, 170):
		w.paint_circle(Vector2i(x, 99), 0, M.heater, 1)
	w.paint_circle(Vector2i(width - 60, 60), 8, M.smoke, 1)
	lattice(M.uranium235, M.graphite, width / 2, 40, 30, 6, 3)
	w.spawn_neutrons(Vector2i(width / 2, 40), 4, 100)

func time_steps(k: int) -> float:
	var t0 := Time.get_ticks_usec()
	for i in k:
		w.step_once()
	return (Time.get_ticks_usec() - t0) / 1000.0 / k

func test_perf_wide() -> void:
	print("\n== performance with air field ==")
	for width in [320, 570]:
		perf_scene(width)
		var warm := time_steps(120)
		var on := time_steps(240)
		var st: Dictionary = w.get_stats()
		print("  step_ms %.3f pass ms: " % st.step_ms, st.pass_ms)
		w.set_air_enabled(false)
		var off := time_steps(240)
		w.set_air_enabled(true)
		var views := ""
		for v in 4:
			var t0 := Time.get_ticks_usec()
			for i in 30:
				w.get_color_buffer(v)
			views += "v%d=%.3f " % [v, (Time.get_ticks_usec() - t0) / 1000.0 / 30.0]
		var t1 := Time.get_ticks_usec()
		for i in 30:
			w.get_air_layer(3)
		var al := (Time.get_ticks_usec() - t1) / 1000.0 / 30.0
		print("RESULT perf %dx180: step %.3f ms (air on), %.3f ms (air off) -> air %.3f ms; neutrons %d; color_buffer ms %s; air_layer %.3f ms" % [width, on, off, on - off, st.neutrons, views, al])


func test_ice() -> void:
	print("\n== ice cube 3x3 in water at 20 C (x1) ==")
	w.setup(120, 60)
	w.set_heat_multiplier(1.0)
	for y in range(30, 60):
		for x in range(40, 80):
			var m: int = M.stone if (x < 42 or x >= 78 or y >= 58) else M.water
			w.paint_circle(Vector2i(x, y), 0, m, 1)
	for y in range(40, 43):
		for x in range(58, 61):
			w.paint_circle(Vector2i(x, y), 0, M.ice, 1)
	var t_first := -1.0
	var t_all := -1.0
	for i in 60 * 400:
		w.step_once()
		var n: int = w.count_material(M.ice)
		if t_first < 0 and n < 9: t_first = (i + 1) / 60.0
		if n == 0:
			t_all = (i + 1) / 60.0
			break
	print("RESULT ice first cell %.1f s, all melted %.1f s, water mean %.1f C" % [t_first, t_all, w.get_mean_temp(M.water)])

func test_float() -> void:
	print("\n== movable_solid ==")
	w.setup(120, 80)
	for y in range(40, 80):
		for x in range(30, 90):
			var m: int = M.stone if (x < 32 or x >= 88 or y >= 78) else M.water
			w.paint_circle(Vector2i(x, y), 0, m, 1)
	for y in range(72, 75):
		for x in range(40, 43):
			w.paint_circle(Vector2i(x, y), 0, M.wood, 1)
	for y in range(5, 8):
		for x in range(70, 73):
			w.paint_circle(Vector2i(x, y), 0, M.ice, 1)
	for y in range(5, 8):
		for x in range(60, 63):
			w.paint_circle(Vector2i(x, y), 0, M.wood, 1)
	for i in 600:
		w.step_once()
	var wood: Dictionary = region_stats(M.wood)
	var ice: Dictionary = region_stats(M.ice)
	print("wood (one block from the bottom, one dropped): rows %d..%d, cols %d..%d; ice dropped: rows %d..%d cols %d..%d; water surface row 40" % [wood.miny, wood.maxy, wood.minx, wood.maxx, ice.miny, ice.maxy, ice.minx, ice.maxx])
	var ok: bool = wood.maxy < 50 and ice.maxy < 50 and ice.maxx - ice.minx == 2
	print("RESULT movable_solid float ok=%s" % ok)
