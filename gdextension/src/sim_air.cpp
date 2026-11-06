// Air field: incompressible "stable fluids" on a coarse grid (one cell = 4x4 world cells).
// Driven by buoyancy, fans, explosions and the wind tool; it carries gases, fire, light
// powders and the heat of air back into the world grid.
#include "sim.h"

#include <algorithm>
#include <cstring>

namespace sim {

static const float AIR_VMAX = 160.0f; // world cells per second
static const float AIR_BUOY = 981.0f * 0.35f; // g in cells/s^2 (1 cell = 1 cm), damped for play
static const float AIR_VISC = 0.2f; // also suppresses the collocated-grid checkerboard mode // blend towards neighbour mean per step
static const float AIR_DAMP = 0.996f;
static const int AIR_JACOBI = 24;

static const int GX[8] = { 1, 1, 0, -1, -1, -1, 0, 1 };
static const int GY[8] = { 0, 1, 1, 1, 0, -1, -1, -1 };

static inline bool fluid_state(State s) { return s == ST_EMPTY || s == ST_GAS || s == ST_FIRE; }

void World::air_setup() {
	AW = (W + AIR_SCALE - 1) / AIR_SCALE;
	AH = (H + AIR_SCALE - 1) / AIR_SCALE;
	const size_t n = (size_t)AW * AH;
	for (auto *f : { &au, &av, &au0, &av0, &ap, &ap0, &adiv, &asrc, &atemp0, &ablur, &atmp, &afx, &afy, &awt }) f->assign(n, 0.0f);
	atemp.assign(n, ambient);
	asolid.assign(n, 0);
	acount.assign(n, 0);
	afan.assign(n, 0);
	atotal.assign(n, 0);
	for (int ay = 0; ay < AH; ay++)
		for (int ax = 0; ax < AW; ax++) {
			int cw = std::min(AIR_SCALE, W - ax * AIR_SCALE), ch = std::min(AIR_SCALE, H - ay * AIR_SCALE);
			atotal[ay * AW + ax] = (uint8_t)(cw * ch);
		}
	air_quiet = true;
}

void World::set_air_enabled(bool on) {
	air_enabled = on;
	if (!on) {
		std::fill(au.begin(), au.end(), 0.0f);
		std::fill(av.begin(), av.end(), 0.0f);
		std::fill(asrc.begin(), asrc.end(), 0.0f);
	}
	air_quiet = false;
}

inline float World::air_sample(const std::vector<float> &f, float x, float y) const {
	// x, y in air-cell units, cell centres at integer coordinates
	if (x < 0) x = 0;
	if (y < 0) y = 0;
	if (x > AW - 1) x = (float)(AW - 1);
	if (y > AH - 1) y = (float)(AH - 1);
	int x0 = (int)x, y0 = (int)y;
	int x1 = std::min(x0 + 1, AW - 1), y1 = std::min(y0 + 1, AH - 1);
	float fx = x - x0, fy = y - y0;
	const float *d = f.data();
	float a = d[y0 * AW + x0] + (d[y0 * AW + x1] - d[y0 * AW + x0]) * fx;
	float b = d[y1 * AW + x0] + (d[y1 * AW + x1] - d[y1 * AW + x0]) * fx;
	return a + (b - a) * fy;
}

void World::air_impulse(int cx, int cy, int r, float vx, float vy) {
	if (AW == 0) return;
	const float acx = (cx + 0.5f) / AIR_SCALE - 0.5f, acy = (cy + 0.5f) / AIR_SCALE - 0.5f;
	const float ar = std::max(1.0f, r / (float)AIR_SCALE + 0.5f);
	const int R = (int)std::ceil(ar);
	for (int y = (int)acy - R; y <= (int)acy + R + 1; y++)
		for (int x = (int)acx - R; x <= (int)acx + R + 1; x++) {
			if (x < 0 || y < 0 || x >= AW || y >= AH) continue;
			int i = y * AW + x;
			if (asolid[i]) continue;
			float d = std::sqrt((x - acx) * (x - acx) + (y - acy) * (y - acy));
			if (d > ar) continue;
			float wgt = 1.0f - 0.5f * d / ar;
			au[i] += (vx - au[i]) * wgt;
			av[i] += (vy - av[i]) * wgt;
		}
	air_quiet = false;
}

void World::air_explosion(int cx, int cy, int radius, float energy_j) {
	if (AW == 0 || !air_enabled) return;
	const float acx = (cx + 0.5f) / AIR_SCALE - 0.5f, acy = (cy + 0.5f) / AIR_SCALE - 0.5f;
	const float ar = std::max(1.5f, radius / (float)AIR_SCALE + 1.0f);
	// blast speed grows with the square root of energy (kinetic), capped
	const float s = std::min(AIR_VMAX, 25.0f + 1.6f * std::sqrt(std::max(0.0f, energy_j)));
	const int R = (int)std::ceil(ar) + 1;
	for (int y = (int)acy - R; y <= (int)acy + R + 1; y++)
		for (int x = (int)acx - R; x <= (int)acx + R + 1; x++) {
			if (x < 0 || y < 0 || x >= AW || y >= AH) continue;
			int i = y * AW + x;
			float dx = x - acx, dy = y - acy;
			float d = std::sqrt(dx * dx + dy * dy);
			if (d > ar) continue;
			if (d < ar * 0.5f) {
				// divergence source (expanding gas): the projection keeps this outflow
				asrc[i] += s * 0.25f * (1.0f - d / (ar * 0.5f + 0.01f));
			}
			if (d < 0.3f) continue;
			float k = s * (0.4f + 0.6f * d / ar); // strongest at the rim: an expanding ring
			au[i] += dx / d * k;
			av[i] += dy / d * k;
		}
	air_quiet = false;
}

void World::air_step() {
	if (!air_enabled || AW == 0) return;
	const float dt = FIXED_DT;
	const int n = AW * AH;

	// Skip everything while the world sleeps and the air is still.
	if (air_quiet) {
		bool any = false;
		for (const auto &c : chunks)
			if (c.therm_awake || c.x0 <= c.x1) {
				any = true;
				break;
			}
		if (!any) return;
	}

	// ---- 1. scan the world: obstacles, gas temperature, fans ----
	float *tsum = atmp.data();
	std::fill(atmp.begin(), atmp.end(), 0.0f);
	std::fill(acount.begin(), acount.end(), 0);
	bool any_fan = false;
	uint8_t cls[256];
	for (int m = 0; m < 256; m++) {
		if (m >= (int)mats.size()) cls[m] = 0;
		else cls[m] = fluid_state(mats[m].state) ? 1 : ((mats[m].flags & MF_FAN) ? 2 : 0);
	}
	for (int y = 0; y < H; y++) {
		const int arow = (y / AIR_SCALE) * AW;
		const int row = y * W;
		const uint8_t *mr = mat.data() + row;
		const float *tr = temp.data() + row;
		for (int x = 0; x < W; x++) {
			const uint8_t k = cls[mr[x]];
			if (k == 0) continue;
			const int ai = arow + (x >> 2);
			if (k == 1) {
				acount[ai]++;
				tsum[ai] += tr[x];
				continue;
			}
			const Material &M = mats[mr[x]];
			{
				// a fan is a grille: air passes through it; it drives its own air cell and the one in front
				acount[ai]++;
				tsum[ai] += ambient;
				if (!any_fan) {
					std::fill(afx.begin(), afx.end(), 0.0f);
					std::fill(afy.begin(), afy.end(), 0.0f);
					std::fill(afan.begin(), afan.end(), 0);
					any_fan = true;
				}
				for (int q = 0; q <= 1; q++) {
					int tx = x + (int)std::lround(M.fan_dx * 4.0f * q), ty = y + (int)std::lround(M.fan_dy * 4.0f * q);
					if (!inb(tx, ty)) continue;
					int aj = (ty / AIR_SCALE) * AW + tx / AIR_SCALE;
					afx[aj] += M.fan_dx * M.fan_strength;
					afy[aj] += M.fan_dy * M.fan_strength;
					if (afan[aj] < 255) afan[aj]++;
				}
			}
		}
	}
	float tmin = 1e30f, tmax = -1e30f;
	for (int i = 0; i < n; i++) {
		asolid[i] = (uint8_t)(acount[i] * 2 < atotal[i]);
		if (acount[i]) {
			float t = tsum[i] / acount[i];
			atemp[i] = t;
			if (t < tmin) tmin = t;
			if (t > tmax) tmax = t;
		}
		// solid cells keep their last gas temperature (used only for display)
	}
	float vmax2 = 0.0f, smax = 0.0f;
	for (int i = 0; i < n; i++) {
		vmax2 = std::max(vmax2, au[i] * au[i] + av[i] * av[i]);
		smax = std::max(smax, std::fabs(asrc[i]));
	}
	if (!any_fan && vmax2 < 0.01f && smax < 0.01f && (tmax - tmin) < 0.05f && std::fabs(tmax - ambient) < 0.05f) {
		std::fill(au.begin(), au.end(), 0.0f);
		std::fill(av.begin(), av.end(), 0.0f);
		air_quiet = true;
		return;
	}
	air_quiet = false;

	// ---- 2. buoyancy ----
	// The world is a closed box (walls with free slip on all four edges), so any uniform part of
	// the force is absorbed by the pressure (hydrostatics) and only temperature differences drive
	// flow. Reference = mean gas temperature over the box; F = g' * (T - Tref) / (T + 273).
	const float upx = -(float)GX[grav_dir], upy = -(float)GY[grav_dir];
	const float ul = 1.0f / std::sqrt(upx * upx + upy * upy);
	double tsum_all = 0.0;
	int tn = 0;
	for (int i = 0; i < n; i++)
		if (!asolid[i]) {
			tsum_all += atemp[i];
			tn++;
		}
	const float tref = tn ? (float)(tsum_all / tn) : ambient;
	for (int i = 0; i < n; i++) {
		if (asolid[i]) continue;
		const float T = atemp[i];
		const float b = AIR_BUOY * (T - tref) / std::max(T + 273.15f, 1.0f) * dt;
		au[i] += upx * ul * b;
		av[i] += upy * ul * b;
	}
	if (any_fan)
		for (int i = 0; i < n; i++)
			if (afan[i] && !asolid[i]) {
				float tx = afx[i] / afan[i], ty = afy[i] / afan[i];
				au[i] += (tx - au[i]) * 0.5f;
				av[i] += (ty - av[i]) * 0.5f;
			}

	// ---- 3. advection (semi-Lagrangian) of velocity and gas temperature ----
	au0 = au;
	av0 = av;
	std::copy(atemp.begin(), atemp.end(), atemp0.begin());
	const float k = dt / AIR_SCALE;
	for (int y = 0; y < AH; y++)
		for (int x = 0; x < AW; x++) {
			int i = y * AW + x;
			if (asolid[i]) {
				au[i] = av[i] = 0.0f;
				continue;
			}
			float bx = x - au0[i] * k, by = y - av0[i] * k;
			au[i] = air_sample(au0, bx, by);
			av[i] = air_sample(av0, bx, by);
			atemp[i] = air_sample(atemp0, bx, by);
		}

	// ---- 4. light viscosity ----
	for (int y = 0; y < AH; y++)
		for (int x = 0; x < AW; x++) {
			int i = y * AW + x;
			if (asolid[i]) continue;
			float su = 0, sv = 0;
			int c = 0;
			if (x > 0 && !asolid[i - 1]) su += au[i - 1], sv += av[i - 1], c++;
			if (x < AW - 1 && !asolid[i + 1]) su += au[i + 1], sv += av[i + 1], c++;
			if (y > 0 && !asolid[i - AW]) su += au[i - AW], sv += av[i - AW], c++;
			if (y < AH - 1 && !asolid[i + AW]) su += au[i + AW], sv += av[i + AW], c++;
			if (c) {
				au0[i] = au[i] + AIR_VISC * (su / c - au[i]);
				av0[i] = av[i] + AIR_VISC * (sv / c - av[i]);
			} else {
				au0[i] = au[i];
				av0[i] = av[i];
			}
		}
	au.swap(au0);
	av.swap(av0);

	// ---- 5. pressure projection (Jacobi, warm-started); walls at the grid edge and at obstacles ----
	auto U = [&](int x, int y, int self) -> float {
		(void)self;
		if (x < 0 || x >= AW || y < 0 || y >= AH) return 0.0f;
		int j = y * AW + x;
		return asolid[j] ? 0.0f : au[j];
	};
	auto V = [&](int x, int y, int self) -> float {
		(void)self;
		if (x < 0 || x >= AW || y < 0 || y >= AH) return 0.0f;
		int j = y * AW + x;
		return asolid[j] ? 0.0f : av[j];
	};
	for (int y = 0; y < AH; y++)
		for (int x = 0; x < AW; x++) {
			int i = y * AW + x;
			if (asolid[i]) {
				adiv[i] = 0;
				continue;
			}
			adiv[i] = 0.5f * (U(x + 1, y, i) - U(x - 1, y, i) + V(x, y + 1, i) - V(x, y - 1, i)) - asrc[i];
		}
	{
		// a closed box cannot take a net source: spread the compensating sink over all fluid cells
		double ds = 0.0;
		int dn = 0;
		for (int i = 0; i < n; i++)
			if (!asolid[i]) {
				ds += adiv[i];
				dn++;
			}
		const float dm = dn ? (float)(ds / dn) : 0.0f;
		for (int i = 0; i < n; i++)
			if (!asolid[i]) adiv[i] -= dm;
	}
	// warm start from the previous step's pressure; keep its mean at zero (pure Neumann problem)
	{
		double pm = 0.0;
		for (int i = 0; i < n; i++) pm += ap[i];
		const float pmf = (float)(pm / n);
		for (int i = 0; i < n; i++) ap[i] = asolid[i] ? 0.0f : ap[i] - pmf;
	}
	for (int it = 0; it < AIR_JACOBI; it++) {
		ap0.swap(ap);
		const float *P = ap0.data();
		for (int y = 0; y < AH; y++)
			for (int x = 0; x < AW; x++) {
				int i = y * AW + x;
				if (asolid[i]) {
					ap[i] = 0;
					continue;
				}
				const float pc = P[i];
				float s = 0;
				s += x > 0 ? (asolid[i - 1] ? pc : P[i - 1]) : pc;
				s += x < AW - 1 ? (asolid[i + 1] ? pc : P[i + 1]) : pc;
				s += y > 0 ? (asolid[i - AW] ? pc : P[i - AW]) : pc;
				s += y < AH - 1 ? (asolid[i + AW] ? pc : P[i + AW]) : pc;
				ap[i] = (s - adiv[i]) * 0.25f;
			}
	}
	const float v2max = AIR_VMAX * AIR_VMAX;
	for (int y = 0; y < AH; y++)
		for (int x = 0; x < AW; x++) {
			int i = y * AW + x;
			if (asolid[i]) {
				au[i] = av[i] = 0.0f;
				continue;
			}
			const float pc = ap[i];
			float pl = x > 0 ? (asolid[i - 1] ? pc : ap[i - 1]) : pc;
			float pr = x < AW - 1 ? (asolid[i + 1] ? pc : ap[i + 1]) : pc;
			float pu = y > 0 ? (asolid[i - AW] ? pc : ap[i - AW]) : pc;
			float pd = y < AH - 1 ? (asolid[i + AW] ? pc : ap[i + AW]) : pc;
			float u = (au[i] - 0.5f * (pr - pl)) * AIR_DAMP;
			float v = (av[i] - 0.5f * (pd - pu)) * AIR_DAMP;
			float m2 = u * u + v * v;
			if (m2 > v2max) {
				float s = AIR_VMAX / std::sqrt(m2);
				u *= s;
				v *= s;
			}
			au[i] = u;
			av[i] = v;
		}
	for (int i = 0; i < n; i++) asrc[i] *= 0.8f;

	// ---- 6. heat carried by the air: apply the coarse advection delta to gas cells ----
	{
		float *d = atmp.data(); // reuse as delta
		bool any = false;
		for (int i = 0; i < n; i++) {
			float dd = asolid[i] ? 0.0f : atemp[i] - atemp0[i];
			if (dd > 200.0f) dd = 200.0f;
			if (dd < -200.0f) dd = -200.0f;
			d[i] = dd;
			if (std::fabs(dd) > 0.01f) any = true;
		}
		if (any) {
			uint8_t carry[256];
			for (int m = 0; m < 256; m++)
				carry[m] = m < (int)mats.size() && (mats[m].state == ST_EMPTY || mats[m].state == ST_GAS) ? 1 : 0;
			for (int ay = 0; ay < AH; ay++)
				for (int ax = 0; ax < AW; ax++) {
					const float dd = d[ay * AW + ax];
					if (dd == 0.0f) continue;
					const int x0 = ax * AIR_SCALE, y0 = ay * AIR_SCALE;
					const int x1 = std::min(W, x0 + AIR_SCALE), y1 = std::min(H, y0 + AIR_SCALE);
					for (int y = y0; y < y1; y++) {
						const int row = y * W;
						for (int x = x0; x < x1; x++) {
							const int i = row + x;
							if (!carry[mat[i]]) continue;
							float t = temp[i] + dd;
							temp[i] = t < MIN_TEMP ? MIN_TEMP : (t > MAX_TEMP ? MAX_TEMP : t);
						}
					}
					if (std::fabs(dd) > 0.05f) chunks[(y0 >> CHUNK_SHIFT) * CW + (x0 >> CHUNK_SHIFT)].therm_awake = true;
				}
		}
	}
}

// Moves gases, fire, smoke and light powders along the air field.
void World::wind_pass() {
	if (!air_enabled || AW == 0 || air_quiet) return;
	const float dt = FIXED_DT;
	const uint8_t ws = wind_stamp;
	for (int y = 0; y < H; y++) {
		const int arow = (y / AIR_SCALE) * AW;
		for (int x = 0; x < W; x++) {
			const int i = y * W + x;
			const Material &M = mats[mat[i]];
			const float c = M.wind_coupling;
			if (c <= 0.0f || mat[i] == 0 || clock[i] == ws) continue;
			const int ai = arow + x / AIR_SCALE;
			const float vx = au[ai] * c * dt, vy = av[ai] * c * dt; // cells this step
			if (vx * vx + vy * vy < 1e-6f) continue;
			int cx = x, cy = y, ci = i;
			// up to 3 unit moves, x and y independently, stochastic rounding
			float ax = std::fabs(vx), ay = std::fabs(vy);
			int nx = (int)ax + (frand() < ax - (int)ax ? 1 : 0);
			int ny = (int)ay + (frand() < ay - (int)ay ? 1 : 0);
			nx = std::min(nx, 3);
			ny = std::min(ny, 3);
			const int sx = vx > 0 ? 1 : -1, sy = vy > 0 ? 1 : -1;
			bool moved = false;
			while (nx > 0 || ny > 0) {
				bool dox = nx > 0 && (ny == 0 || (rnd() & 1));
				int tx = cx + (dox ? sx : 0), ty = cy + (dox ? 0 : sy);
				if (dox) nx--;
				else ny--;
				// cells of the same material in the way: the cell jumps to the front of its cloud,
				// otherwise a blob could only move from its leading edge
				const int me = mat[ci];
				int q = 0;
				while (q < 8 && inb(tx, ty) && mat[ty * W + tx] == me) {
					tx += dox ? sx : 0;
					ty += dox ? 0 : sy;
					q++;
				}
				if (!inb(tx, ty)) continue;
				const int j = ty * W + tx;
				const Material &B = mats[mat[j]];
				if (!fluid_state(B.state)) continue;
				swap_cells(ci, j);
				clock[ci] = clock[j] = ws;
				cx = tx;
				cy = ty;
				ci = j;
				moved = true;
			}
			if (moved) {
				wake(x, y);
				wake(cx, cy);
			}
		}
	}
}

} // namespace sim
