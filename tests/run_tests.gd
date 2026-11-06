extends SceneTree
## Headless-тесты физики на реальных данных data/*.json.
##
##   godot --headless --path <проект> -s tests/run_tests.gd
##   godot --headless --path <проект> -s tests/run_tests.gd -- only=pot,nuke tts=17 data=/abs/dir
##
## Аргументы после «--»:
##   only=<группы через запятую>  pot, dens, phase, burn, react, nuke, save, perf, robust, heat
##   data=<папка>                 откуда брать materials.json и reactions.json (по умолчанию res://data)
##   tts=<число>                  переопределить thermal_time_scale
##   set=<id.поле.поле:значение,…> переопределить поля материалов в памяти (подбор параметров)
##   perf_frames=<n>              число шагов в замере производительности (600)
## Код выхода — число проваленных проверок (0 — всё прошло).

var w: Object
var M := {}            # str_id -> int
var args := {}
var results: Array[Dictionary] = []
var mat_data: Dictionary
var rx_data: Dictionary
var data_dir := "res://data"
var loader_used := "JSON.parse_string"

const DT := 1.0 / 60.0


# ---------------------------------------------------------------------------
# каркас
# ---------------------------------------------------------------------------

func _init() -> void:
	for a in OS.get_cmdline_user_args():
		var p := a.find("=")
		if p > 0:
			args[a.substr(0, p)] = a.substr(p + 1)
	if not ClassDB.class_exists("SandWorld"):
		push_error("SandWorld не найден: GDExtension не загружен (bin/physics.gdextension)")
		quit(100)
		return
	data_dir = str(args.get("data", "res://data")).trim_suffix("/")
	mat_data = read_json(data_dir + "/materials.json")
	rx_data = read_json(data_dir + "/reactions.json")
	if mat_data.is_empty():
		push_error("нет materials.json в " + data_dir)
		quit(101)
		return
	if args.has("tts"):
		mat_data["thermal_time_scale"] = float(args["tts"])
	if args.has("set"):
		apply_overrides(str(args["set"]))
	# дополнительная плита 1530 и 1600 °C для теста плавления стали (только в памяти)
	add_plate("qa_plate_1530", 1530.0)
	add_plate("qa_plate_1600", 1600.0)
	w = new_world()
	if w == null:
		quit(102)
		return
	print("data: %s (через %s), материалов %d, реакций %d, thermal_time_scale=%.2f, debug_build=%s" % [
		data_dir, loader_used, w.get_material_count(), (rx_data.get("reactions", []) as Array).size(),
		w.get_thermal_time_scale(), OS.is_debug_build()])
	var only := str(args.get("only", ""))
	var groups := only.split(",", false)
	var run := func(g: String) -> bool: return groups.is_empty() or g in groups
	if run.call("pot"): test_pot()
	if run.call("heat"): test_heat_conservation()
	if run.call("dens"): test_densities()
	if run.call("phase"): test_phases()
	if run.call("burn"): test_burning()
	if run.call("react"): test_reactions()
	if run.call("nuke"): test_nuclear()
	if run.call("save"): test_save()
	if run.call("robust"): test_robust()
	if run.call("perf"): test_perf()
	print_summary()
	var fails := 0
	for r in results:
		if not r.ok: fails += 1
	quit(min(fails, 99))


func read_json(path: String) -> Dictionary:
	# та же логика, что в игре: MaterialsLoader.read_json (если скрипт компилируется)
	if path.begins_with("res://") and ResourceLoader.exists("res://scripts/data/materials_loader.gd"):
		var scr: Variant = load("res://scripts/data/materials_loader.gd")
		if scr is GDScript and (scr as GDScript).can_instantiate():
			var d: Variant = scr.read_json(path)
			if d is Dictionary and not (d as Dictionary).is_empty():
				loader_used = "MaterialsLoader.read_json"
				return d
	if not FileAccess.file_exists(path):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}


func new_world() -> Object:
	var nw: Object = ClassDB.instantiate("SandWorld")
	if not nw.load_materials(mat_data):
		push_error("ядро отвергло materials.json")
		return null
	if not rx_data.is_empty() and not nw.load_reactions(rx_data):
		push_error("ядро отвергло reactions.json")
	M.clear()
	for i in nw.get_material_count():
		M[str(nw.get_material_info(i)["str_id"])] = i
	return nw


func add_plate(id: String, t: float) -> void:
	var src: Dictionary = {}
	for m: Dictionary in mat_data["materials"]:
		if m["id"] == "super_heater":
			src = m.duplicate(true)
	if src.is_empty():
		return
	src["id"] = id
	src["name"] = id
	src["hidden"] = true
	src["fixed_temp"] = t
	(mat_data["materials"] as Array).append(src)


func apply_overrides(spec: String) -> void:
	for item in spec.split(",", false):
		var kv := item.split(":")
		if kv.size() != 2:
			continue
		var path := kv[0].split(".")
		var val: Variant = float(kv[1]) if kv[1].is_valid_float() else kv[1]
		for m: Dictionary in mat_data["materials"]:
			if m["id"] != path[0]:
				continue
			var d: Dictionary = m
			for k in range(1, path.size() - 1):
				if not d.has(path[k]):
					d[path[k]] = {}
				d = d[path[k]]
			d[path[path.size() - 1]] = val
			print("override %s = %s" % [kv[0], str(val)])


func check(group: String, name: String, ok: bool, detail: String) -> void:
	results.append({"group": group, "name": name, "ok": ok, "detail": detail})
	print("  [%s] %s: %s" % ["PASS" if ok else "FAIL", name, detail])


func print_summary() -> void:
	print("\n================ ИТОГ ================")
	var fails := 0
	for r in results:
		print("%s | %-7s | %-48s | %s" % ["PASS" if r.ok else "FAIL", r.group, r.name, r.detail])
		if not r.ok: fails += 1
	print("всего %d, провалено %d" % [results.size(), fails])


# ---------------------------------------------------------------------------
# помощники
# ---------------------------------------------------------------------------

func id(s: String) -> int:
	if not M.has(s):
		push_error("нет материала " + s)
		return 0
	return M[s]


