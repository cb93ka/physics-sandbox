// Grid, painting, movement, specials (burning, explosions, acid, reactions), heat.
#include "sim.h"

#include <algorithm>
#include <chrono>
#include <climits>
#include <cstring>

namespace sim {

// 8 directions, clockwise starting from +x (y grows downwards).
static const int RX[8] = { 1, 1, 0, -1, -1, -1, 0, 1 };
static const int RY[8] = { 0, 1, 1, 1, 0, -1, -1, -1 };

// Convection gains: swap probability per step = relative density difference * gain.
static const float CONV_LIQ = 150.0f;
static const float CONV_GAS = 8.0f;
static const float CONV_AIR = 25.0f;
static const float MELT_INTERFACE_BOOST = 2.0f;

static inline int ring(int d) { return d & 7; }

static inline bool gas_like(State s) { return s == ST_EMPTY || s == ST_GAS || s == ST_FIRE; }

// ============================================================================
// materials / tables
// ============================================================================

void World::finalize_materials() {
	const float vol = cell_size * cell_size * cell_size;
	for (auto &M : mats) {
		M.mass = M.density * vol;
		M.cell_C = M.density * M.heat_capacity * vol;
		if (M.cell_C <= 0) M.cell_C = 1e-9f;
		M.inv_c = M.heat_capacity > 0 ? 1.0f / M.heat_capacity : 0.0f;
		M.inv_C = (M.flags & MF_FIXED) ? 0.0f : 1.0f / M.cell_C;
	}
	const int n = (int)mats.size();
	F_raw.assign(256 * 256, 0.0f);
	F_eff.assign(256 * 256, 0.0f);
	F_sub.assign(256 * 256, 0.0f);
	inv_C.assign(256, 0.0f);
	present.assign(256, 0);
	for (int a = 0; a < n; a++) {
		inv_C[a] = mats[a].inv_C;
		for (int b = 0; b < n; b++) {
			float ka = mats[a].conductivity, kb = mats[b].conductivity;
			float h = (ka + kb) > 0 ? 2.0f * ka * kb / (ka + kb) : 0.0f;
			// flux = k * area * dT / dx = k * dx * dT   (area dx^2, distance dx)
			F_raw[a * 256 + b] = h * cell_size;
			// A solid next to its own melt (ice-water, wax-molten wax): the meltwater boundary layer
			// convects, which one cell of still liquid cannot represent; boost that interface.
			const Material &A = mats[a], &B = mats[b];
			const bool own_melt = (A.melt.has && A.melt.into == b && B.state == ST_LIQUID) || (B.melt.has && B.melt.into == a && A.state == ST_LIQUID);
			if (own_melt) F_raw[a * 256 + b] *= MELT_INTERFACE_BOOST;
		}
	}
	rx_table.assign(256 * 256, 0);
	tables_ready = false;
	new_neutrons.reserve(4096);
	scratch_offsets.reserve(4096);
}

void World::build_reaction_table() {
	rx_table.assign(256 * 256, 0);
	for (auto &M : mats) M.flags &= ~MF_REACT;
	for (size_t k = 0; k < reactions.size(); k++) {
		const Reaction &r = reactions[k];
		rx_table[r.a * 256 + r.b] = (int16_t)(k + 1);
		if (r.a != r.b) rx_table[r.b * 256 + r.a] = (int16_t)(-(int)(k + 1));
		mats[r.a].flags |= MF_REACT;
		mats[r.b].flags |= MF_REACT;
	}
}

// ============================================================================
// grid
// ============================================================================

void World::setup(int w, int h) {
	if (w < 1) w = 1;
	if (h < 1) h = 1;
	W = w;
	H = h;
	CW = (W + CHUNK - 1) >> CHUNK_SHIFT;
	CH = (H + CHUNK - 1) >> CHUNK_SHIFT;
	const size_t n = (size_t)W * H;
	mat.assign(n, 0);
	var.resize(n);
	for (size_t i = 0; i < n; i++) var[i] = (uint8_t)rnd();
	cflags.assign(n, 0);
	clock.assign(n, 0);
	temp.assign(n, ambient);
	phase.assign(n, 0.0f);
	life.assign(n, 0.0f);
	flux.assign(n, 0.0f);
	chunks.assign((size_t)CW * CH, Chunk{});
	for (auto &c : chunks) {
		c.x0 = c.y0 = c.nx0 = c.ny0 = INT_MAX;
		c.x1 = c.y1 = c.nx1 = c.ny1 = -1;
		c.therm_awake = false;
		c.therm_active = false;
		c.hard = false;
		c.calm = 0;
		c.tmax = ambient;
	}
	neutrons.clear();
	neutrons.reserve(MAX_NEUTRONS);
	active_list.reserve(chunks.size());
	stiff_list.reserve((size_t)W * H);
	stiff_q.reserve((size_t)W * H);
	T0buf.assign((size_t)W * H, ambient);
	recount();
	air_setup();
	memset(fission_ring, 0, sizeof(fission_ring));
	fission_sum = 0;
	fissions_per_sec = 0;
	max_temp = ambient;
}

void World::clear() { setup(W, H); }

void World::recount() {
	memset(mat_count, 0, sizeof(mat_count));
	for (uint8_t m : mat) mat_count[m]++;
}

void World::set_gravity(float x, float y) {
	if (x * x + y * y < 1e-8f) return;
	float a = std::atan2(y, x); // y down
	int idx = (int)std::lround(a / (3.14159265f / 4.0f));
	grav_dir = ring(idx);
	wake_all();
}

void World::wake_all() {
	for (int cy = 0; cy < CH; cy++)
		for (int cx = 0; cx < CW; cx++) {
			Chunk &c = chunks[cy * CW + cx];
			c.nx0 = cx * CHUNK;
			c.ny0 = cy * CHUNK;
			c.nx1 = std::min(W - 1, cx * CHUNK + CHUNK - 1);
			c.ny1 = std::min(H - 1, cy * CHUNK + CHUNK - 1);
			c.therm_awake = true;
		}
}

void World::wake(int x, int y) { wake_impl(x, y, true); }
void World::wake_soft(int x, int y) { wake_impl(x, y, false); }

void World::wake_impl(int x, int y, bool hard) {
	int x0 = std::max(x - 1, 0), x1 = std::min(x + 1, W - 1);
	int y0 = std::max(y - 1, 0), y1 = std::min(y + 1, H - 1);
	int cx0 = x0 >> CHUNK_SHIFT, cx1 = x1 >> CHUNK_SHIFT;
	int cy0 = y0 >> CHUNK_SHIFT, cy1 = y1 >> CHUNK_SHIFT;
	for (int cy = cy0; cy <= cy1; cy++) {
		for (int cx = cx0; cx <= cx1; cx++) {
			Chunk &c = chunks[cy * CW + cx];
			if (hard) c.hard = true;
			else if (c.calm > CALM_LIMIT) continue;
			int bx0 = cx << CHUNK_SHIFT, by0 = cy << CHUNK_SHIFT;
			int ax0 = std::max(x0, bx0), ax1 = std::min(x1, bx0 + CHUNK - 1);
			int ay0 = std::max(y0, by0), ay1 = std::min(y1, by0 + CHUNK - 1);
			if (ax0 < c.nx0) c.nx0 = ax0;
			if (ax1 > c.nx1) c.nx1 = ax1;
			if (ay0 < c.ny0) c.ny0 = ay0;
			if (ay1 > c.ny1) c.ny1 = ay1;
			if (hard) c.therm_awake = true;
		}
	}
}

void World::set_cell(int i, int m, float t) {
	mat_count[mat[i]]--;
	mat_count[m]++;
	const Material &M = mats[m];
	mat[i] = (uint8_t)m;
	if (M.flags & MF_FIXED) t = M.fixed_temp;
	temp[i] = std::min(std::max(t, MIN_TEMP), MAX_TEMP);
	phase[i] = 0.0f;
	life[i] = (M.flags & MF_LIFE) ? M.life_min + (M.life_max - M.life_min) * frand() : 0.0f;
	var[i] = (uint8_t)rnd();
	cflags[i] = 0;
}

void World::swap_cells(int i, int j) {
	std::swap(mat[i], mat[j]);
	std::swap(temp[i], temp[j]);
	std::swap(phase[i], phase[j]);
	std::swap(life[i], life[j]);
	std::swap(var[i], var[j]);
	std::swap(cflags[i], cflags[j]);
	clock[i] = clock[j] = stamp;
}

// ============================================================================
// painting
// ============================================================================

void World::paint_circle(int cx, int cy, int r, int m, int mode) {
	if (m < 0 || m >= (int)mats.size() || W == 0) return;
	if (r < 0) r = 0;
	if (r > 4096) r = 4096; // r*r must not overflow
	const Material &M = mats[m];
	float t0 = std::isnan(M.initial_temp) ? ambient : M.initial_temp;
	int rr = r * r + r;
	for (int dy = -r; dy <= r; dy++) {
		int y = cy + dy;
		if (y < 0 || y >= H) continue;
		for (int dx = -r; dx <= r; dx++) {
			if (dx * dx + dy * dy > rr) continue;
			int x = cx + dx;
			if (x < 0 || x >= W) continue;
			int i = y * W + x;
			if (mode == 0 && mat[i] != 0) continue;
			if (mat[i] == m && mode == 0) continue;
			set_cell(i, m, t0);
			wake(x, y);
		}
	}
}

void World::paint_line(int ax, int ay, int bx, int by, int r, int m, int mode) {
	int dx = std::abs(bx - ax), dy = std::abs(by - ay);
	int n = std::max(dx, dy);
	int stride = std::max(1, r / 2);
	if (n == 0) {
		paint_circle(ax, ay, r, m, mode);
		return;
	}
	for (int k = 0; k <= n; k += stride) {
		int x = ax + (int)std::lround((double)(bx - ax) * k / n);
		int y = ay + (int)std::lround((double)(by - ay) * k / n);
		paint_circle(x, y, r, m, mode);
	}
	paint_circle(bx, by, r, m, mode);
}

void World::erase_circle(int cx, int cy, int r) {
	if (W == 0) return;
	if (r < 0) r = 0;
	if (r > 4096) r = 4096; // r*r must not overflow
	int rr = r * r + r;
	for (int dy = -r; dy <= r; dy++) {
		int y = cy + dy;
		if (y < 0 || y >= H) continue;
		for (int dx = -r; dx <= r; dx++) {
			if (dx * dx + dy * dy > rr) continue;
			int x = cx + dx;
			if (x < 0 || x >= W) continue;
			int i = y * W + x;
			set_cell(i, 0, ambient);
			wake(x, y);
		}
	}
}

void World::heat_circle(int cx, int cy, int r, float watts, float delta) {
	if (W == 0) return;
	if (r < 0) r = 0;
	if (r > 4096) r = 4096; // r*r must not overflow
	int rr = r * r + r;
	float e = watts * delta * heat_multiplier;
	for (int dy = -r; dy <= r; dy++) {
		int y = cy + dy;
		if (y < 0 || y >= H) continue;
		for (int dx = -r; dx <= r; dx++) {
			if (dx * dx + dy * dy > rr) continue;
			int x = cx + dx;
			if (x < 0 || x >= W) continue;
			int i = y * W + x;
			float ic = inv_C[mat[i]];
			if (ic == 0.0f) continue;
			temp[i] = std::min(std::max(temp[i] + e * ic, MIN_TEMP), MAX_TEMP);
			wake(x, y);
		}
	}
}

void World::spawn_neutrons(int cx, int cy, int r, int count) {
	if (W == 0) return;
	if (r < 0) r = 0;
	if (r > 4096) r = 4096; // r*r must not overflow
	for (int k = 0; k < count && (int)neutrons.size() < MAX_NEUTRONS; k++) {
		float a = frand() * 6.2831853f, d = std::sqrt(frand()) * (float)r;
		float x = cx + 0.5f + std::cos(a) * d, y = cy + 0.5f + std::sin(a) * d;
		if (x < 0 || y < 0 || x >= W || y >= H) continue;
		float b = frand() * 6.2831853f;
		neutrons.push_back(Neutron{ x, y, std::cos(b), std::sin(b), 0.0f, 1 });
	}
}

// ============================================================================
// step
// ============================================================================

void World::step_once() {
	if (W == 0 || mats.empty()) return;
	auto t0 = std::chrono::steady_clock::now();
	// odd stamps for the movement pass, stamp+1 (even, never 0) for the wind pass
	stamp = (uint8_t)(stamp + 2);
	if (stamp == 255 || stamp == 0) stamp = 1;
	wind_stamp = (uint8_t)(stamp + 1);
	step_counter++;
	fissions_this_step = 0;

	active_chunks = 0;
	for (auto &c : chunks) {
		// steps with only soft activity (surface levelling) count towards sleep
		if (c.hard) c.calm = 0;
		else if (c.nx0 <= c.nx1 && c.calm <= CALM_LIMIT) c.calm++;
		c.hard = false;
		c.x0 = c.nx0;
		c.y0 = c.ny0;
		c.x1 = c.nx1;
		c.y1 = c.ny1;
		c.nx0 = c.ny0 = INT_MAX;
		c.nx1 = c.ny1 = -1;
		if (c.x0 <= c.x1) active_chunks++;
	}

	auto tick = [](std::chrono::steady_clock::time_point &t) {
		auto n = std::chrono::steady_clock::now();
		double ms = std::chrono::duration<double, std::milli>(n - t).count();
		t = n;
		return ms;
	};
	auto tp = t0;
	double pm[6];
	move_pass();
	pm[0] = tick(tp);
	air_step();
	pm[1] = tick(tp);
	wind_pass();
	pm[2] = tick(tp);
	special_pass();
	pm[3] = tick(tp);
	neutron_pass();
	pm[4] = tick(tp);
	heat_pass();
	pm[5] = tick(tp);
	for (int k = 0; k < 6; k++) pass_ms[k] = step_counter <= 1 ? pm[k] : pass_ms[k] * 0.9 + pm[k] * 0.1;

	// neutron flux map (view 2) decays
	{
		float *f = flux.data();
		const size_t n = flux.size();
		for (size_t i = 0; i < n; i++) f[i] *= 0.85f;
	}

	int slot = (int)(step_counter % 60);
	fission_sum += fissions_this_step - fission_ring[slot];
	fission_ring[slot] = fissions_this_step;
	fissions_per_sec = (float)fission_sum * (60.0f / (float)std::min<uint64_t>(step_counter, 60));

	auto t1 = std::chrono::steady_clock::now();
	double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
	step_ms = step_counter <= 1 ? ms : step_ms * 0.9 + ms * 0.1;
}

// ============================================================================
// movement
// ============================================================================

void World::move_pass() {
	const int gx = RX[grav_dir], gy = RY[grav_dir];
	const bool flip = (step_counter & 1) != 0;
	if (gy != 0) {
		const int ys = gy > 0 ? H - 1 : 0, ye = gy > 0 ? -1 : H, yi = gy > 0 ? -1 : 1;
		const bool rev = gx > 0 ? true : (gx < 0 ? false : flip);
		for (int y = ys; y != ye; y += yi) {
			const int cy = y >> CHUNK_SHIFT;
			for (int k = 0; k < CW; k++) {
				const int cx = rev ? CW - 1 - k : k;
				const Chunk &ch = chunks[cy * CW + cx];
				if (ch.x0 > ch.x1 || y < ch.y0 || y > ch.y1) continue;
				const int a = ch.x0, b = ch.x1;
				if (rev)
					for (int x = b; x >= a; --x) update_cell(x, y);
				else
					for (int x = a; x <= b; ++x) update_cell(x, y);
			}
		}
	} else {
		const int xs = gx > 0 ? W - 1 : 0, xe = gx > 0 ? -1 : W, xi = gx > 0 ? -1 : 1;
		const bool rev = flip;
		for (int x = xs; x != xe; x += xi) {
			const int cx = x >> CHUNK_SHIFT;
			for (int k = 0; k < CH; k++) {
				const int cy = rev ? CH - 1 - k : k;
				const Chunk &ch = chunks[cy * CW + cx];
				if (ch.x0 > ch.x1 || x < ch.x0 || x > ch.x1) continue;
				const int a = ch.y0, b = ch.y1;
				if (rev)
					for (int y = b; y >= a; --y) update_cell(x, y);
				else
					for (int y = a; y <= b; ++y) update_cell(x, y);
			}
		}
	}
}

void World::update_cell(int x, int y) {
	const int i = y * W + x;
	if (clock[i] == stamp) return;
	const int m = mat[i];
	const Material &M = mats[m];
	if (M.state == ST_SOLID) {
		if (M.flags & MF_MOVSOLID) update_movsolid(i, x, y);
		return;
	}
	if (M.flags & MF_LIFE) {
		life[i] -= FIXED_DT;
		if (life[i] <= 0.0f) {
			set_cell(i, M.decay_into, temp[i]);
			clock[i] = stamp;
			wake(x, y);
			return;
		}
		wake(x, y);
	}
	switch (M.state) {
		case ST_POWDER: update_powder(i, x, y); break;
		case ST_LIQUID: update_liquid(i, x, y); break;
		case ST_GAS:
		case ST_FIRE: update_gas(i, x, y); break;
		case ST_EMPTY: update_air(i, x, y); break;
		default: break;
	}
}

// Probability that the falling cell i may swap into j (0 = not allowed).
static inline float enter_prob_impl(const Material &A, const Material &B, int mi, int mj, float da, float db) {
	switch (B.state) {
		case ST_EMPTY:
		case ST_GAS:
		case ST_FIRE: return 1.0f;
		case ST_LIQUID: {
			if (da <= db) return 0.0f;
			if (mi == mj) {
				float rel = (da - db) / db;
				if (rel < 2e-5f) return 0.0f;
				return std::min(1.0f, rel * CONV_LIQ);
			}
			return A.state == ST_POWDER ? 0.35f : 0.5f;
		}
		case ST_POWDER: return (A.state == ST_LIQUID && da > db) ? 0.35f : 0.0f;
		default: return 0.0f;
	}
}

bool World::try_move(int i, int x, int y, int nx, int ny, int /*mode*/) {
	if (!inb(nx, ny)) return false;
	const int j = ny * W + nx;
	const int mi = mat[i], mj = mat[j];
	const Material &A = mats[mi], &B = mats[mj];
	if (B.state == ST_SOLID) return false;
	if (B.state == ST_POWDER && A.state == ST_POWDER) return false;
	// same liquid: only a colder (denser) cell can sink into a warmer one; cheap reject first
	if (mi == mj && temp[i] > temp[j] - 0.05f) return false;
	float p = enter_prob_impl(A, B, mi, mj, dens(i), dens(j));
	if (p <= 0.0f) return false;
	if (p < 1.0f && frand() >= p) {
		wake(x, y); // could move later: stay awake
		return true; // "handled": do not try further directions this step
	}
	swap_cells(i, j);
	wake(x, y);
	wake(nx, ny);
	return true;
}

void World::update_powder(int i, int x, int y) {
	const int d = grav_dir;
	if (try_move(i, x, y, x + RX[d], y + RY[d], 0)) return;
	const int first = (rnd() & 1) ? 1 : -1;
	for (int s = 0; s < 2; s++) {
		const int dd = ring(d + (s == 0 ? first : -first));
		if (try_move(i, x, y, x + RX[dd], y + RY[dd], 0)) return;
	}
}

void World::update_liquid(int i, int x, int y) {
	const int d = grav_dir;
	const int mi = mat[i];
	const Material &M = mats[mi];
	if (try_move(i, x, y, x + RX[d], y + RY[d], 0)) return;
	const int first = (rnd() & 1) ? 1 : -1;
	for (int s = 0; s < 2; s++) {
		const int dd = ring(d + (s == 0 ? first : -first));
		if (try_move(i, x, y, x + RX[dd], y + RY[dd], 0)) return;
	}
	// lateral spreading
	const float visc = M.viscosity;
	if (visc > 0.0f && frand() < visc) {
		// may still flow later
		const int sa = ring(d + 2), sb = ring(d - 2);
		int ax = x + RX[sa], ay = y + RY[sa], bx = x + RX[sb], by = y + RY[sb];
		if ((inb(ax, ay) && gas_like(mats[mat[ay * W + ax]].state)) || (inb(bx, by) && gas_like(mats[mat[by * W + bx]].state)))
			wake_soft(x, y);
		return;
	}
	const int maxd = 1 + (int)((1.0f - visc) * 4.0f);
	const float di = dens(i);
	int flat = -1, fxp = 0, fyp = 0; // farthest reachable gas cell on the same level
	for (int s = 0; s < 2; s++) {
		const int sd = ring(d + (s == 0 ? 2 * first : -2 * first));
		const int sx = RX[sd], sy = RY[sd];
		int best = -1, bxp = 0, byp = 0;
		for (int k = 1; k <= maxd; k++) {
			const int tx = x + sx * k, ty = y + sy * k;
			if (!inb(tx, ty)) break;
			const int j = ty * W + tx;
			const int mj = mat[j];
			const State st = mats[mj].state;
			if (gas_like(st)) {
				const int fx = tx + RX[d], fy = ty + RY[d];
				if (inb(fx, fy) && gas_like(mats[mat[fy * W + fx]].state)) {
					// a spot where the liquid can drop: real flow
					best = j;
					bxp = tx;
					byp = ty;
					break;
				}
				if (s == 0 || flat < 0) {
					flat = j;
					fxp = tx;
					fyp = ty;
				}
				continue;
			}
			if (st == ST_LIQUID && mj != mi && k == 1 && di > dens(j) && frand() < 0.5f) {
				best = j;
				bxp = tx;
				byp = ty;
			}
			break;
		}
		if (best >= 0) {
			swap_cells(i, best);
			wake(x, y);
			wake(bxp, byp);
			return;
		}
	}
	// same-level wandering levels the surface; it uses "soft" wakes, so a chunk where only
	// this happens falls asleep after a while instead of jittering forever
	if (flat >= 0) {
		swap_cells(i, flat);
		wake_soft(x, y);
		wake_soft(fxp, fyp);
	}
}

// movable_solid: a rigid cell that falls straight down (no diagonal slides, no spreading),
// sinks in lighter liquids and floats up in denser ones (ice and wood in water).
void World::update_movsolid(int i, int x, int y) {
	const int d = grav_dir;
	const int nx = x + RX[d], ny = y + RY[d];
	if (inb(nx, ny)) {
		const int j = ny * W + nx;
		const State st = mats[mat[j]].state;
		if (gas_like(st)) {
			swap_cells(i, j);
			wake(x, y);
			wake(nx, ny);
			return;
		}
		if (st == ST_LIQUID && dens(i) > dens(j)) {
			wake(x, y);
			if (frand() < 0.5f) {
				swap_cells(i, j);
				wake(nx, ny);
			}
			return;
		}
	}
	const int u = ring(d + 4);
	const int ux = x + RX[u], uy = y + RY[u];
	if (inb(ux, uy)) {
		const int j = uy * W + ux;
		if (mats[mat[j]].state == ST_LIQUID && dens(j) > dens(i)) {
			wake(x, y);
			if (frand() < 0.5f) {
				swap_cells(i, j);
				wake(ux, uy);
			}
		}
	}
}

void World::update_gas(int i, int x, int y) {
	const int d = grav_dir;
	const int u = ring(d + 4);
	const int mi = mat[i];
	const bool fire = mats[mi].state == ST_FIRE;
	const float di = dens(i);
	wake(x, y); // gases are restless
	// heavier than the gas below -> sink
	{
		const int nx = x + RX[d], ny = y + RY[d];
		if (inb(nx, ny)) {
			const int j = ny * W + nx;
			if (gas_like(mats[mat[j]].state)) {
				const float dj = dens(j);
				if (di > dj * 1.002f) {
					float p = std::min(1.0f, (di - dj) / dj * CONV_GAS);
					if (frand() < p) {
						swap_cells(i, j);
						wake(nx, ny);
						return;
					}
				}
			}
		}
	}
	// lighter than what is above -> rise (also bubbles through liquids)
	{
		const int nx = x + RX[u], ny = y + RY[u];
		if (inb(nx, ny)) {
			const int j = ny * W + nx;
			const State st = mats[mat[j]].state;
			if (gas_like(st)) {
				const float dj = dens(j);
				if (dj > di * 1.002f) {
					float p = std::min(1.0f, (dj - di) / di * CONV_GAS);
					if (fire) p = std::max(p, 0.7f);
					if (frand() < p) {
						swap_cells(i, j);
						wake(nx, ny);
						return;
					}
				}
			} else if (st == ST_LIQUID && !fire) {
				if (frand() < 0.5f) {
					swap_cells(i, j);
					wake(nx, ny);
					return;
				}
			}
		}
	}
	// diagonal up (if lighter) and lateral random walk
	const int first = (rnd() & 1) ? 1 : -1;
	for (int s = 0; s < 2; s++) {
		const int dd = ring(u + (s == 0 ? first : -first));
		const int nx = x + RX[dd], ny = y + RY[dd];
		if (!inb(nx, ny)) continue;
		const int j = ny * W + nx;
		if (!gas_like(mats[mat[j]].state) || mat[j] == mi) continue;
		if (dens(j) > di * 1.002f && frand() < 0.5f) {
			swap_cells(i, j);
			wake(nx, ny);
			return;
		}
	}
	if (frand() < (fire ? 0.5f : 0.3f)) {
		const int sd = ring(d + 2 * first);
		const int nx = x + RX[sd], ny = y + RY[sd];
		if (inb(nx, ny)) {
			const int j = ny * W + nx;
			if (gas_like(mats[mat[j]].state) && mat[j] != mi) {
				swap_cells(i, j);
				wake(nx, ny);
			}
		}
	}
}

void World::update_air(int i, int x, int y) {
	// Air takes part in buoyancy: colder (denser) air above sinks into warmer air.
	const int u = ring(grav_dir + 4);
	const int nx = x + RX[u], ny = y + RY[u];
	if (!inb(nx, ny)) return;
	const int j = ny * W + nx;
	if (mat[j] != 0) return; // other gases handle themselves
	const float ti = temp[i], tj = temp[j];
	if (tj >= ti - 0.3f) return; // fast reject: above is not colder
	const float di = dens(i), dj = dens(j);
	const float rel = (dj - di) / di;
	if (rel < 0.001f) return;
	wake(x, y);
	if (frand() < std::min(1.0f, rel * CONV_AIR)) {
		swap_cells(i, j);
		wake(nx, ny);
	}
}

// ============================================================================
// specials: burning, explosives, acid, reactions, radioactive sources
// ============================================================================

void World::add_heat(int i, float joules) {
	const float ic = inv_C[mat[i]];
	if (ic == 0.0f) return;
	temp[i] = std::min(std::max(temp[i] + joules * ic, MIN_TEMP), MAX_TEMP);
	const int x = i % W, y = i / W;
	chunks[(y >> CHUNK_SHIFT) * CW + (x >> CHUNK_SHIFT)].therm_awake = true;
}

void World::ignite_cell(int i) {
	const Material &M = mats[mat[i]];
	cflags[i] |= CF_BURNING;
	life[i] = M.burn_min + (M.burn_max - M.burn_min) * frand();
	if (life[i] <= 0.0f) life[i] = FIXED_DT;
}

void World::explode(int cx, int cy, int radius, float energy_j, int into) {
	if (radius < 1) radius = 1;
	if (radius > 48) radius = 48;
	const int R = radius;
	// collect offsets sorted far-to-near so outer cells are pushed first
	scratch_offsets.clear();
	for (int dy = -R; dy <= R; dy++)
		for (int dx = -R; dx <= R; dx++) {
			int d2 = dx * dx + dy * dy;
			if (d2 > R * R) continue;
			scratch_offsets.push_back((d2 << 16) | ((dy + 128) << 8) | (dx + 128));
		}
	std::sort(scratch_offsets.begin(), scratch_offsets.end(), [](int a, int b) { return a > b; });
	air_explosion(cx, cy, R, energy_j * heat_multiplier);
	// energy weights: w = 1 - d/R, sum approx pi R^2 / 3
	const float wsum = 3.14159f * R * R / 3.0f + 1.0f;
	const float e_total = energy_j * heat_multiplier;
	const int fire_id = into;
	for (int code : scratch_offsets) {
		const int dx = (code & 0xFF) - 128, dy = ((code >> 8) & 0xFF) - 128;
		const int x = cx + dx, y = cy + dy;
		if (!inb(x, y)) continue;
		const float d = std::sqrt((float)(dx * dx + dy * dy));
		const float w = 1.0f - d / (R + 0.5f);
		int i = y * W + x;
		const Material &M = mats[mat[i]];
		// explosives inside the blast are set off (chain detonation), never deleted
		if (M.flags & MF_EXPLOSIVE) {
			if (temp[i] < M.exp_temp) temp[i] = M.exp_temp;
			wake(x, y);
			continue;
		}
		// destruction of brittle solids near the centre
		if (M.state == ST_SOLID && !(M.flags & (MF_METAL | MF_FIXED)) && d < R * 0.5f && frand() < w) {
			set_cell(i, 0, temp[i]);
		}
		const Material &M2 = mats[mat[i]];
		// shock wave: throw movable cells outwards
		if ((M2.state == ST_POWDER || M2.state == ST_LIQUID || M2.state == ST_GAS || M2.state == ST_FIRE) && d > 0.5f) {
			const float ux = dx / d, uy = dy / d;
			const int push = (int)((R - d) * 0.8f) + 1;
			int tx = x, ty = y;
			for (int k = 1; k <= push; k++) {
				int px = x + (int)std::lround(ux * k), py = y + (int)std::lround(uy * k);
				if (!inb(px, py) || mat[py * W + px] != 0) break;
				tx = px;
				ty = py;
			}
			if (tx != x || ty != y) {
				int j = ty * W + tx;
				swap_cells(i, j);
				wake(tx, ty);
				i = j;
			}
		}
		// heat
		float share = e_total * w / wsum;
		float ic = inv_C[mat[i]];
		if (ic > 0.0f) {
			float dT = std::min(share * ic, 2500.0f);
			temp[i] = std::min(temp[i] + dT, std::max(temp[i], 3000.0f)); // detonation products ~3000 °C
		}
		const int ci = y * W + x;
		if (mat[ci] == 0 && d < R * 0.6f && fire_id > 0 && frand() < 0.6f) {
			set_cell(ci, fire_id, std::max(temp[ci], mats[fire_id].initial_temp));
		}
		wake(x, y);
	}
}

void World::special_pass() {
	const float dt = FIXED_DT;
	const float dt_th = FIXED_DT * thermal_time_scale * heat_multiplier;
	static const int NX[4] = { 1, -1, 0, 0 };
	static const int NY[4] = { 0, 0, 1, -1 };
	const int n = W * H;
	for (int i = 0; i < n; i++) {
		const int m = mat[i];
		const Material &M = mats[m];
		const uint32_t f = M.flags;
		if (!(f & MF_SPECIAL)) continue;
		const int x = i % W, y = i / W;

		// ---- burning ----
		if (cflags[i] & CF_BURNING) {
			const float burn_total = std::max(0.05f, 0.5f * (M.burn_min + M.burn_max));
			// heat release (power, scaled as a thermal process), capped at flame temperature
			const float flame_t = mats[M.ign_into].initial_temp;
			float dT = M.ign_heat * M.inv_c / burn_total * dt_th;
			if (temp[i] < flame_t) temp[i] = std::min(flame_t, temp[i] + dT);
			chunks[(y >> CHUNK_SHIFT) * CW + (x >> CHUNK_SHIFT)].therm_awake = true;
			// flames into neighbouring air (up preferred)
			if (frand() < 0.35f) {
				const int u = ring(grav_dir + 4 + (int)(rnd() % 3) - 1);
				int nx = x + RX[u], ny = y + RY[u];
				if (inb(nx, ny) && mat[ny * W + nx] == 0) {
					set_cell(ny * W + nx, M.ign_into, mats[M.ign_into].initial_temp);
					wake(nx, ny);
				}
			}
			life[i] -= dt;
			if (life[i] <= 0.0f) {
				const float t = temp[i];
				if (M.residue >= 0 && frand() < M.residue_chance)
					set_cell(i, M.residue, t);
				else
					set_cell(i, M.ign_into, std::max(t, mats[M.ign_into].initial_temp));
				wake(x, y);
				continue;
			}
			wake(x, y);
		}

		// ---- ignition / explosion triggers ----
		if (f & (MF_IGNITE | MF_EXPLOSIVE)) {
			bool flame_near = false;
			for (int k = 0; k < 4; k++) {
				int nx = x + NX[k], ny = y + NY[k];
				if (!inb(nx, ny)) continue;
				int j = ny * W + nx;
				if (mats[mat[j]].state == ST_FIRE || (cflags[j] & CF_BURNING)) {
					flame_near = true;
					break;
				}
			}
			if ((f & MF_EXPLOSIVE) && (temp[i] >= M.exp_temp || flame_near)) {
				const float e = M.exp_energy * M.mass;
				const int into = M.exp_into;
				set_cell(i, into, std::max(temp[i], mats[into].initial_temp));
				explode(x, y, M.exp_radius, e, into);
				continue;
			}
			if ((f & MF_IGNITE) && !(cflags[i] & CF_BURNING)) {
				if (temp[i] >= M.ign_temp || (flame_near && frand() < 3.0f * dt)) {
					ignite_cell(i);
					wake(x, y);
				}
			}
		}

		// ---- acid ----
		if (f & MF_ACID) {
			const int k = rnd() & 3;
			int nx = x + NX[k], ny = y + NY[k];
			if (inb(nx, ny)) {
				int j = ny * W + nx;
				const Material &B = mats[mat[j]];
				if (mat[j] != 0 && !(B.flags & (MF_ACID | MF_FIXED)) && (B.state == ST_SOLID || B.state == ST_POWDER)) {
					float p = 4.0f * M.acid_strength * (1.0f - B.acid_resistance) * dt;
					if (frand() < p) {
						set_cell(j, M.acid_into, temp[j]);
						wake(nx, ny);
						if (frand() < M.acid_consumed) {
							set_cell(i, 0, temp[i]);
							wake(x, y);
							continue;
						}
					}
				}
			}
		}

		// ---- sources and sinks ----
		if (f & MF_EMIT) {
			float p = M.emit_rate * dt;
			const Material &E = mats[M.emit_into];
			const float et = !std::isnan(M.emit_temp) ? M.emit_temp : (std::isnan(E.initial_temp) ? ambient : E.initial_temp);
			for (; p > 0.0f; p -= 1.0f) {
				if (p < 1.0f && frand() >= p) break;
				// prefer the cell "below" for liquids/powders, "above" for gases; then the rest
				const int pref = (E.state == ST_GAS || E.state == ST_FIRE) ? ring(grav_dir + 4) : grav_dir;
				const int r0 = (int)(rnd() & 7);
				for (int q = -1; q < 8; q++) {
					const int dd = q < 0 ? pref : ring(r0 + q);
					const int nx = x + RX[dd], ny = y + RY[dd];
					if (!inb(nx, ny)) continue;
					const int j = ny * W + nx;
					if (mat[j] != 0) continue;
					set_cell(j, M.emit_into, et);
					wake(nx, ny);
					break;
				}
			}
		}
		if (f & MF_DRAIN) {
			float p = M.drain_rate * dt;
			for (; p > 0.0f; p -= 1.0f) {
				if (p < 1.0f && frand() >= p) break;
				const int r0 = (int)(rnd() & 7);
				for (int q = 0; q < 8; q++) {
					const int dd = ring(r0 + q);
					const int nx = x + RX[dd], ny = y + RY[dd];
					if (!inb(nx, ny)) continue;
					const int j = ny * W + nx;
					if (mat[j] == 0 || mats[mat[j]].state == ST_SOLID) continue;
					set_cell(j, 0, ambient);
					wake(nx, ny);
					break;
				}
			}
		}

		// ---- radioactive sources ----
		if (f & MF_NUC_SOURCE) {
			if (M.nuc.decay_heat > 0.0f) add_heat(i, M.nuc.decay_heat * dt_th);
			if (M.nuc.spontaneous > 0.0f) {
				float p = M.nuc.spontaneous * dt;
				while (p > 0.0f) {
					if (frand() < p) emit_neutron(x + frand(), y + frand(), true);
					p -= 1.0f;
				}
			}
		}

		// ---- pair reactions (right and down neighbours, each unordered pair once) ----
		if (f & MF_REACT) {
			for (int k = 0; k < 4; k++) {
				// right/down plus left/up only when that neighbour is not itself reactive (avoid double counting)
				int nx = x + NX[k], ny = y + NY[k];
				if (!inb(nx, ny)) continue;
				int j = ny * W + nx;
				int mj = mat[j];
				if (k == 1 || k == 3) {
					if (mats[mj].flags & MF_REACT) continue; // the other cell processes it
				}
				int16_t r = rx_table[m * 256 + mj];
				if (r == 0) continue;
				const Reaction &R = reactions[std::abs(r) - 1];
				if (frand() >= R.chance * dt) continue;
				float tavg = 0.5f * (temp[i] + temp[j]);
				if (R.has_min && tavg < R.min_t) continue;
				if (R.has_max && tavg > R.max_t) continue;
				int ia = r > 0 ? i : j, ib = r > 0 ? j : i;
				float ta = temp[ia], tb = temp[ib];
				if (R.into_a >= 0) set_cell(ia, R.into_a, ta);
				if (R.into_b >= 0) set_cell(ib, R.into_b, tb);
				if (R.heat != 0.0f) {
					// split in proportion to heat capacity: both cells get the same temperature change
					const float ca = mats[mat[ia]].cell_C, cb = mats[mat[ib]].cell_C;
					const float q = R.heat * heat_multiplier / std::max(ca + cb, 1e-12f);
					add_heat(ia, q * ca);
					add_heat(ib, q * cb);
				}
				wake(x, y);
				wake(nx, ny);
				if (R.explode_radius > 0) {
					explode(x, y, R.explode_radius, std::fabs(R.heat), 0);
				}
				break;
			}
		}
	}
}

// ============================================================================
// heat
// ============================================================================

void World::heat_pass() {
	const float dt_th = FIXED_DT * thermal_time_scale * heat_multiplier;
	const int nm = (int)mats.size();
	int pl[256];
	int np = 0;
	for (int m = 0; m < nm; m++)
		if (m == 0 || mat_count[m] > 0) pl[np++] = m;

	// Multi-rate explicit scheme. A pair whose relaxation coefficient over the whole step is
	// <= 0.2 (water, sand, stone, air ...) is exchanged once with the full dt. Stiff pairs (metals,
	// graphite, flames and gases with tiny heat capacity) get nsub substeps, at most 8; past that
	// their conductance is clamped to 0.2*min(C) per substep. Every exchange is pairwise, so energy
	// is conserved, and every coefficient stays <= 0.2, so it is stable.
	float cmax = 0.0f;
	stiff_mat = -1;
	for (int a = 0; a < np; a++) {
		const int ma = pl[a];
		if (inv_C[ma] == 0.0f) continue;
		for (int b = 0; b < np; b++) {
			float c = F_raw[ma * 256 + pl[b]] * dt_th * inv_C[ma];
			if (c > cmax) {
				cmax = c;
				stiff_mat = ma;
			}
		}
	}
	int nsub = (int)std::ceil(cmax / 0.2f);
	nsub = std::min(std::max(nsub, 1), 8);
	const float dts = dt_th / nsub;
	heat_substeps = nsub;
	for (int a = 0; a < np; a++) {
		const int ma = pl[a];
		for (int b = 0; b < np; b++) {
			const int mb = pl[b];
			const float fr = F_raw[ma * 256 + mb];
			const float ca = inv_C[ma] > 0 ? mats[ma].cell_C : 1e30f;
			const float cb = inv_C[mb] > 0 ? mats[mb].cell_C : 1e30f;
			const float lim = 0.2f * std::min(ca, cb);
			const float full = fr * dt_th;
			if (full <= lim || nsub == 1) {
				F_eff[ma * 256 + mb] = std::min(full, lim);
				F_sub[ma * 256 + mb] = 0.0f;
			} else {
				F_eff[ma * 256 + mb] = -1.0f; // stiff: handled in the substep loop
				F_sub[ma * 256 + mb] = std::min(fr * dts, lim);
			}
		}
	}

	// active chunks = awake dilated by one
	active_list.clear();
	for (int cy = 0; cy < CH; cy++)
		for (int cx = 0; cx < CW; cx++) {
			bool act = false;
			for (int oy = -1; oy <= 1 && !act; oy++)
				for (int ox = -1; ox <= 1; ox++) {
					int ax = cx + ox, ay = cy + oy;
					if (ax < 0 || ay < 0 || ax >= CW || ay >= CH) continue;
					if (chunks[ay * CW + ax].therm_awake) {
						act = true;
						break;
					}
				}
			chunks[cy * CW + cx].therm_active = act;
			if (act) active_list.push_back(cy * CW + cx);
		}

	float *T = temp.data();
	const uint8_t *Mt = mat.data();
	const float *Fe = F_eff.data();
	const float *Fs = F_sub.data();
	const float *IC = inv_C.data();
	const float amb = ambient;
	stiff_list.clear();
	// Jacobi: every flux uses the temperatures at the start of the pass, so heat spreads the same
	// way in all directions (in-place Gauss-Seidel made +x/+y about 8 % faster).
	if (T0buf.size() != temp.size()) T0buf.resize(temp.size());
	std::copy(temp.begin(), temp.end(), T0buf.begin());
	const float *T0 = T0buf.data();
	// ---- pass A: non-stiff pairs, full step; collect stiff pairs ----
	for (int c : active_list) {
		const int cx = c % CW, cy = c / CW;
		const int x0 = cx * CHUNK, y0 = cy * CHUNK;
		const int x1 = std::min(W - 1, x0 + CHUNK - 1), y1 = std::min(H - 1, y0 + CHUNK - 1);
		const int xr = std::min(x1, W - 2); // last x with a right neighbour
		for (int y = y0; y <= y1; y++) {
			const int row = y * W;
			const bool has_down = (y + 1 < H);
			for (int x = x0; x <= x1; x++) {
				const int i = row + x;
				const int ma = Mt[i];
				const float *Fa = Fe + ma * 256;
				const float ica = IC[ma];
				float Ta = T[i];
				if (x <= xr) {
					const int mb = Mt[i + 1];
					const float f = Fa[mb];
					if (f >= 0.0f) {
						const float q = f * (T0[i + 1] - T0[i]);
						Ta += q * ica;
						T[i + 1] -= q * IC[mb];
					} else {
						stiff_list.push_back(i * 2);
					}
				}
				if (has_down) {
					const int mb = Mt[i + W];
					const float f = Fa[mb];
					if (f >= 0.0f) {
						const float q = f * (T0[i + W] - T0[i]);
						Ta += q * ica;
						T[i + W] -= q * IC[mb];
					} else {
						stiff_list.push_back(i * 2 + 1);
					}
				}
				T[i] = Ta;
			}
		}
		// boundary: infinite air at ambient (clamped full-step exchange)
		auto edge = [&](int i) {
			const int m = Mt[i];
			const float f = Fe[m * 256] >= 0.0f ? Fe[m * 256] : Fs[m * 256] * nsub;
			const float k = std::min(f * IC[m], 0.2f);
			T[i] += k * (amb - T[i]);
		};
		if (x0 == 0)
			for (int y = y0; y <= y1; y++) edge(y * W);
		if (x1 == W - 1)
			for (int y = y0; y <= y1; y++) edge(y * W + W - 1);
		if (y0 == 0)
			for (int x = x0; x <= x1; x++) edge(x);
		if (y1 == H - 1)
			for (int x = x0; x <= x1; x++) edge((H - 1) * W + x);
	}
	// ---- pass B: stiff pairs, nsub substeps ----
	const int *sl = stiff_list.data();
	const size_t ns = stiff_list.size();
	if (stiff_q.size() < ns) stiff_q.resize(ns); // grows once, then reused
	float *sq = stiff_q.data();
	for (int s = 0; s < nsub && ns; s++) {
		// Jacobi within the substep: all fluxes first, then apply
		for (size_t k = 0; k < ns; k++) {
			const int code = sl[k];
			const int i = code >> 1;
			const int j = (code & 1) ? i + W : i + 1;
			sq[k] = Fs[Mt[i] * 256 + Mt[j]] * (T[j] - T[i]);
		}
		for (size_t k = 0; k < ns; k++) {
			const int code = sl[k];
			const int i = code >> 1;
			const int j = (code & 1) ? i + W : i + 1;
			T[i] += sq[k] * IC[Mt[i]];
			T[j] -= sq[k] * IC[Mt[j]];
		}
	}

	heat_chunks = (int)active_list.size();
	float tmax = -1e30f;
	for (int c : active_list) post_heat_chunk(c, tmax);
	// sleeping chunks keep their last known maximum
	float mt = -1e30f;
	for (const auto &ch : chunks) mt = std::max(mt, ch.tmax);
	max_temp = mt;
}

void World::handle_phase(int i) {
	const int m = mat[i];
	const Material &M = mats[m];
	if (M.flags & MF_FIXED) return;
	const Transition *up = M.melt.has ? &M.melt : (M.boil.has ? &M.boil : nullptr);
	const Transition *dn = M.freeze.has ? &M.freeze : (M.condense.has ? &M.condense : nullptr);
	const float c = M.heat_capacity;
	float T = temp[i];
	float P = phase[i];
	// give back partially stored latent heat when the cell moves back across the point
	if (P > 0.0f && up && T < up->temp) {
		float take = std::min((up->temp - T) * c, P);
		P -= take;
		T += take * M.inv_c;
	} else if (P < 0.0f && dn && T > dn->temp) {
		float take = std::min((T - dn->temp) * c, -P);
		P += take;
		T -= take * M.inv_c;
	}
	int into = -1;
	float left = 0.0f, tp = 0.0f;
	int dir = 0;
	if (up && T > up->temp) {
		P += (T - up->temp) * c;
		T = up->temp;
		if (P >= up->latent) {
			into = up->into;
			left = P - up->latent;
			tp = up->temp;
			dir = 1;
		}
	} else if (dn && T < dn->temp) {
		P -= (dn->temp - T) * c;
		T = dn->temp;
		if (-P >= dn->latent) {
			into = dn->into;
			left = -P - dn->latent;
			tp = dn->temp;
			dir = -1;
		}
	}
	if (into >= 0) {
		const Material &N = mats[into];
		float nt = tp + dir * left * N.inv_c;
		uint8_t keepflags = cflags[i];
		set_cell(i, into, nt);
		(void)keepflags;
		wake(i % W, i / W);
	} else {
		temp[i] = T;
		phase[i] = P;
	}
}

void World::post_heat_chunk(int c, float &tmax_global) {
	Chunk &ch = chunks[c];
	const int cx = c % CW, cy = c / CW;
	const int x0 = cx * CHUNK, y0 = cy * CHUNK;
	const int x1 = std::min(W - 1, x0 + CHUNK - 1), y1 = std::min(H - 1, y0 + CHUNK - 1);
	float tmin = 1e30f, tmax = -1e30f;
	for (int y = y0; y <= y1; y++) {
		const int row = y * W;
		for (int x = x0; x <= x1; x++) {
			const int i = row + x;
			const uint32_t f = mats[mat[i]].flags;
			if (f & MF_PHASE) handle_phase(i);
			float T = temp[i];
			if (T < MIN_TEMP) temp[i] = T = MIN_TEMP;
			if (T > MAX_TEMP) temp[i] = T = MAX_TEMP;
			if (T < tmin) tmin = T;
			if (T > tmax) tmax = T;
		}
	}
	if (tmax > tmax_global) tmax_global = tmax;
	ch.tmax = tmax;
	// ring around the chunk (ambient outside the grid)
	auto sample = [&](int x, int y) {
		float T = inb(x, y) ? temp[y * W + x] : ambient;
		if (T < tmin) tmin = T;
		if (T > tmax) tmax = T;
	};
	for (int x = x0 - 1; x <= x1 + 1; x++) {
		sample(x, y0 - 1);
		sample(x, y1 + 1);
	}
	for (int y = y0; y <= y1; y++) {
		sample(x0 - 1, y);
		sample(x1 + 1, y);
	}
	const float spread = tmax - tmin;
	ch.therm_awake = spread >= 0.05f;
	if (spread >= 0.5f) {
		// temperature differences drive convection: let movement look at the whole chunk
		if (x0 < ch.nx0) ch.nx0 = x0;
		if (y0 < ch.ny0) ch.ny0 = y0;
		if (x1 > ch.nx1) ch.nx1 = x1;
		if (y1 > ch.ny1) ch.ny1 = y1;
	}
}

} // namespace sim
