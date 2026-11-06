// Godot-facing class SandWorld: data parsing, API, save/load. Simulation lives in sim::World.
#include "sand_world.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <cstring>
#include <map>
#include <string>

using namespace godot;

namespace {

std::string to_std(const String &s) {
	CharString cs = s.utf8();
	return std::string(cs.get_data(), cs.length());
}

bool is_num(const Variant &v) { return v.get_type() == Variant::FLOAT || v.get_type() == Variant::INT; }

struct Parser {
	std::string err;
	std::map<std::string, int> ids;

	void fail(const std::string &msg) {
		if (err.empty()) err = msg;
	}
	double num(const Dictionary &d, const char *key, double def, const std::string &ctx, bool required = false) {
		if (!d.has(key) || d[key].get_type() == Variant::NIL) {
			if (required) fail(ctx + ": missing number '" + std::string(key) + "'");
			return def;
		}
		Variant v = d[key];
		if (!is_num(v)) {
			fail(ctx + ": '" + std::string(key) + "' must be a number");
			return def;
		}
		return (double)v;
	}
	String str(const Dictionary &d, const char *key, const String &def, const std::string &ctx, bool required = false) {
		if (!d.has(key) || d[key].get_type() == Variant::NIL) {
			if (required) fail(ctx + ": missing string '" + std::string(key) + "'");
			return def;
		}
		Variant v = d[key];
		if (v.get_type() != Variant::STRING && v.get_type() != Variant::STRING_NAME) {
			fail(ctx + ": '" + std::string(key) + "' must be a string");
			return def;
		}
		return String(v);
	}
	// reference to another material; returns def when absent/null, -1 + error when unknown
	int ref(const Dictionary &d, const char *key, int def, const std::string &ctx) {
		if (!d.has(key) || d[key].get_type() == Variant::NIL) return def;
		String s = str(d, key, "", ctx);
		auto it = ids.find(to_std(s));
		if (it == ids.end()) {
			fail(ctx + ": '" + std::string(key) + "' refers to unknown material '" + to_std(s) + "'");
			return def;
		}
		return it->second;
	}
	bool obj(const Dictionary &d, const char *key, Dictionary &out, const std::string &ctx) {
		if (!d.has(key) || d[key].get_type() == Variant::NIL) return false;
		if (d[key].get_type() != Variant::DICTIONARY) {
			fail(ctx + ": '" + std::string(key) + "' must be an object");
			return false;
		}
		out = d[key];
		return true;
	}
	void range(const Dictionary &d, const char *key, float &a, float &b, const std::string &ctx) {
		if (!d.has(key) || d[key].get_type() == Variant::NIL) return;
		Variant v = d[key];
		if (v.get_type() == Variant::ARRAY) {
			Array arr = v;
			if (arr.size() >= 1 && is_num(arr[0])) a = b = (float)(double)arr[0];
			if (arr.size() >= 2 && is_num(arr[1])) b = (float)(double)arr[1];
			if (b < a) std::swap(a, b);
		} else if (is_num(v)) {
			a = b = (float)(double)v;
		} else {
			fail(ctx + ": '" + std::string(key) + "' must be [min, max]");
		}
	}
	void transition(const Dictionary &d, const char *key, sim::Transition &t, const std::string &ctx) {
		Dictionary o;
		if (!obj(d, key, o, ctx)) return;
		std::string c = ctx + "." + key;
		t.has = true;
		t.temp = (float)num(o, "temp", 0, c, true);
		t.latent = (float)num(o, "latent", 0, c);
		t.into = ref(o, "into", -1, c);
		if (t.into < 0) {
			fail(c + ": missing 'into'");
			t.has = false;
		}
	}
};

} // namespace

// ============================================================================
// bindings
// ============================================================================