func rect(x0: int, y0: int, x1: int, y1: int, m: String) -> void:
	var mi := id(m)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			w.paint_circle(Vector2i(x, y), 0, mi, 1)


func steps(n: int) -> void:
	for i in n:
		w.step_once()


func cnt(m: String) -> int:
	return w.count_material(id(m))


func temp_at(x: int, y: int) -> float:
	return float(w.get_cell(Vector2i(x, y))["temp"])


## Сводка по области: {mat_id: {n, sy, st, tmax, tmin}}, плюс "_bad" — число нечисловых температур.
func scan(x0 := 0, y0 := 0, x1 := -1, y1 := -1) -> Dictionary:
	if x1 < 0: x1 = w.get_width() - 1
	if y1 < 0: y1 = w.get_height() - 1
	var out := {"_bad": 0, "_tmax": -1e30, "_tmin": 1e30}
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var c: Dictionary = w.get_cell(Vector2i(x, y))
			var m: int = c["mat"]
			var t: float = c["temp"]
			if is_nan(t) or is_inf(t):
				out["_bad"] += 1
				continue
			out["_tmax"] = max(out["_tmax"], t)
			out["_tmin"] = min(out["_tmin"], t)
			if not out.has(m):
				out[m] = {"n": 0, "sy": 0.0, "st": 0.0, "tmax": -1e30, "tmin": 1e30}
			var e: Dictionary = out[m]
			e.n += 1
			e.sy += y
			e.st += t
			e.tmax = max(e.tmax, t)
			e.tmin = min(e.tmin, t)
	return out


func mean_y(s: Dictionary, m: String) -> float:
	var e: Dictionary = s.get(id(m), {})
	return e.sy / e.n if not e.is_empty() and e.n > 0 else -1.0


func fmt_t(t: float) -> String:
	return "—" if t < 0 else "%.1f с" % t


# ---------------------------------------------------------------------------
# a. кастрюля
# ---------------------------------------------------------------------------

func build_pot() -> void:
	w.setup(320, 180)
	rect(148, 177, 171, 179, "heater")
	rect(148, 175, 171, 176, "steel")
	rect(148, 163, 149, 174, "steel")
	rect(170, 163, 171, 174, "steel")
	rect(150, 165, 169, 174, "water")


func steel_bottom_mean() -> float:
	var s := 0.0
	for y in range(175, 177):
		for x in range(150, 170):
			s += temp_at(x, y)
	return s / 40.0


func run_pot(mult: float) -> Dictionary:
	build_pot()
	w.set_heat_multiplier(mult)
	var r := {"steam": -1.0, "steel100": -1.0, "water50": -1.0, "water_at_steel": 0.0, "water_left": 0, "water0": cnt("water")}
	var limit := int(150.0 / mult * 60.0)
	var t_after := -1.0
	for i in limit:
		w.step_once()
		var t := (i + 1) * DT
		if r.steel100 < 0 and steel_bottom_mean() > 100.0:
			r.steel100 = t
			r.water_at_steel = w.get_mean_temp(id("water"))
		if r.water50 < 0 and w.get_mean_temp(id("water")) >= 50.0:
			r.water50 = t
		if r.steam < 0 and cnt("steam") > 0:
			r.steam = t
			t_after = t + 10.0 / mult
		if t_after > 0 and t >= t_after:
			r.water_left = cnt("water")
			break
	w.set_heat_multiplier(1.0)
	return r


func test_pot() -> void:
	print("\n== a. кастрюля (heater 400 °C, сталь, вода 20×10) ==")
	var r1 := run_pot(1.0)
	var r3 := run_pot(3.0)
	check("pot", "первый пар ×1 в 45–75 с", r1.steam >= 45.0 and r1.steam <= 75.0, fmt_t(r1.steam))
	check("pot", "первый пар ×3 в 15–25 с", r3.steam >= 15.0 and r3.steam <= 25.0, fmt_t(r3.steam))
	var ratio: float = r1.steam / r3.steam if r3.steam > 0 else 0.0
	check("pot", "×3 ускоряет кипение в 2.7–3.3 раза", ratio > 2.7 and ratio < 3.3, "%.2f×" % ratio)
	check("pot", "сталь дна >100 °C раньше, чем вода 50 °C (×1)", r1.steel100 > 0 and (r1.water50 < 0 or r1.steel100 < r1.water50),
		"сталь %s (вода тогда %.1f °C), вода 50 °C в %s" % [fmt_t(r1.steel100), r1.water_at_steel, fmt_t(r1.water50)])
	check("pot", "скрытая теплота: через 10 с после пара воды >90 %", r1.water_left > 0.9 * r1.water0,
		"%d → %d клеток" % [r1.water0, r1.water_left])


# ---------------------------------------------------------------------------
# теплопередача: сохранение энергии, изотропия, ×3
# ---------------------------------------------------------------------------

func cellC(m: String) -> float:
	for d: Dictionary in mat_data["materials"]:
		if d["id"] == m:
			var cs: float = mat_data.get("cell_size_m", 0.01)
			return float(d["density"]) * float(d["heat_capacity"]) * cs * cs * cs
	return 0.0


