// Core of the sandbox: plain C++ (no Godot types), driven by SandWorld.
#pragma once

#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace sim {

enum State : uint8_t {
	ST_EMPTY = 0, // air only
	ST_SOLID,
	ST_POWDER,
	ST_LIQUID,
	ST_GAS,
	ST_FIRE,
};

// Material flags (precomputed from fields) for fast per-cell dispatch.
enum : uint32_t {
	MF_LIFE = 1u << 0, // has lifetime
	MF_IGNITE = 1u << 1,
	MF_EXPLOSIVE = 1u << 2,
	MF_ACID = 1u << 3,
	MF_NUC_SOURCE = 1u << 4, // spontaneous neutrons or decay heat
	MF_REACT = 1u << 5, // takes part in some reaction from reactions.json
	MF_PHASE = 1u << 6, // has melt/freeze/boil/condense
	MF_FIXED = 1u << 7,
	MF_NUCLEAR = 1u << 8, // interacts with neutrons
	MF_METAL = 1u << 9, // category "metal": survives explosions
};
constexpr uint32_t MF_SPECIAL = MF_IGNITE | MF_EXPLOSIVE | MF_ACID | MF_NUC_SOURCE | MF_REACT;

// Cell flags.
enum : uint8_t {
	CF_BURNING = 1u << 0,
};

struct Transition {
	bool has = false;
	float temp = 0.0f;
	int into = 0;
	float latent = 0.0f; // J/kg
};

struct Nuclear {
	float fissile = 0, fast_fission = 0, absorb = 0, moderate = 0, reflect = 0;
	float spontaneous = 0, decay_heat = 0, fission_energy = 0;
	int npf_min = 2, npf_max = 3;
	int burnup_into = -1;
	float burnup_chance = 0;
	int poison_into = -1;
	float poison_chance = 0;
};

struct Material {
	std::string id, name, category, desc, state_name;
	State state = ST_SOLID;
	float density = 1000, conductivity = 1, heat_capacity = 1000, expansion = 0;
	float initial_temp = 20;
	uint8_t colors[4][3] = {};
	int ncolors = 1;
	bool glow = false, hidden = false;
	float viscosity = 0;
	float life_min = 0, life_max = 0;
	int decay_into = 0;
	Transition melt, freeze, boil, condense;
	// ignite
	float ign_temp = 0, burn_min = 1, burn_max = 1, residue_chance = 0, ign_heat = 0;
	int ign_into = 0, residue = -1;
	// explosive
	float exp_temp = 0, exp_energy = 0;
	int exp_radius = 0, exp_into = 0;
	// acid
	float acid_strength = 0, acid_consumed = 0;
	int acid_into = 0;
	float acid_resistance = 0;
	Nuclear nuc;
	float fixed_temp = 0;

	// derived
	uint32_t flags = 0;
	float cell_C = 1; // J/K of one cell
	float inv_C = 1; // 0 for fixed_temp (infinite capacity)
	float inv_c = 1; // 1 / heat_capacity
	float mass = 1; // kg per cell
};

struct Reaction {
	int a = 0, b = 0;
	float chance = 0;
	bool has_min = false, has_max = false;
	float min_t = 0, max_t = 0;
	int into_a = -1, into_b = -1; // -1 = unchanged
	float heat = 0;
	int explode_radius = 0;
};

struct Neutron {
	float x, y, vx, vy;
	float age;
	uint8_t fast;
};

struct Chunk {
	// movement dirty rect for the current step (inclusive, global coords); x0 > x1 means empty
	int x0, y0, x1, y1;
	// rect being collected for the next step
	int nx0, ny0, nx1, ny1;
	bool therm_awake;
	bool therm_active; // computed per step (dilated)
	bool hard; // got a real (non-levelling) wake during this step
	int calm; // consecutive steps with only soft wakes
	float tmax; // last known max temperature in the chunk
};

constexpr int CHUNK = 64;
constexpr int CHUNK_SHIFT = 6;
constexpr int MAX_NEUTRONS = 20000;
constexpr int CALM_LIMIT = 240; // steps of pure surface levelling before a chunk may sleep
constexpr float FIXED_DT = 1.0f / 60.0f;
constexpr float MIN_TEMP = -273.15f;
constexpr float MAX_TEMP = 20000.0f;