void SandWorld::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_materials", "data"), &SandWorld::load_materials);
	ClassDB::bind_method(D_METHOD("load_reactions", "data"), &SandWorld::load_reactions);
	ClassDB::bind_method(D_METHOD("setup", "width", "height"), &SandWorld::setup);
	ClassDB::bind_method(D_METHOD("get_width"), &SandWorld::get_width);
	ClassDB::bind_method(D_METHOD("get_height"), &SandWorld::get_height);
	ClassDB::bind_method(D_METHOD("get_material_count"), &SandWorld::get_material_count);
	ClassDB::bind_method(D_METHOD("get_material_info", "id"), &SandWorld::get_material_info);
	ClassDB::bind_method(D_METHOD("find_material", "str_id"), &SandWorld::find_material);

	ClassDB::bind_method(D_METHOD("step", "delta"), &SandWorld::step);
	ClassDB::bind_method(D_METHOD("step_once"), &SandWorld::step_once);
	ClassDB::bind_method(D_METHOD("set_heat_multiplier", "m"), &SandWorld::set_heat_multiplier);
	ClassDB::bind_method(D_METHOD("set_gravity", "dir"), &SandWorld::set_gravity);
	ClassDB::bind_method(D_METHOD("set_ambient_temp", "c"), &SandWorld::set_ambient_temp);
	ClassDB::bind_method(D_METHOD("clear"), &SandWorld::clear);

	ClassDB::bind_method(D_METHOD("paint_circle", "c", "r", "mat", "mode"), &SandWorld::paint_circle);
	ClassDB::bind_method(D_METHOD("paint_line", "a", "b", "r", "mat", "mode"), &SandWorld::paint_line);
	ClassDB::bind_method(D_METHOD("erase_circle", "c", "r"), &SandWorld::erase_circle);
	ClassDB::bind_method(D_METHOD("heat_circle", "c", "r", "watts", "delta"), &SandWorld::heat_circle);
	ClassDB::bind_method(D_METHOD("spawn_neutrons", "c", "r", "count"), &SandWorld::spawn_neutrons);

	ClassDB::bind_method(D_METHOD("get_color_buffer", "view"), &SandWorld::get_color_buffer);
	ClassDB::bind_method(D_METHOD("get_cell", "p"), &SandWorld::get_cell);
	ClassDB::bind_method(D_METHOD("get_stats"), &SandWorld::get_stats);

	ClassDB::bind_method(D_METHOD("get_air_grid_size"), &SandWorld::get_air_grid_size);
	ClassDB::bind_method(D_METHOD("get_air_velocity"), &SandWorld::get_air_velocity);
	ClassDB::bind_method(D_METHOD("get_air_cell_scale"), &SandWorld::get_air_cell_scale);
	ClassDB::bind_method(D_METHOD("add_air_impulse", "c", "r", "v"), &SandWorld::add_air_impulse);
	ClassDB::bind_method(D_METHOD("set_air_enabled", "on"), &SandWorld::set_air_enabled);
	ClassDB::bind_method(D_METHOD("get_air_layer", "view"), &SandWorld::get_air_layer);

	ClassDB::bind_method(D_METHOD("save_bytes"), &SandWorld::save_bytes);
	ClassDB::bind_method(D_METHOD("load_bytes", "data"), &SandWorld::load_bytes);

	ClassDB::bind_method(D_METHOD("get_thermal_time_scale"), &SandWorld::get_thermal_time_scale);
	ClassDB::bind_method(D_METHOD("set_thermal_time_scale", "s"), &SandWorld::set_thermal_time_scale);
	ClassDB::bind_method(D_METHOD("count_material", "id"), &SandWorld::count_material);
	ClassDB::bind_method(D_METHOD("get_mean_temp", "id"), &SandWorld::get_mean_temp);
}

// ============================================================================
// materials
// ============================================================================