func test_heat_conservation() -> void:
	print("\n== теплопередача: энергия, изотропия, ×3 ==")
	# сетка целиком из камня и меди, без воздуха; граница — воздух при 20 °C (k 0.026, утечка мала)
	w.setup(64, 64)
	rect(0, 0, 31, 63, "stone")
	rect(32, 0, 63, 63, "copper")
	w.heat_circle(Vector2i(16, 32), 10, 200.0, 1.0) # +94 K в круге камня r=10
	var e0 := energy({"stone": cellC("stone"), "copper": cellC("copper")})
	steps(300)
	var e1 := energy({"stone": cellC("stone"), "copper": cellC("copper")})
	var rel: float = abs(e1 - e0) / max(1.0, e0)
	check("heat", "энергия сохраняется (камень+медь, 5 с)", rel < 0.02, "E %.0f → %.0f Дж (ΔE/E = %.2f %%, часть уходит в «бесконечный воздух» на краю)" % [e0, e1, rel * 100.0])
	# точечный источник в однородном камне: симметрия ±x, ±y
	w.setup(64, 64)
	rect(0, 0, 63, 63, "stone")
	w.heat_circle(Vector2i(32, 32), 0, 2.0e5, 1.0)
	steps(120)
	var d := 4
	var tr := temp_at(32 + d, 32) - 20.0
	var tl := temp_at(32 - d, 32) - 20.0
	var td := temp_at(32, 32 + d) - 20.0
	var tu := temp_at(32, 32 - d) - 20.0
	var mx: float = max(max(tr, tl), max(td, tu))
	var mn: float = min(min(tr, tl), min(td, tu))
	var aniso: float = (mx - mn) / max(1e-6, mx)
	check("heat", "изотропия: точечный нагрев, разброс ±x/±y <5 %", aniso < 0.05,
		"+x %.2f, −x %.2f, +y %.2f, −y %.2f K (разброс %.1f %%)" % [tr, tl, td, tu, aniso * 100.0])
	# ×3: время нагрева точки на расстоянии 4 клеток до +1 K
	var t1 := diffusion_time(1.0)
	var t3 := diffusion_time(3.0)
	check("heat", "×3 ускоряет теплопроводность ~3×", t3 > 0 and abs(t1 / t3 - 3.0) < 0.35, "%.2f с → %.2f с (%.2f×)" % [t1, t3, t1 / max(t3, 1e-6)])


func diffusion_time(mult: float) -> float:
	w.setup(32, 32)
	rect(0, 0, 31, 31, "stone")
	rect(8, 8, 8, 23, "heater")
	w.set_heat_multiplier(mult)
	for i in 6000:
		w.step_once()
		if temp_at(16, 16) > 50.0:
			w.set_heat_multiplier(1.0)
			return (i + 1) * DT
	w.set_heat_multiplier(1.0)
	return -1.0


func energy(caps: Dictionary) -> float:
	var s := scan()
	var e := 0.0
	for k in caps:
		var en: Dictionary = s.get(id(k), {})
		if not en.is_empty():
			e += (en.st - 20.0 * en.n) * caps[k]
	return e


# ---------------------------------------------------------------------------
# b. плотности
# ---------------------------------------------------------------------------

func beaker(x0: int, x1: int, ytop: int, yfloor: int, m := "glass") -> void:
	rect(x0, yfloor, x1, yfloor, m)
	rect(x0, ytop, x0, yfloor, m)
	rect(x1, ytop, x1, yfloor, m)


func test_densities() -> void:
	print("\n== b. плотности и расслоение ==")
	w.setup(128, 64)
	# стакан 1: снизу масло, вода, сверху ртуть — должны поменяться местами
	beaker(4, 31, 16, 60)
	rect(5, 53, 30, 59, "oil")
	rect(5, 46, 30, 52, "water")
	rect(5, 39, 30, 45, "mercury")
	# стакан 2: вода, сверху песок и пепел
	beaker(36, 63, 16, 60)
	rect(37, 40, 62, 59, "water")
	rect(40, 30, 48, 34, "sand")
	rect(52, 30, 60, 34, "ash")
	# стакан 3: ртуть, сверху песок
	beaker(68, 95, 16, 60)
	rect(69, 50, 94, 59, "mercury")
	rect(76, 40, 86, 44, "sand")
	steps(60 * 40)
	var s1 := scan(5, 16, 30, 59)
	var hg := mean_y(s1, "mercury")
	var wa := mean_y(s1, "water")
	var oi := mean_y(s1, "oil")
	check("dens", "стакан: снизу ртуть, вода, масло (40 с)", hg > wa and wa > oi,
		"средняя глубина y: ртуть %.1f, вода %.1f, масло %.1f (больше — ниже)" % [hg, wa, oi])
	var s2 := scan(37, 16, 62, 59)
	check("dens", "песок тонет в воде", mean_y(s2, "sand") > mean_y(s2, "water"),
		"y песка %.1f, воды %.1f" % [mean_y(s2, "sand"), mean_y(s2, "water")])
	check("dens", "пепел (600 кг/м³) плавает на воде", mean_y(s2, "ash") < mean_y(s2, "water"),
		"y пепла %.1f, воды %.1f" % [mean_y(s2, "ash"), mean_y(s2, "water")])
	var s3 := scan(69, 16, 94, 59)
	check("dens", "песок плавает на ртути", mean_y(s3, "sand") < mean_y(s3, "mercury"),
		"y песка %.1f, ртути %.1f" % [mean_y(s3, "sand"), mean_y(s3, "mercury")])
	# газы в закрытом ящике
	w.setup(64, 64)
	rect(2, 2, 61, 2, "wall")
	rect(2, 61, 61, 61, "wall")
	rect(2, 2, 2, 61, "wall")
	rect(61, 2, 61, 61, "wall")
	rect(6, 50, 15, 58, "helium")
	rect(48, 50, 57, 58, "hydrogen")
	rect(6, 5, 15, 13, "co2")
	rect(48, 5, 57, 13, "xenon135")
	steps(60 * 10)
	var sg := scan(3, 3, 60, 60)
	var mid := 31.5
	var he := mean_y(sg, "helium")
	var h2 := mean_y(sg, "hydrogen")
	var co := mean_y(sg, "co2")
	var xe := mean_y(sg, "xenon135")
	check("dens", "гелий и водород поднимаются (10 с)", he > 0 and h2 > 0 and he < mid - 8 and h2 < mid - 8,
		"y гелия %.1f, водорода %.1f (центр %.1f, старт 54)" % [he, h2, mid])
	check("dens", "CO2 и ксенон опускаются (10 с)", co > mid + 8 and xe > mid + 8,
		"y CO2 %.1f, ксенона %.1f (старт 9)" % [co, xe])


# ---------------------------------------------------------------------------
# c. фазы
# ---------------------------------------------------------------------------

