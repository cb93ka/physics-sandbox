// Neutron transport: particles marching cell by cell, per-cell interaction probabilities.
#include "sim.h"

#include <algorithm>

namespace sim {

static const float FAST_SPEED = 4.0f; // cells per step
static const float THERMAL_SPEED = 1.0f;
static const float FAST_LIFETIME = 2.0f; // seconds
static const float THERMAL_LIFETIME = 2.5f;

void World::emit_neutron(float x, float y, bool fast) {
	std::vector<Neutron> &dst = in_npass ? new_neutrons : neutrons;
	if ((int)(neutrons.size() + (in_npass ? new_neutrons.size() : 0)) >= MAX_NEUTRONS) return;
	float a = frand() * 6.2831853f;
	dst.push_back(Neutron{ x, y, std::cos(a), std::sin(a), 0.0f, (uint8_t)(fast ? 1 : 0) });
}

void World::fission_at(int i, int x, int y, const Material &M) {
	fissions_this_step++;
	const Nuclear &N = M.nuc;
	add_heat(i, N.fission_energy * heat_multiplier);
	int span = N.npf_max - N.npf_min + 1;
	int k = N.npf_min + (span > 1 ? (int)(rnd() % (uint32_t)span) : 0);
	for (int n = 0; n < k; n++) emit_neutron(x + 0.5f, y + 0.5f, true);
	if (N.poison_into >= 0 && frand() < N.poison_chance) {
		static const int NX[4] = { 1, -1, 0, 0 };
		static const int NY[4] = { 0, 0, 1, -1 };
		int s = rnd() & 3;
		for (int q = 0; q < 4; q++) {
			int d = (s + q) & 3;
			int nx = x + NX[d], ny = y + NY[d];
			if (inb(nx, ny) && mat[ny * W + nx] == 0) {
				set_cell(ny * W + nx, N.poison_into, temp[i]);
				wake(nx, ny);
				break;
			}
		}
	}
	if (N.burnup_into >= 0 && frand() < N.burnup_chance) {
		transmute(i, N.burnup_into);
		wake(x, y);
	}
}

void World::neutron_pass() {
	if (neutrons.empty()) return;
	in_npass = true;
	new_neutrons.clear();
	const float dt = FIXED_DT;
	size_t out = 0;
	const size_t n = neutrons.size();
	for (size_t k = 0; k < n; k++) {
		Neutron nt = neutrons[k];
		bool alive = true;
		// Exact grid traversal (Amanatides-Woo DDA): every crossed cell is visited, so a rod one
		// cell thick cannot be skipped even when the neutron flies several cells per step.
		float remain = nt.fast ? FAST_SPEED : THERMAL_SPEED;
		int cx = (int)std::floor(nt.x), cy = (int)std::floor(nt.y);
		int guard = 0;
		while (remain > 0.0f && alive && guard++ < 64) {
			const float vx = nt.vx, vy = nt.vy;
			const float tx = vx > 1e-7f ? (cx + 1 - nt.x) / vx : (vx < -1e-7f ? (nt.x - cx) / -vx : 1e30f);
			const float ty = vy > 1e-7f ? (cy + 1 - nt.y) / vy : (vy < -1e-7f ? (nt.y - cy) / -vy : 1e30f);
			const float t = std::max(0.0f, std::min(tx, ty));
			if (t >= remain) {
				nt.x += vx * remain;
				nt.y += vy * remain;
				break;
			}
			remain -= t;
			int nx = cx, ny = cy;
			if (tx <= ty) {
				nx += vx > 0 ? 1 : -1;
				nt.x = vx > 0 ? nx + 1e-4f : nx + 1 - 1e-4f;
				nt.y += vy * t;
			} else {
				ny += vy > 0 ? 1 : -1;
				nt.y = vy > 0 ? ny + 1e-4f : ny + 1 - 1e-4f;
				nt.x += vx * t;
			}
			if (!inb(nx, ny)) {
				alive = false;
				break;
			}
			// keep the secondary coordinate inside the new cell (float drift)
			nt.x = std::min(std::max(nt.x, nx + 1e-4f), nx + 1 - 1e-4f);
			nt.y = std::min(std::max(nt.y, ny + 1e-4f), ny + 1 - 1e-4f);
			const int i = ny * W + nx;
			flux[i] += 1.0f;
			const Material &M = mats[mat[i]];
			if (M.flags & MF_NUCLEAR) {
				const Nuclear &N = M.nuc;
				float r = frand();
				const float pf = nt.fast ? N.fast_fission : N.fissile;
				if (r < pf) {
					fission_at(i, nx, ny, M);
					alive = false;
					break;
				}
				r -= pf;
				if (r < N.absorb) {
					alive = false;
					break;
				}
				r -= N.absorb;
				if (r < N.moderate) {
					// elastic scattering: fast -> thermal, isotropic direction; energy lost for this step
					nt.fast = 0;
					float a = frand() * 6.2831853f;
					nt.vx = std::cos(a);
					nt.vy = std::sin(a);
					nt.x = nx + 0.5f;
					nt.y = ny + 0.5f;
					cx = nx;
					cy = ny;
					break;
				}
				r -= N.moderate;
				if (r < N.reflect) {
					// back into the previous cell with some angular spread
					float a = (frand() - 0.5f) * 1.2f;
					float ca = std::cos(a), sa = std::sin(a);
					float rvx = -vx, rvy = -vy;
					nt.vx = rvx * ca - rvy * sa;
					nt.vy = rvx * sa + rvy * ca;
					nt.x = cx + 0.5f;
					nt.y = cy + 0.5f;
					continue;
				}
			}
			cx = nx;
			cy = ny;
		}
		if (!alive) continue;
		nt.age += dt;
		if (nt.age > (nt.fast ? FAST_LIFETIME : THERMAL_LIFETIME)) continue;
		neutrons[out++] = nt;
	}
	neutrons.resize(out);
	in_npass = false;
	for (const Neutron &nn : new_neutrons) {
		if ((int)neutrons.size() >= MAX_NEUTRONS) break;
		neutrons.push_back(nn);
	}
}

} // namespace sim