bool SandWorld::load_materials(const Dictionary &data) {
	Parser P;
	if (!data.has("materials") || data["materials"].get_type() != Variant::ARRAY) {
		UtilityFunctions::push_error("SandWorld.load_materials: 'materials' array is missing");
		return false;
	}
	Array arr = data["materials"];
	if (arr.size() < 1 || arr.size() > 255) {
		UtilityFunctions::push_error("SandWorld.load_materials: need 1..255 materials, got ", arr.size());
		return false;
	}
	const float cell_size = (float)P.num(data, "cell_size_m", 0.01, "materials.json");
	const float ambient = (float)P.num(data, "ambient_temp", 20.0, "materials.json");
	const float tts = (float)P.num(data, "thermal_time_scale", 1.0, "materials.json");

	// pass 1: ids
	for (int k = 0; k < arr.size(); k++) {
		if (arr[k].get_type() != Variant::DICTIONARY) {
			P.fail("materials[" + std::to_string(k) + "] is not an object");
			continue;
		}
		Dictionary d = arr[k];
		String id = P.str(d, "id", "", "materials[" + std::to_string(k) + "]", true);
		std::string sid = to_std(id);
		if (P.ids.count(sid)) P.fail("duplicate material id '" + sid + "'");
		P.ids[sid] = k;
	}
	if (P.err.empty() && to_std(P.str((Dictionary)arr[0], "id", "", "materials[0]")) != "air")
		P.fail("materials[0] must be 'air'");

	std::vector<sim::Material> mats(arr.size());
	for (int k = 0; k < arr.size() && P.err.empty(); k++) {
		Dictionary d = arr[k];
		sim::Material &M = mats[k];
		M.id = to_std(P.str(d, "id", "", "material"));
		const std::string ctx = "material '" + M.id + "'";
		M.name = to_std(P.str(d, "name", String::utf8(M.id.c_str()), ctx, true));
		M.category = to_std(P.str(d, "category", "special", ctx, true));
		M.desc = to_std(P.str(d, "desc", "", ctx));
		String st = P.str(d, "state", "solid", ctx, true);
		M.state_name = to_std(st);
		if (st == "empty") M.state = sim::ST_EMPTY;
		else if (st == "solid") M.state = sim::ST_SOLID;
		else if (st == "powder") M.state = sim::ST_POWDER;
		else if (st == "liquid") M.state = sim::ST_LIQUID;
		else if (st == "gas") M.state = sim::ST_GAS;
		else if (st == "fire") M.state = sim::ST_FIRE;
		else P.fail(ctx + ": unknown state '" + to_std(st) + "'");
		if (k == 0) M.state = sim::ST_EMPTY;
		else if (M.state == sim::ST_EMPTY) P.fail(ctx + ": state 'empty' is reserved for air");

		M.density = (float)P.num(d, "density", 1000, ctx, true);
		M.conductivity = (float)P.num(d, "conductivity", 1, ctx, true);
		M.heat_capacity = (float)P.num(d, "heat_capacity", 1000, ctx, true);
		if (M.density <= 0 || M.heat_capacity <= 0 || M.conductivity < 0) P.fail(ctx + ": density/heat_capacity must be > 0");
		const bool gaslike = M.state == sim::ST_GAS || M.state == sim::ST_FIRE || M.state == sim::ST_EMPTY;
		M.expansion = (float)P.num(d, "thermal_expansion", gaslike ? 1.0 / 293.15 : 0.0, ctx);
		M.initial_temp = d.has("initial_temp") && is_num(d["initial_temp"]) ? (float)(double)d["initial_temp"] : NAN;

		// colours
		M.ncolors = 0;
		if (d.has("colors") && d["colors"].get_type() == Variant::ARRAY) {
			Array cs = d["colors"];
			for (int c = 0; c < cs.size() && M.ncolors < 4; c++) {
				String h = cs[c];
				if (!Color::html_is_valid(h)) {
					P.fail(ctx + ": bad colour '" + to_std(h) + "'");
					continue;
				}
				Color col = Color::html(h);
				M.colors[M.ncolors][0] = (uint8_t)std::lround(col.r * 255);
				M.colors[M.ncolors][1] = (uint8_t)std::lround(col.g * 255);
				M.colors[M.ncolors][2] = (uint8_t)std::lround(col.b * 255);
				M.ncolors++;
			}
		}
		if (M.ncolors == 0) {
			P.fail(ctx + ": 'colors' must have 1..4 colours");
			M.ncolors = 1;
		}
		M.glow = d.has("glow") && (bool)d["glow"];
		M.hidden = d.has("hidden") && (bool)d["hidden"];
		M.viscosity = std::min(1.0f, std::max(0.0f, (float)P.num(d, "viscosity", 0.0, ctx)));

		if (d.has("lifetime") && d["lifetime"].get_type() != Variant::NIL) {
			P.range(d, "lifetime", M.life_min, M.life_max, ctx);
			M.flags |= sim::MF_LIFE;
			M.decay_into = P.ref(d, "decay_into", 0, ctx);
		}
		P.transition(d, "melt", M.melt, ctx);
		P.transition(d, "freeze", M.freeze, ctx);
		P.transition(d, "boil", M.boil, ctx);
		P.transition(d, "condense", M.condense, ctx);
		if (M.melt.has || M.freeze.has || M.boil.has || M.condense.has) M.flags |= sim::MF_PHASE;

		Dictionary o;
		if (P.obj(d, "ignite", o, ctx)) {
			std::string c = ctx + ".ignite";
			M.flags |= sim::MF_IGNITE;
			M.ign_temp = (float)P.num(o, "temp", 300, c, true);
			int fire_def = P.ids.count("fire") ? P.ids["fire"] : 0;
			M.ign_into = P.ref(o, "into", fire_def, c);
			M.burn_min = M.burn_max = 1.0f;
			P.range(o, "burn_time", M.burn_min, M.burn_max, c);
			M.residue = P.ref(o, "residue", -1, c);
			M.residue_chance = (float)P.num(o, "residue_chance", 0, c);
			M.ign_heat = (float)P.num(o, "heat", 0, c);
		}
		if (P.obj(d, "explosive", o, ctx)) {
			std::string c = ctx + ".explosive";
			M.flags |= sim::MF_EXPLOSIVE;
			M.exp_temp = (float)P.num(o, "temp", 200, c, true);
			M.exp_radius = (int)P.num(o, "radius", 6, c);
			M.exp_energy = (float)P.num(o, "energy", 4.2e6, c);
			M.exp_into = P.ref(o, "into", 0, c);
		}
		if (P.obj(d, "acid", o, ctx)) {
			std::string c = ctx + ".acid";
			M.flags |= sim::MF_ACID;
			M.acid_strength = (float)P.num(o, "strength", 0.3, c);
			M.acid_into = P.ref(o, "into", 0, c);
			M.acid_consumed = (float)P.num(o, "consumed_chance", 0.2, c);
		}
		M.acid_resistance = std::min(1.0f, std::max(0.0f, (float)P.num(d, "acid_resistance", 0.0, ctx)));
		if (P.obj(d, "nuclear", o, ctx)) {
			std::string c = ctx + ".nuclear";
			sim::Nuclear &N = M.nuc;
			N.fissile = (float)P.num(o, "fissile", 0, c);
			N.fast_fission = (float)P.num(o, "fast_fission", 0, c);
			N.absorb = (float)P.num(o, "absorb", 0, c);
			N.moderate = (float)P.num(o, "moderate", 0, c);
			N.reflect = (float)P.num(o, "reflect", 0, c);
			N.spontaneous = (float)P.num(o, "spontaneous", 0, c);
			N.decay_heat = (float)P.num(o, "decay_heat", 0, c);
			N.fission_energy = (float)P.num(o, "fission_energy", 0, c);
			float a = 2, b = 3;
			P.range(o, "neutrons_per_fission", a, b, c);
			N.npf_min = std::max(0, (int)a);
			N.npf_max = std::max(N.npf_min, (int)b);
			N.burnup_into = P.ref(o, "burnup_into", -1, c);
			N.burnup_chance = (float)P.num(o, "burnup_chance", 0, c);
			N.poison_into = P.ref(o, "poison_into", -1, c);
			N.poison_chance = (float)P.num(o, "poison_chance", 0, c);
			if (N.fissile > 0 || N.fast_fission > 0 || N.absorb > 0 || N.moderate > 0 || N.reflect > 0) M.flags |= sim::MF_NUCLEAR;
			if (N.spontaneous > 0 || N.decay_heat > 0) M.flags |= sim::MF_NUC_SOURCE;
		}
		if (d.has("fixed_temp") && is_num(d["fixed_temp"])) {
			M.flags |= sim::MF_FIXED;
			M.fixed_temp = (float)(double)d["fixed_temp"];
			if (M.state != sim::ST_SOLID) P.fail(ctx + ": fixed_temp materials must be 'solid'");
		}
		if (M.category == "metal") M.flags |= sim::MF_METAL;

		// v0.1.1
		M.wind_coupling = std::min(1.0f, std::max(0.0f, (float)P.num(d, "wind_coupling", gaslike && k != 0 ? 1.0 : 0.0, ctx)));
		if (k == 0) M.wind_coupling = 0.0f;
		M.gas_alpha = std::min(1.0f, std::max(0.0f, (float)P.num(d, "gas_alpha", M.state == sim::ST_FIRE ? 0.85 : 0.5, ctx)));
		if (P.obj(d, "emit", o, ctx)) {
			std::string c = ctx + ".emit";
			M.emit_into = P.ref(o, "into", -1, c);
			if (M.emit_into < 0) P.fail(c + ": missing 'into'");
			M.emit_rate = (float)P.num(o, "rate", 20, c);
			M.emit_temp = o.has("temp") && is_num(o["temp"]) ? (float)(double)o["temp"] : NAN;
			if (M.emit_into > 0 && M.emit_rate > 0) M.flags |= sim::MF_EMIT;
		}
		if (P.obj(d, "drain", o, ctx)) {
			M.drain_rate = (float)P.num(o, "rate", 60, ctx + ".drain");
			if (M.drain_rate > 0) M.flags |= sim::MF_DRAIN;
		}
		if (P.obj(d, "fan", o, ctx)) {
			std::string c = ctx + ".fan";
			float fx = 0, fy = -1;
			if (o.has("dir") && o["dir"].get_type() == Variant::ARRAY) {
				Array a = o["dir"];
				if (a.size() >= 2 && is_num(a[0]) && is_num(a[1])) {
					fx = (float)(double)a[0];
					fy = (float)(double)a[1];
				} else P.fail(c + ": 'dir' must be [x, y]");
			}
			float l = std::sqrt(fx * fx + fy * fy);
			if (l < 1e-6f) P.fail(c + ": 'dir' must be non-zero");
			else {
				M.fan_dx = fx / l;
				M.fan_dy = fy / l;
			}
			M.fan_strength = (float)P.num(o, "strength", 40, c);
			M.flags |= sim::MF_FAN;
		}
	}
	if (!P.err.empty()) {
		UtilityFunctions::push_error(String::utf8(("SandWorld.load_materials: " + P.err).c_str()));
		return false;
	}

	// keep an existing grid: remap old ids to the new table by string id
	std::vector<int> remap;
	const bool had_grid = w.W > 0 && !w.mats.empty();
	if (had_grid) {
		remap.assign(256, 0);
		for (size_t k = 0; k < w.mats.size(); k++) {
			auto it = P.ids.find(w.mats[k].id);
			remap[k] = it == P.ids.end() ? 0 : it->second;
		}
	}
	w.mats = std::move(mats);
	w.cell_size = cell_size > 0 ? cell_size : 0.01f;
	w.ambient = ambient;
	w.thermal_time_scale = tts > 0 ? tts : 1.0f;
	w.reactions.clear();
	w.finalize_materials();
	w.build_reaction_table();
	if (had_grid) {
		for (auto &m : w.mat) m = (uint8_t)remap[m];
		w.recount();
		w.wake_all();
	}
	materials_ok = true;
	return true;
}