func test_phases() -> void:
	print("\n== c. фазовые переходы ==")
	# лёд в неподвижном воздухе 20 °C: тепло приходит только из воздуха сетки
	w.setup(64, 64)
	rect(27, 30, 36, 39, "ice")
	var ice0 := cnt("ice")
	steps(60 * 120)
	check("phase", "лёд 10×10 в воздухе 20 °C тает (120 с)", cnt("ice") < ice0,
		"льда %d → %d, средняя T льда −10 → %.2f °C" % [ice0, cnt("ice"), w.get_mean_temp(id("ice"))])
	# лёд в воде: льда больше, чем вода может растопить → вода остывает до ≈0 °C и стоит, пока лёд есть
	w.setup(64, 48)
	beaker(21, 42, 26, 42, "glass")
	rect(22, 27, 41, 41, "water")
	rect(27, 29, 36, 38, "ice")
	var n_w := cnt("water")
	var n_g := cnt("glass")
	var ice_tmax := -1e9
	var wmean := 0.0
	var t2 := -1.0
	for i in 60 * 1500:
		w.step_once()
		if t2 < 0 and i % 60 == 0 and w.get_mean_temp(id("water")) <= 2.0:
			t2 = (i + 1) * DT
		if i % 600 == 0:
			var s := scan(22, 27, 41, 41)
			var e: Dictionary = s.get(id("ice"), {})
			if not e.is_empty():
				ice_tmax = max(ice_tmax, e.tmax)
	wmean = w.get_mean_temp(id("water"))
	var cs: float = mat_data.get("cell_size_m", 0.01)
	var m_ice: float = 917.0 * cs * cs * cs
	var per_cell := m_ice * 334000.0
	var avail := n_w * cellC("water") * 20.0 + n_g * cellC("glass") * 20.0 - 100 * cellC("ice") * 10.0
	var predicted := avail / per_cell
	var n_melt := 100 - cnt("ice")
	check("phase", "лёд в воде: вода остывает до 0…1.5 °C и держится", wmean > -0.5 and wmean < 1.5 and cnt("ice") > 0,
		"T воды ≤2 °C через %s, через 1500 с %.2f °C, льда осталось %d" % [fmt_t(t2), wmean, cnt("ice")])
	check("phase", "лёд в воде: вода ≤2 °C быстрее 300 с (стакан со льдом)", t2 > 0 and t2 < 300.0, fmt_t(t2))
	check("phase", "лёд не нагревается выше 0 °C (скрытая теплота)", ice_tmax <= 0.05, "макс. T льда %.2f °C" % ice_tmax)
	check("phase", "растаяло столько, сколько дала тепла вода (±30 %)", abs(n_melt - predicted) <= 0.3 * predicted,
		"растаяло %d клеток, по балансу энергии ≈%.0f (вода %d кл., стекло %d кл.)" % [n_melt, predicted, n_w, n_g])


	# вода на super_heater кипит
	w.setup(64, 48)
	rect(20, 44, 43, 46, "super_heater")
	beaker(19, 44, 30, 43, "glass")
	rect(20, 34, 43, 43, "water")
	var w0 := cnt("water")
	var tst := -1.0
	for i in 60 * 30:
		w.step_once()
		if tst < 0 and cnt("steam") > 0:
			tst = (i + 1) * DT
	check("phase", "вода на super_heater кипит", tst > 0 and cnt("water") < w0,
		"пар через %s, воды %d → %d за 30 с" % [fmt_t(tst), w0, cnt("water")])

	# ртуть на нагревателе 400 °C
	w.setup(64, 48)
	rect(20, 44, 43, 46, "heater")
	beaker(19, 44, 36, 43, "glass")
	rect(20, 40, 43, 43, "mercury")
	var tv := -1.0
	var vmax := 0
	var hg0 := cnt("mercury")
	for i in 60 * 60:
		w.step_once()
		var v := cnt("mercury_vapor")
		vmax = max(vmax, v)
		if tv < 0 and v > 0:
			tv = (i + 1) * DT
	check("phase", "ртуть на 400 °C испаряется (кипит при 357)", tv > 0,
		"первый пар через %s, максимум паров %d клеток, ртути %d → %d" % [fmt_t(tv), vmax, hg0, cnt("mercury")])
	# пары ртути в холодном воздухе конденсируются
	w.setup(64, 64)
	rect(27, 20, 36, 29, "mercury_vapor")
	var v0 := cnt("mercury_vapor")
	var tc := -1.0
	for i in 60 * 30:
		w.step_once()
		if tc < 0 and cnt("mercury_vapor") <= v0 / 5:
			tc = (i + 1) * DT
			break
	check("phase", "пары ртути (380 °C) конденсируются в воздухе 20 °C", tc > 0,
		"80 %% паров → ртуть за %s, ртути %d" % [fmt_t(tc), cnt("mercury")])

	# сталь на плитах 1500 / 1530 / 1600 °C
	for plate in [["super_heater", 1500.0, false], ["qa_plate_1530", 1530.0, false], ["qa_plate_1600", 1600.0, true]]:
		w.setup(48, 32)
		rect(14, 28, 33, 30, plate[0])
		rect(16, 24, 31, 27, "steel")
		var tm := -1.0
		for i in 60 * 90:
			w.step_once()
			if tm < 0 and cnt("molten_steel") > 0:
				tm = (i + 1) * DT
				break
		var melted := tm > 0
		check("phase", "сталь на плите %d °C %s" % [int(plate[1]), "плавится" if plate[2] else "НЕ плавится (Tпл железа 1538)"],
			melted == plate[2], ("расплав через %s" % fmt_t(tm)) if melted else "за 90 с не расплавилась, T стали %.1f" % temp_at(24, 26))


# ---------------------------------------------------------------------------
# d. горение и взрывчатка
# ---------------------------------------------------------------------------