class World {
public:
	// ---------------- configuration ----------------
	std::vector<Material> mats;
	std::vector<Reaction> reactions;
	std::vector<int16_t> rx_table; // [a*256+b] = +(rule+1) (a is rule.a) or -(rule+1) (swapped)
	float cell_size = 0.01f;
	float ambient = 20.0f;
	float thermal_time_scale = 1.0f;
	float heat_multiplier = 1.0f;
	int grav_dir = 2; // index in ring (0,1)

	// ---------------- grid (structure of arrays) ----------------
	int W = 0, H = 0, CW = 0, CH = 0;
	std::vector<uint8_t> mat, var, cflags, clock;
	std::vector<float> temp, phase, life, flux;
	std::vector<Chunk> chunks;
	std::vector<Neutron> neutrons;
	uint32_t mat_count[256] = {};

	// ---------------- stats ----------------
	double step_ms = 0.0;
	int active_chunks = 0;
	float fissions_per_sec = 0.0f;
	float max_temp = 20.0f;
	uint64_t step_counter = 0;

	// ---------------- API ----------------
	void finalize_materials(); // derive tables after loading
	void build_reaction_table();
	void setup(int w, int h);
	void clear();
	void step_once();
	void set_gravity(float x, float y);

	void paint_circle(int cx, int cy, int r, int m, int mode);
	void paint_line(int ax, int ay, int bx, int by, int r, int m, int mode);
	void erase_circle(int cx, int cy, int r);
	void heat_circle(int cx, int cy, int r, float watts, float delta);
	void spawn_neutrons(int cx, int cy, int r, int count);

	void render(int view, uint8_t *out); // W*H*4 RGBA8

	// helpers usable from the glue
	void set_cell(int i, int m, float t);
	void wake(int x, int y);
	void wake_soft(int x, int y);
	void wake_impl(int x, int y, bool hard);
	void wake_all();
	inline bool inb(int x, int y) const { return (unsigned)x < (unsigned)W && (unsigned)y < (unsigned)H; }

	// save/load of raw state (glue writes the header/material table)
	void recount();

private:
	// rng (xorshift64*)
	uint64_t rng_state = 0x9E3779B97F4A7C15ull;
	inline uint32_t rnd() {
		uint64_t x = rng_state;
		x ^= x >> 12;
		x ^= x << 25;
		x ^= x >> 27;
		rng_state = x;
		return (uint32_t)((x * 0x2545F4914F6CDD1Dull) >> 32);
	}
	inline float frand() { return (rnd() >> 8) * (1.0f / 16777216.0f); }

	uint8_t stamp = 1;
	bool in_npass = false;
	int fission_ring[60] = {};
	int fission_sum = 0;
	int fissions_this_step = 0;

	// heat tables (only rows/cols of present materials are valid)
	std::vector<float> F_raw; // harmonic k * dx  (W/K), 256*256
	std::vector<float> F_eff; // per-substep conductance*dt (J/K), clamped
	std::vector<float> inv_C; // per material
	std::vector<uint8_t> present;
	std::vector<int> active_list;
	std::vector<int> scratch_offsets; // for explosions
	std::vector<Neutron> new_neutrons;

	// passes
	void move_pass();
	void update_cell(int x, int y);
	void special_pass();
	void neutron_pass();
	void heat_pass();
	void post_heat_chunk(int c, float &tmax_global);

	// movement helpers
	inline float dens(int i) const {
		const Material &M = mats[mat[i]];
		float d = 1.0f + M.expansion * (temp[i] - 20.0f);
		if (d < 0.05f) d = 0.05f;
		return M.density / d;
	}
	void swap_cells(int i, int j);
	bool try_move(int i, int x, int y, int nx, int ny, int mode);
	void update_powder(int i, int x, int y);
	void update_liquid(int i, int x, int y);
	void update_gas(int i, int x, int y);
	void update_air(int i, int x, int y);

	// specials
	void explode(int cx, int cy, int radius, float energy_j, int into);
	void ignite_cell(int i);
	void add_heat(int i, float joules);
	void handle_phase(int i);
	void fission_at(int i, int x, int y, const Material &M);
	void emit_neutron(float x, float y, bool fast);

	friend class SaveIO;
};

} // namespace sim