bool SandWorld::load_reactions(const Dictionary &data) {
	if (!materials_ok) {
		UtilityFunctions::push_error("SandWorld.load_reactions: call load_materials first");
		return false;
	}
	Parser P;
	for (size_t k = 0; k < w.mats.size(); k++) P.ids[w.mats[k].id] = (int)k;
	if (!data.has("reactions") || data["reactions"].get_type() != Variant::ARRAY) {
		UtilityFunctions::push_error("SandWorld.load_reactions: 'reactions' array is missing");
		return false;
	}
	Array arr = data["reactions"];
	std::vector<sim::Reaction> rs;
	for (int k = 0; k < arr.size(); k++) {
		const std::string ctx = "reactions[" + std::to_string(k) + "]";
		if (arr[k].get_type() != Variant::DICTIONARY) {
			P.fail(ctx + " is not an object");
			break;
		}
		Dictionary d = arr[k];
		sim::Reaction r;
		r.a = P.ref(d, "a", -1, ctx);
		r.b = P.ref(d, "b", -1, ctx);
		if (r.a < 0 || r.b < 0) P.fail(ctx + ": 'a' and 'b' are required");
		r.chance = (float)P.num(d, "chance", 0, ctx, true);
		if (d.has("min_temp") && is_num(d["min_temp"])) {
			r.has_min = true;
			r.min_t = (float)(double)d["min_temp"];
		}
		if (d.has("max_temp") && is_num(d["max_temp"])) {
			r.has_max = true;
			r.max_t = (float)(double)d["max_temp"];
		}
		r.into_a = P.ref(d, "into_a", -1, ctx);
		r.into_b = P.ref(d, "into_b", -1, ctx);
		r.heat = (float)P.num(d, "heat", 0, ctx);
		r.explode_radius = (int)P.num(d, "explode_radius", 0, ctx);
		if (!P.err.empty()) break;
		rs.push_back(r);
	}
	if (!P.err.empty()) {
		UtilityFunctions::push_error(String::utf8(("SandWorld.load_reactions: " + P.err).c_str()));
		return false;
	}
	if (rs.size() > 32000) rs.resize(32000);
	w.reactions = std::move(rs);
	w.build_reaction_table();
	return true;
}