func test_burning() -> void:
	print("\n== d. горение и взрывы ==")
	# дерево у огня (огонь «рисуется» 1 с, как кистью)
	w.setup(64, 48)
	rect(10, 44, 53, 44, "stone")
	rect(27, 34, 36, 43, "wood")
	var wood0 := cnt("wood")
	var t_ign := -1.0
	var fire_peak := 0
	for i in 60 * 120:
		if i < 60:
			rect(24, 40, 26, 43, "fire")
		w.step_once()
		fire_peak = max(fire_peak, cnt("fire"))
		if t_ign < 0 and cnt("wood") < wood0:
			t_ign = (i + 1) * DT
	check("burn", "дерево загорается от огня и сгорает", t_ign > 0 and cnt("wood") < wood0 / 2,
		"первая клетка сгорела через %s, дерева %d → %d за 120 с, огня макс %d" % [fmt_t(t_ign), wood0, cnt("wood"), fire_peak])
	check("burn", "после дерева остаётся пепел", cnt("ash") > 0, "пепла %d клеток" % cnt("ash"))
	# дерево на нагревателе 400 °C (выше 300 °C воспламенения)
	w.setup(64, 48)
	rect(20, 44, 43, 46, "heater")
	rect(27, 34, 36, 43, "wood")
	var t2 := -1.0
	for i in 60 * 120:
		w.step_once()
		if t2 < 0 and cnt("wood") < 100:
			t2 = (i + 1) * DT
	check("burn", "дерево на нагревателе 400 °C горит", t2 > 0, "первая клетка сгорела через %s, дерева осталось %d" % [fmt_t(t2), cnt("wood")])
	# порох и тротил от нагрева
	for ex in ["gunpowder", "tnt", "c4"]:
		w.setup(64, 48)
		rect(20, 44, 43, 46, "heater")
		rect(28, 38, 35, 43, ex)
		var n0 := cnt(ex)
		var tb := -1.0
		var maxT := 0.0
		for i in 60 * 30:
			w.step_once()
			maxT = max(maxT, float(w.get_stats()["max_temp"]))
			if tb < 0 and cnt(ex) < n0:
				tb = (i + 1) * DT
		check("burn", "%s взрывается от нагрева (heater 400)" % ex, tb > 0 and cnt(ex) < n0 / 4,
			"взрыв через %s, осталось %d/%d, дым %d, max T %.0f °C" % [fmt_t(tb), cnt(ex), n0, cnt("smoke"), maxT])


# ---------------------------------------------------------------------------
# e. реакции
# ---------------------------------------------------------------------------

func test_reactions() -> void:
	print("\n== e. реакции ==")
	w.setup(64, 48)
	beaker(14, 49, 20, 44, "glass")
	rect(15, 32, 48, 43, "water")
	rect(30, 36, 33, 39, "sodium")
	var h2max := 0
	var naoh := 0
	var maxT := 0.0
	var h2_tmax := 0.0
	var water_t0: float = w.get_mean_temp(id("water"))
	for i in 60 * 5:
		w.step_once()
		h2max = max(h2max, cnt("hydrogen"))
		naoh = max(naoh, cnt("sodium_hydroxide"))
		maxT = max(maxT, float(w.get_stats()["max_temp"]))
		if i % 10 == 0 and cnt("hydrogen") > 0:
			var s := scan(0, 0, 63, 47)
			var e: Dictionary = s.get(id("hydrogen"), {})
			if not e.is_empty():
				h2_tmax = max(h2_tmax, e.tmax)
	check("react", "натрий + вода → водород и NaOH", h2max > 0 and naoh > 0, "водород макс %d клеток, NaOH %d" % [h2max, naoh])
	check("react", "натрий + вода нагревает воду", w.get_mean_temp(id("water")) > water_t0 + 0.5 or maxT > 100.0,
		"вода %.1f → %.1f °C, max T %.0f °C" % [water_t0, w.get_mean_temp(id("water")), maxT])
	check("react", "реализм: водород после реакции < 3000 °C", h2_tmax < 3000.0,
		"макс. T водорода %.0f °C, max_temp мира %.0f °C" % [h2_tmax, maxT])
	# цирконий + пар > 1200 °C
	w.setup(64, 48)
	rect(20, 44, 43, 46, "super_heater")
	rect(19, 20, 19, 46, "wall")
	rect(44, 20, 44, 46, "wall")
	rect(19, 20, 44, 20, "wall")
	rect(27, 38, 36, 43, "zirconium")
	var h2 := 0
	var t_h2 := -1.0
	for i in 60 * 40:
		if i % 30 == 0:
			for y in range(21, 37):
				for x in range(20, 44):
					var c: int = w.get_cell(Vector2i(x, y))["mat"]
					if c == 0:
						w.paint_circle(Vector2i(x, y), 0, id("steam"), 0)
		w.step_once()
		h2 = max(h2, cnt("hydrogen"))
		if t_h2 < 0 and cnt("hydrogen") > 0:
			t_h2 = (i + 1) * DT
	check("react", "цирконий + пар при >1200 °C → водород", h2 > 0,
		"водород через %s, макс %d клеток, T циркония %.0f °C" % [fmt_t(t_h2), h2, w.get_mean_temp(id("zirconium"))])
	# тот же опыт при 400 °C — водорода быть не должно
	w.setup(64, 48)
	rect(20, 44, 43, 46, "heater")
	rect(27, 38, 36, 43, "zirconium")
	rect(20, 30, 43, 37, "steam")
	rect(20, 38, 26, 43, "steam")
	rect(37, 38, 43, 43, "steam")
	var h2c := 0
	for i in 60 * 10:
		w.step_once()
		h2c = max(h2c, cnt("hydrogen"))
	check("react", "цирконий + пар при 400 °C — без водорода", h2c == 0, "водород %d" % h2c)


# ---------------------------------------------------------------------------
# f. ядерка
# ---------------------------------------------------------------------------

## Решётка: вертикальные столбцы топлива шириной fw с периодом per, между ними other; пол из wall.
func lattice(cx: int, ybot: int, wd: int, ht: int, per: int, fw: int, fuel: String, other: String) -> void:
	var x0 := cx - wd / 2
	for y in range(ybot - ht, ybot):
		for x in range(x0, x0 + wd):
			var m := fuel if ((x - x0) % per) < fw else other
			if m != "":
				w.paint_circle(Vector2i(x, y), 0, id(m), 1)
	rect(x0 - 1, ybot, x0 + wd, ybot, "wall")
	rect(x0 - 1, ybot - ht - 4, x0 - 1, ybot, "wall")
	rect(x0 + wd, ybot - ht - 4, x0 + wd, ybot, "wall")


