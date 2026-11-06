#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include "sim.h"

namespace godot {

class SandWorld : public RefCounted {
	GDCLASS(SandWorld, RefCounted)

	sim::World w;
	double accumulator = 0.0;
	bool materials_ok = false;
	PackedByteArray color_buf;

protected:
	static void _bind_methods();

public:
	bool load_materials(const Dictionary &data);
	bool load_reactions(const Dictionary &data);
	void setup(int width, int height);
	int get_width() const { return w.W; }
	int get_height() const { return w.H; }
	int get_material_count() const { return (int)w.mats.size(); }
	Dictionary get_material_info(int id) const;
	int find_material(const String &str_id) const;

	void step(double delta);
	void step_once();
	void set_heat_multiplier(double m);
	void set_gravity(const Vector2 &dir);
	void set_ambient_temp(double c);
	void clear();

	void paint_circle(const Vector2i &c, int r, int mat, int mode);
	void paint_line(const Vector2i &a, const Vector2i &b, int r, int mat, int mode);
	void erase_circle(const Vector2i &c, int r);
	void heat_circle(const Vector2i &c, int r, double watts, double delta);
	void spawn_neutrons(const Vector2i &c, int r, int count);

	PackedByteArray get_color_buffer(int view);
	Dictionary get_cell(const Vector2i &p) const;
	Dictionary get_stats() const;

	PackedByteArray save_bytes() const;
	bool load_bytes(const PackedByteArray &data);

	// extra (not in docs/api.md, handy for tests/UI)
	double get_thermal_time_scale() const { return w.thermal_time_scale; }
	void set_thermal_time_scale(double s) { w.thermal_time_scale = (float)s; }
	int count_material(int id) const;
	double get_mean_temp(int id) const;
};

} // namespace godot