void SandWorld::setup(int width, int height) {
	if (!materials_ok) {
		UtilityFunctions::push_error("SandWorld.setup: call load_materials first");
		return;
	}
	if (width < 1 || height < 1 || (int64_t)width * height > 16 * 1024 * 1024) {
		UtilityFunctions::push_error("SandWorld.setup: bad size");
		return;
	}
	w.setup(width, height);
	accumulator = 0.0;
}

Dictionary SandWorld::get_material_info(int id) const {
	Dictionary d;
	if (id < 0 || id >= (int)w.mats.size()) return d;
	const sim::Material &M = w.mats[id];
	d["id"] = id;
	d["str_id"] = String::utf8(M.id.c_str());
	d["name"] = String::utf8(M.name.c_str());
	d["category"] = String::utf8(M.category.c_str());
	d["state"] = String::utf8(M.state_name.c_str());
	d["desc"] = String::utf8(M.desc.c_str());
	d["color"] = Color(M.colors[0][0] / 255.0f, M.colors[0][1] / 255.0f, M.colors[0][2] / 255.0f);
	d["hidden"] = M.hidden;
	return d;
}

int SandWorld::find_material(const String &str_id) const {
	std::string s = to_std(str_id);
	for (size_t k = 0; k < w.mats.size(); k++)
		if (w.mats[k].id == s) return (int)k;
	return -1;
}