func fps() -> float:
	return float(w.get_stats()["fissions_per_sec"])


func test_nuclear() -> void:
	print("\n== f. ядерка ==")
	# f1: малый голый U-235
	w.setup(200, 120)
	rect(97, 57, 102, 62, "uranium235")
	w.spawn_neutrons(Vector2i(100, 60), 3, 100)
	steps(60)
	var a1 := fps()
	steps(240)
	var a5 := fps()
	check("nuke", "малый голый U-235 6×6 не разгоняется", a5 < 10.0, "делений/с: 1 с %.0f, 5 с %.0f" % [a1, a5])
	# f1b: голый U-235 30×30
	w.setup(200, 120)
	rect(85, 45, 114, 74, "uranium235")
	w.spawn_neutrons(Vector2i(100, 60), 4, 100)
	steps(300)
	print("  (справка) голый U-235 30×30: делений/с через 5 с %.0f, нейтронов %d" % [fps(), w.get_stats()["neutrons"]])

	# f2: U-235 + вода, ×1 и ×3
	var rw1 := run_water_reactor(1.0, false)
	var rw3 := run_water_reactor(3.0, false)
	check("nuke", "U-235 + вода разгоняется (делений/с растёт)", rw1.f5 > rw1.f1 * 3.0 and rw1.f5 > 200.0,
		"делений/с: 1 с %.0f, 3 с %.0f, 5 с %.0f, 10 с %.0f; нейтронов %d" % [rw1.f1, rw1.f3, rw1.f5, rw1.f10, rw1.nmax])
	check("nuke", "U-235 + вода: кипение за 10–40 с (×1)", rw1.boil >= 10.0 and rw1.boil <= 40.0,
		"пар через %s, T топлива тогда %.0f °C" % [fmt_t(rw1.boil), rw1.fuel_t])
	var rr: float = rw1.boil / rw3.boil if rw3.boil > 0 else 0.0
	check("nuke", "×3: реактор доводит воду до кипения быстрее в 2–3.5 раза", rr >= 2.0 and rr <= 3.5,
		"%s → %s (%.2f×)" % [fmt_t(rw1.boil), fmt_t(rw3.boil), rr])
	# f3: стержни B4C
	var rb := run_water_reactor(1.0, true)
	var drop: float = rb.before / max(rb.after, 0.1)
	check("nuke", "стержни B4C глушат реактор (падение >10×)", rb.before > 100.0 and drop > 10.0,
		"делений/с до %.0f, через 3 с после стержней %.0f (%.0f×)" % [rb.before, rb.after, drop])
	# f4: графит без воды и стержней → кориум
	var rg := run_graphite_reactor(3.0, 150.0)
	check("nuke", "U-235 + графит (×3) плавится в кориум", rg.corium > 0,
		"кориум через %s, max T %.0f °C, делений/с макс %.0f, графита %d → %d, огня макс %d" % [fmt_t(rg.t), rg.tmax, rg.fmax, rg.g0, rg.g1, rg.fire])
	# f5: отработанное топливо греется само
	var sf1 := spent_fuel_heat(1.0)
	var sf3 := spent_fuel_heat(3.0)
	check("nuke", "spent_fuel греется сам (decay_heat), ×1 за 5 с", sf1 > 20.0, "+%.1f K" % sf1)
	check("nuke", "decay_heat ×3 ≈ в 3 раза быстрее", abs(sf3 / max(sf1, 1e-3) - 3.0) < 0.5, "+%.1f K → +%.1f K (%.2f×)" % [sf1, sf3, sf3 / max(sf1, 1e-3)])


func run_water_reactor(mult: float, rods: bool) -> Dictionary:
	w.setup(200, 120)
	w.set_heat_multiplier(mult)
	lattice(100, 100, 36, 30, 6, 3, "uranium235", "water")
	w.spawn_neutrons(Vector2i(100, 85), 6, 100)
	var r := {"f1": 0.0, "f3": 0.0, "f5": 0.0, "f10": 0.0, "boil": -1.0, "fuel_t": 0.0, "nmax": 0, "before": 0.0, "after": 0.0}
	var limit := int((60.0 if not rods else 8.0) * 60.0)
	for i in limit:
		w.step_once()
		var t := (i + 1) * DT
		r.nmax = max(r.nmax, int(w.get_stats()["neutrons"]))
		if i + 1 == 60: r.f1 = fps()
		if i + 1 == 180: r.f3 = fps()
		if i + 1 == 300: r.f5 = fps()
		if i + 1 == 600: r.f10 = fps()
		if rods and i + 1 == 300:
			r.before = fps()
			# стержень в середину каждого водяного промежутка
			var x0 := 100 - 18
			for x in range(x0, x0 + 36):
				if ((x - x0) % 6) == 4:
					for y in range(70, 100):
						w.paint_circle(Vector2i(x, y), 0, id("boron_carbide"), 1)
		if rods and i + 1 == 480:
			r.after = fps()
		if not rods and r.boil < 0 and cnt("steam") > 0:
			r.boil = t
			r.fuel_t = w.get_mean_temp(id("uranium235"))
			if mult > 1.0 or i > 600:
				break
	w.set_heat_multiplier(1.0)
	return r


func run_graphite_reactor(mult: float, limit_s: float) -> Dictionary:
	w.setup(200, 120)
	w.set_heat_multiplier(mult)
	lattice(100, 100, 40, 40, 6, 3, "uranium235", "graphite")
	w.spawn_neutrons(Vector2i(100, 80), 6, 100)
	var r := {"t": -1.0, "tmax": 0.0, "fmax": 0.0, "corium": 0, "g0": cnt("graphite"), "g1": 0, "fire": 0}
	for i in int(limit_s * 60.0):
		w.step_once()
		r.fmax = max(r.fmax, fps())
		r.tmax = max(r.tmax, float(w.get_stats()["max_temp"]))
		r.fire = max(r.fire, cnt("fire"))
		if cnt("corium") > 0:
			r.t = (i + 1) * DT
			break
		if i % 600 == 0:
			print("    графит t=%3.0f с: делений/с %6.0f  T урана %.0f  max %.0f  графита %d" % [(i + 1) * DT, fps(), w.get_mean_temp(id("uranium235")), w.get_stats()["max_temp"], cnt("graphite")])
	r.corium = cnt("corium") + cnt("spent_fuel") * 0 # кориум мог застыть, отдельно не считаем
	r.g1 = cnt("graphite")
	w.set_heat_multiplier(1.0)
	return r