// ============================================================================
// simulation
// ============================================================================

void SandWorld::step(double delta) {
	if (w.W == 0) return;
	if (delta < 0) delta = 0;
	accumulator += delta;
	int n = 0;
	while (accumulator >= sim::FIXED_DT && n < 4) {
		w.step_once();
		accumulator -= sim::FIXED_DT;
		n++;
	}
	if (accumulator > sim::FIXED_DT) accumulator = sim::FIXED_DT; // drop backlog (no spiral of death)
}

void SandWorld::step_once() { w.step_once(); }
void SandWorld::set_heat_multiplier(double m) { w.heat_multiplier = (float)std::max(0.0, m); }
void SandWorld::set_gravity(const Vector2 &dir) { w.set_gravity(dir.x, dir.y); }
void SandWorld::set_ambient_temp(double c) {
	w.ambient = (float)c;
	if (w.W > 0) w.wake_all();
}
void SandWorld::clear() {
	if (w.W > 0) w.clear();
}

void SandWorld::paint_circle(const Vector2i &c, int r, int mat, int mode) { w.paint_circle(c.x, c.y, r, mat, mode); }
void SandWorld::paint_line(const Vector2i &a, const Vector2i &b, int r, int mat, int mode) { w.paint_line(a.x, a.y, b.x, b.y, r, mat, mode); }
void SandWorld::erase_circle(const Vector2i &c, int r) { w.erase_circle(c.x, c.y, r); }
void SandWorld::heat_circle(const Vector2i &c, int r, double watts, double delta) { w.heat_circle(c.x, c.y, r, (float)watts, (float)delta); }
void SandWorld::spawn_neutrons(const Vector2i &c, int r, int count) { w.spawn_neutrons(c.x, c.y, r, count); }

PackedFloat32Array SandWorld::get_air_velocity() const {
	PackedFloat32Array out;
	const int64_t n = (int64_t)w.AW * w.AH;
	out.resize(n * 2);
	if (n == 0) return out;
	float *p = out.ptrw();
	for (int64_t i = 0; i < n; i++) {
		p[2 * i] = w.au[i];
		p[2 * i + 1] = w.av[i];
	}
	return out;
}

void SandWorld::add_air_impulse(const Vector2i &c, int r, const Vector2 &v) { w.air_impulse(c.x, c.y, r, v.x, v.y); }

PackedByteArray SandWorld::get_air_layer(int view) {
	const int64_t n = (int64_t)w.AW * w.AH * 4;
	if (air_buf.size() != n) air_buf.resize(n);
	if (n == 0) return air_buf;
	w.render_air(view, air_buf.ptrw());
	return air_buf;
}

PackedByteArray SandWorld::get_color_buffer(int view) {
	const int64_t n = (int64_t)w.W * w.H * 4;
	if (color_buf.size() != n) color_buf.resize(n);
	if (n == 0) return color_buf;
	w.render(view, color_buf.ptrw());
	return color_buf;
}

Dictionary SandWorld::get_cell(const Vector2i &p) const {
	Dictionary d;
	if (!w.inb(p.x, p.y)) {
		d["mat"] = -1;
		d["temp"] = w.ambient;
		d["name"] = String();
		return d;
	}
	int i = p.y * w.W + p.x;
	const sim::Material &M = w.mats[w.mat[i]];
	d["mat"] = (int)w.mat[i];
	d["temp"] = w.temp[i];
	d["name"] = String::utf8(M.name.c_str());
	return d;
}

Dictionary SandWorld::get_stats() const {
	Dictionary d;
	d["step_ms"] = w.step_ms;
	d["active_chunks"] = w.active_chunks;
	d["neutrons"] = (int)w.neutrons.size();
	d["fissions_per_sec"] = w.fissions_per_sec;
	d["max_temp"] = w.max_temp;
	// extra: per-pass timings (ms, smoothed)
	Dictionary pm;
	static const char *names[6] = { "move", "air", "wind", "special", "neutrons", "heat" };
	for (int k = 0; k < 6; k++) pm[names[k]] = w.pass_ms[k];
	pm["heat_substeps"] = w.heat_substeps;
	pm["heat_chunks"] = w.heat_chunks;
	pm["stiff_mat"] = w.stiff_mat >= 0 ? String::utf8(w.mats[w.stiff_mat].id.c_str()) : String();
	d["pass_ms"] = pm;
	return d;
}

int SandWorld::count_material(int id) const {
	if (id < 0 || id > 255) return 0;
	return (int)w.mat_count[id];
}

double SandWorld::get_mean_temp(int id) const {
	double s = 0;
	int64_t n = 0;
	for (size_t i = 0; i < w.mat.size(); i++)
		if (w.mat[i] == id) {
			s += w.temp[i];
			n++;
		}
	return n ? s / n : 0.0;
}

// ============================================================================
// save / load
// ============================================================================

namespace {
const uint32_t SAVE_MAGIC = 0x57444E53; // "SNDW"
const uint32_t SAVE_VERSION = 2; // v2 (0.1.1): + air field; v1 still loads

struct Writer {
	std::vector<uint8_t> b;
	void u8(uint8_t v) { b.push_back(v); }
	void u16(uint16_t v) { raw(&v, 2); }
	void u32(uint32_t v) { raw(&v, 4); }
	void f32(float v) { raw(&v, 4); }
	void raw(const void *p, size_t n) {
		const uint8_t *c = (const uint8_t *)p;
		b.insert(b.end(), c, c + n);
	}
};
struct Reader {
	const uint8_t *p;
	size_t n, o = 0;
	bool ok = true;
	bool raw(void *dst, size_t k) {
		if (o + k > n) {
			ok = false;
			return false;
		}
		memcpy(dst, p + o, k);
		o += k;
		return true;
	}
	uint8_t u8() {
		uint8_t v = 0;
		raw(&v, 1);
		return v;
	}
	uint16_t u16() {
		uint16_t v = 0;
		raw(&v, 2);
		return v;
	}
	uint32_t u32() {
		uint32_t v = 0;
		raw(&v, 4);
		return v;
	}
	float f32() {
		float v = 0;
		raw(&v, 4);
		return v;
	}
};
} // namespace

// Layout (little-endian), version 2:
//   u32 magic "SNDW", u32 version, u32 W, u32 H, f32 ambient, u8 gravity dir,
//   u16 nmats, nmats * (u16 len, utf8 id),
//   W*H u8 mat, W*H u8 var, W*H u8 flags, W*H f32 temp, W*H f32 phase, W*H f32 life,
//   u32 neutrons, n * (f32 x, f32 y, f32 vx, f32 vy, f32 age, u8 fast),
//   [v2] u32 AW, u32 AH, AW*AH * (f32 vx, f32 vy)
PackedByteArray SandWorld::save_bytes() const {
	Writer wr;
	const size_t n = (size_t)w.W * w.H;
	wr.b.reserve(64 + n * 15 + w.neutrons.size() * 21);
	wr.u32(SAVE_MAGIC);
	wr.u32(SAVE_VERSION);
	wr.u32((uint32_t)w.W);
	wr.u32((uint32_t)w.H);
	wr.f32(w.ambient);
	wr.u8((uint8_t)w.grav_dir);
	wr.u16((uint16_t)w.mats.size());
	for (const auto &M : w.mats) {
		wr.u16((uint16_t)M.id.size());
		wr.raw(M.id.data(), M.id.size());
	}
	if (n) {
		wr.raw(w.mat.data(), n);
		wr.raw(w.var.data(), n);
		wr.raw(w.cflags.data(), n);
		wr.raw(w.temp.data(), n * 4);
		wr.raw(w.phase.data(), n * 4);
		wr.raw(w.life.data(), n * 4);
	}
	wr.u32((uint32_t)w.neutrons.size());
	for (const auto &nt : w.neutrons) {
		wr.f32(nt.x);
		wr.f32(nt.y);
		wr.f32(nt.vx);
		wr.f32(nt.vy);
		wr.f32(nt.age);
		wr.u8(nt.fast);
	}
	// v2: air field
	wr.u32((uint32_t)w.AW);
	wr.u32((uint32_t)w.AH);
	for (size_t i = 0; i < (size_t)w.AW * w.AH; i++) {
		wr.f32(w.au[i]);
		wr.f32(w.av[i]);
	}
	PackedByteArray out;
	out.resize((int64_t)wr.b.size());
	if (!wr.b.empty()) memcpy(out.ptrw(), wr.b.data(), wr.b.size());
	return out;
}