func spent_fuel_heat(mult: float) -> float:
	w.setup(48, 48)
	w.set_heat_multiplier(mult)
	rect(21, 21, 26, 26, "spent_fuel")
	var t0: float = w.get_mean_temp(id("spent_fuel"))
	steps(300)
	w.set_heat_multiplier(1.0)
	return w.get_mean_temp(id("spent_fuel")) - t0


# ---------------------------------------------------------------------------
# g. сохранение
# ---------------------------------------------------------------------------

func test_save() -> void:
	print("\n== g. сохранение ==")
	w.setup(96, 64)
	rect(10, 50, 40, 60, "water")
	rect(50, 40, 60, 60, "sand")
	rect(62, 56, 90, 60, "heater")
	rect(64, 50, 88, 55, "water")
	rect(5, 5, 14, 14, "uranium235")
	rect(70, 10, 75, 15, "ice")
	w.heat_circle(Vector2i(25, 55), 4, 3000.0, 1.0)
	w.spawn_neutrons(Vector2i(10, 10), 3, 50)
	steps(240)
	var before := snapshot()
	var nn: int = w.get_stats()["neutrons"]
	var b: PackedByteArray = w.save_bytes()
	w.clear()
	var cleared_ok := cnt("water") == 0
	var ok: bool = w.load_bytes(b)
	var after := snapshot()
	var diff := compare(before, after)
	check("save", "save → clear → load восстанавливает сетку и T", ok and cleared_ok and diff.mat == 0 and diff.temp == 0,
		"%d байт, load=%s, отличий: материал %d, температура %d, нейтронов %d → %d" % [b.size(), ok, diff.mat, diff.temp, nn, w.get_stats()["neutrons"]])
	# загрузка в новый мир другого размера
	var w2: Object = new_world()
	w2.setup(10, 10)
	var ok2: bool = w2.load_bytes(b)
	var wsave := w
	w = w2
	var after2 := snapshot()
	w = wsave
	var diff2 := compare(before, after2)
	check("save", "загрузка в новый SandWorld (другой размер)", ok2 and w2.get_width() == 96 and diff2.mat == 0 and diff2.temp == 0,
		"load=%s, размер %d×%d, отличий %d/%d" % [ok2, w2.get_width(), w2.get_height(), diff2.mat, diff2.temp])
	# мусор не должен ронять ядро
	var junk := PackedByteArray()
	junk.resize(100)
	var bad: bool = w2.load_bytes(junk)
	var trunc := b.slice(0, b.size() / 2)
	var bad2: bool = w2.load_bytes(trunc)
	check("save", "битые данные отвергаются", not bad and not bad2, "мусор=%s, обрезанный=%s" % [bad, bad2])
	# сохранение переживает добавление материала в начало таблицы
	var md2: Dictionary = mat_data.duplicate(true)
	var extra: Dictionary = (md2["materials"][1] as Dictionary).duplicate(true)
	extra["id"] = "qa_inserted"
	(md2["materials"] as Array).insert(1, extra)
	var w3: Object = ClassDB.instantiate("SandWorld")
	w3.load_materials(md2)
	var ok3: bool = w3.load_bytes(b)
	var wid_old: int = id("water")
	var wid_new: int = w3.find_material("water")
	check("save", "сохранение переживает перестановку materials.json", ok3 and w3.count_material(wid_new) == before.counts.get(wid_old, -1),
		"вода: id %d → %d, клеток %d → %d" % [wid_old, wid_new, before.counts.get(wid_old, -1), w3.count_material(wid_new)])


func snapshot() -> Dictionary:
	var mats := PackedInt32Array()
	var temps := PackedFloat32Array()
	var counts := {}
	for y in w.get_height():
		for x in w.get_width():
			var c: Dictionary = w.get_cell(Vector2i(x, y))
			mats.append(c["mat"])
			temps.append(c["temp"])
			counts[c["mat"]] = counts.get(c["mat"], 0) + 1
	return {"mats": mats, "temps": temps, "counts": counts}


func compare(a: Dictionary, b: Dictionary) -> Dictionary:
	var dm := 0
	var dt := 0
	if a.mats.size() != b.mats.size():
		return {"mat": a.mats.size(), "temp": a.mats.size()}
	for i in a.mats.size():
		if a.mats[i] != b.mats[i]: dm += 1
		if abs(a.temps[i] - b.temps[i]) > 1e-4: dt += 1
	return {"mat": dm, "temp": dt}


# ---------------------------------------------------------------------------
# крайние случаи (для ревью ядра)
# ---------------------------------------------------------------------------