bool SandWorld::load_bytes(const PackedByteArray &data) {
	if (!materials_ok) {
		UtilityFunctions::push_error("SandWorld.load_bytes: call load_materials first");
		return false;
	}
	Reader rd{ data.ptr(), (size_t)data.size() };
	if (rd.n < 16 || rd.u32() != SAVE_MAGIC) {
		UtilityFunctions::push_error("SandWorld.load_bytes: not a SandWorld save");
		return false;
	}
	uint32_t ver = rd.u32();
	if (ver != 1 && ver != 2) {
		UtilityFunctions::push_error("SandWorld.load_bytes: unsupported version ", (int64_t)ver);
		return false;
	}
	uint32_t W = rd.u32(), H = rd.u32();
	float amb = rd.f32();
	uint8_t gd = rd.u8();
	if (W == 0 || H == 0 || (uint64_t)W * H > 16ull * 1024 * 1024) {
		UtilityFunctions::push_error("SandWorld.load_bytes: bad size");
		return false;
	}
	uint16_t nm = rd.u16();
	std::vector<uint8_t> remap(256, 0);
	for (int k = 0; k < nm && rd.ok; k++) {
		uint16_t len = rd.u16();
		std::string s(len, '\0');
		if (len) rd.raw(&s[0], len);
		int id = 0;
		for (size_t q = 0; q < w.mats.size(); q++)
			if (w.mats[q].id == s) {
				id = (int)q;
				break;
			}
		if (k < 256) remap[k] = (uint8_t)id;
	}
	const size_t n = (size_t)W * H;
	if (!rd.ok || rd.o + n * 15 + 4 > rd.n) {
		UtilityFunctions::push_error("SandWorld.load_bytes: truncated data");
		return false;
	}
	w.ambient = amb;
	w.setup((int)W, (int)H);
	w.grav_dir = gd & 7;
	rd.raw(w.mat.data(), n);
	rd.raw(w.var.data(), n);
	rd.raw(w.cflags.data(), n);
	rd.raw(w.temp.data(), n * 4);
	rd.raw(w.phase.data(), n * 4);
	rd.raw(w.life.data(), n * 4);
	for (auto &m : w.mat) m = remap[m];
	for (size_t i = 0; i < n; i++) {
		float &t = w.temp[i];
		if (!std::isfinite(t)) t = amb;
		if (!std::isfinite(w.phase[i])) w.phase[i] = 0;
		if (!std::isfinite(w.life[i])) w.life[i] = 0;
		const sim::Material &M = w.mats[w.mat[i]];
		if (M.flags & sim::MF_FIXED) t = M.fixed_temp;
	}
	uint32_t nn = rd.u32();
	for (uint32_t k = 0; k < nn && rd.ok && (int)w.neutrons.size() < sim::MAX_NEUTRONS; k++) {
		sim::Neutron nt;
		nt.x = rd.f32();
		nt.y = rd.f32();
		nt.vx = rd.f32();
		nt.vy = rd.f32();
		nt.age = rd.f32();
		nt.fast = rd.u8();
		if (rd.ok && w.inb((int)nt.x, (int)nt.y)) w.neutrons.push_back(nt);
	}
	if (ver >= 2 && rd.ok) {
		uint32_t aw = rd.u32(), ah = rd.u32();
		if (rd.ok && (int)aw == w.AW && (int)ah == w.AH && rd.o + (size_t)aw * ah * 8 <= rd.n) {
			for (size_t i = 0; i < (size_t)aw * ah; i++) {
				float u = rd.f32(), v = rd.f32();
				w.au[i] = std::isfinite(u) ? u : 0.0f;
				w.av[i] = std::isfinite(v) ? v : 0.0f;
			}
		}
	}
	// v1 saves: the air field stays zero (setup() cleared it)
	w.recount();
	w.wake_all();
	accumulator = 0.0;
	return true;
}