func test_robust() -> void:
	print("\n== крайние случаи ==")
	# криоплита вплотную к лаве и ртути с паром
	w.setup(64, 48)
	rect(10, 30, 53, 31, "cryo")
	rect(10, 20, 53, 29, "lava")
	rect(10, 32, 53, 40, "lava")
	rect(10, 5, 30, 10, "liquid_nitrogen")
	rect(31, 5, 53, 10, "steam")
	w.set_heat_multiplier(3.0)
	steps(600)
	w.set_heat_multiplier(1.0)
	var s := scan()
	check("robust", "cryo рядом с лавой ×3: нет NaN/inf, T в пределах", s._bad == 0 and s._tmin >= -273.16 and s._tmax <= 20000.0,
		"нечисловых %d, T от %.1f до %.1f °C" % [s._bad, s._tmin, s._tmax])
	# экстремальный инструмент нагрева/охлаждения
	w.setup(32, 32)
	rect(8, 8, 23, 23, "water")
	w.heat_circle(Vector2i(12, 12), 3, -1.0e12, 1.0)
	w.heat_circle(Vector2i(20, 20), 3, 1.0e12, 1.0)
	steps(120)
	s = scan()
	check("robust", "heat_circle ±1e12 Вт: T зажата, без NaN", s._bad == 0 and s._tmin >= -273.16 and s._tmax <= 20000.0,
		"нечисловых %d, T от %.1f до %.1f" % [s._bad, s._tmin, s._tmax])
	# взрыв у края и в углу
	w.setup(64, 48)
	rect(0, 0, 3, 3, "c4")
	rect(60, 44, 63, 47, "c4")
	rect(0, 44, 5, 47, "tnt")
	rect(0, 20, 4, 25, "nitroglycerin")
	w.heat_circle(Vector2i(1, 1), 3, 1.0e6, 1.0)
	w.heat_circle(Vector2i(62, 46), 3, 1.0e6, 1.0)
	w.heat_circle(Vector2i(2, 46), 3, 1.0e6, 1.0)
	w.heat_circle(Vector2i(2, 22), 3, 1.0e6, 1.0)
	steps(120)
	s = scan()
	check("robust", "взрывы в углах и у края: без падения и NaN", s._bad == 0 and cnt("c4") == 0,
		"c4 осталось %d, tnt %d, нечисловых %d, max T %.0f" % [cnt("c4"), cnt("tnt"), s._bad, s._tmax])
	# 25000 нейтронов
	w.setup(320, 180)
	lattice(160, 170, 60, 60, 6, 3, "uranium235", "water")
	w.spawn_neutrons(Vector2i(160, 130), 30, 25000)
	var n0: int = w.get_stats()["neutrons"]
	var t0 := Time.get_ticks_usec()
	var nmax := 0
	for i in 120:
		w.step_once()
		nmax = max(nmax, int(w.get_stats()["neutrons"]))
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 120.0
	check("robust", "лимит 20000 нейтронов соблюдается", n0 <= 20000 and nmax <= 20000,
		"после spawn 25000: %d, максимум %d, %.2f мс/шаг (%s)" % [n0, nmax, ms, "debug" if OS.is_debug_build() else "release"])
	# пустые и вырожденные вызовы
	w.setup(1, 1)
	w.paint_circle(Vector2i(0, 0), 5, id("water"), 1)
	w.paint_circle(Vector2i(-100, -100), 3, id("sand"), 1)
	w.paint_circle(Vector2i(0, 0), 1, 999, 1)
	w.paint_line(Vector2i(-50, -50), Vector2i(50, 50), 2, id("sand"), 1)
	w.erase_circle(Vector2i(0, 0), -3)
	w.spawn_neutrons(Vector2i(0, 0), 0, 10)
	steps(10)
	var buf: PackedByteArray = w.get_color_buffer(1)
	check("robust", "сетка 1×1 и вызовы за границами", buf.size() == 4, "буфер %d байт" % buf.size())


# ---------------------------------------------------------------------------
# h. производительность
# ---------------------------------------------------------------------------

func test_perf() -> void:
	print("\n== h. производительность (%s) ==" % ("debug-библиотека" if OS.is_debug_build() else "release"))
	for size in [Vector2i(320, 180), Vector2i(390, 180)]:
		perf_scene(size.x, size.y)


func perf_scene(W: int, H: int) -> void:
	w.setup(W, H)
	w.set_heat_multiplier(3.0)
	var mix := ["sand", "water", "oil", "stone", "mercury", "gravel", "salt_water", "steel"]
	var y_top := H - H * 42 / 100
	for x in W:
		var m: String = mix[(x / 24) % mix.size()]
		for y in range(y_top, H):
			w.paint_circle(Vector2i(x, y), 0, id(m), 1)
	rect(W / 2 - 40, H - 4, W / 2 + 40, H - 1, "heater")
	rect(20, y_top - 6, 60, y_top - 1, "wood")
	rect(22, y_top - 7, 24, y_top - 7, "fire")
	# реактор в воздухе на полке
	lattice(W / 2, y_top - 4, 36, 30, 6, 3, "uranium235", "water")
	w.paint_circle(Vector2i(W / 4, 40), 10, id("sand"), 1)
	w.paint_circle(Vector2i(3 * W / 4, 40), 10, id("water"), 1)
	w.spawn_neutrons(Vector2i(W / 2, y_top - 20), 6, 200)
	var filled := 0
	for i in w.get_material_count():
		if i != 0: filled += w.count_material(i)
	steps(120)
	var frames := int(args.get("perf_frames", "600"))
	var times := PackedFloat64Array()
	var nmax := 0
	var fmax := 0.0
	for i in frames:
		if i % 20 == 0:
			w.paint_circle(Vector2i(W / 4 + (i % 7) * 3, 30), 3, id("sand"), 0)
			w.paint_circle(Vector2i(3 * W / 4 - (i % 5) * 3, 30), 3, id("water"), 0)
		var a := Time.get_ticks_usec()
		w.step_once()
		times.append((Time.get_ticks_usec() - a) / 1000.0)
		nmax = max(nmax, int(w.get_stats()["neutrons"]))
		fmax = max(fmax, fps())
	var sorted := times.duplicate()
	sorted.sort()
	var avg := 0.0
	for t in times: avg += t
	avg /= times.size()
	var p95: float = sorted[int(sorted.size() * 0.95)]
	var t1 := Time.get_ticks_usec()
	for i in 30:
		w.get_color_buffer(0)
	var cb := (Time.get_ticks_usec() - t1) / 1000.0 / 30.0
	var budget := 4.0
	check("perf", "%d×%d, %d %% заполнения + реактор: step ≤ %.0f мс" % [W, H, 100 * filled / (W * H), budget],
		avg <= budget or OS.is_debug_build(),
		"среднее %.2f мс, p95 %.2f мс, макс %.2f мс; цвет-буфер %.2f мс; нейтронов до %d, делений/с до %.0f%s" % [
			avg, p95, sorted[sorted.size() - 1], cb, nmax, fmax, " (debug: порог не применяется)" if OS.is_debug_build() else ""])
	w.set_heat_multiplier(1.0)
