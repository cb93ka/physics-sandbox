// Colour buffer: normal view (with glow and neutrons), thermal camera, neutron flux.
#include "sim.h"

#include <algorithm>

namespace sim {

static inline uint8_t clamp8(float v) { return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v)); }

struct Stop {
	float t;
	float r, g, b;
};

static void lerp_stops(const Stop *s, int n, float t, float &r, float &g, float &b) {
	if (t <= s[0].t) {
		r = s[0].r, g = s[0].g, b = s[0].b;
		return;
	}
	for (int k = 1; k < n; k++) {
		if (t <= s[k].t) {
			float u = (t - s[k - 1].t) / (s[k].t - s[k - 1].t);
			r = s[k - 1].r + (s[k].r - s[k - 1].r) * u;
			g = s[k - 1].g + (s[k].g - s[k - 1].g) * u;
			b = s[k - 1].b + (s[k].b - s[k - 1].b) * u;
			return;
		}
	}
	r = s[n - 1].r, g = s[n - 1].g, b = s[n - 1].b;
}

// Approximate black-body colour (sRGB) for a temperature in °C.
static const Stop BB[] = {
	{ 500, 90, 0, 0 },
	{ 750, 190, 25, 0 },
	{ 1000, 255, 90, 5 },
	{ 1300, 255, 160, 50 },
	{ 1700, 255, 210, 130 },
	{ 2300, 255, 240, 210 },
	{ 3200, 250, 250, 255 },
};

// Thermal camera palette over u in 0..1.
static const Stop IRON[] = {
	{ 0.00f, 10, 10, 40 },
	{ 0.15f, 30, 40, 160 },
	{ 0.30f, 40, 160, 200 },
	{ 0.36f, 60, 200, 90 },
	{ 0.50f, 230, 220, 40 },
	{ 0.68f, 240, 120, 20 },
	{ 0.85f, 220, 30, 30 },
	{ 1.00f, 255, 255, 255 },
};

static inline float thermal_u(float T) {
	// -50..100 linear (0..0.36), 100..3000 logarithmic (0.36..1)
	if (T <= 100.0f) {
		float u = (T + 50.0f) / 150.0f;
		return std::max(0.0f, u) * 0.36f;
	}
	float u = std::log(T / 100.0f) / std::log(30.0f);
	return 0.36f + 0.64f * std::min(1.0f, u);
}

void World::render(int view, uint8_t *out) {
	const int n = W * H;
	if (view == 1) {
		uint8_t lut[256][3];
		for (int k = 0; k < 256; k++) {
			float r, g, b;
			lerp_stops(IRON, 8, k / 255.0f, r, g, b);
			lut[k][0] = clamp8(r), lut[k][1] = clamp8(g), lut[k][2] = clamp8(b);
		}
		for (int i = 0; i < n; i++) {
			int k = (int)(thermal_u(temp[i]) * 255.0f + 0.5f);
			k = std::min(255, std::max(0, k));
			uint8_t *o = out + i * 4;
			// faint material edges so shapes stay readable
			float shade = mat[i] == 0 ? 0.80f : 1.0f;
			o[0] = (uint8_t)(lut[k][0] * shade);
			o[1] = (uint8_t)(lut[k][1] * shade);
			o[2] = (uint8_t)(lut[k][2] * shade);
			o[3] = 255;
		}
		return;
	}

	for (int i = 0; i < n; i++) {
		const int m = mat[i];
		const Material &M = mats[m];
		const uint8_t v = var[i];
		const uint8_t *c = M.colors[v % M.ncolors];
		float r = c[0], g = c[1], b = c[2];
		// per-cell brightness noise
		float j = (float)((int)((v >> 3) & 7) - 3) * 2.5f;
		if (M.state == ST_FIRE) {
			const uint8_t *c2 = M.colors[rnd() % M.ncolors];
			r = c2[0], g = c2[1], b = c2[2];
			j = (float)((int)(rnd() & 31) - 16);
		} else if (M.state == ST_LIQUID && ((step_counter + v) & 63) == 0) {
			j += 8.0f; // shimmer
		}
		r += j, g += j, b += j;
		const float T = temp[i];
		if ((M.glow || (cflags[i] & CF_BURNING)) && T > 450.0f) {
			float br, bg, bb;
			lerp_stops(BB, 7, T, br, bg, bb);
			float k = std::min(1.0f, (T - 450.0f) / 650.0f);
			r = r * (1 - k) + br * k;
			g = g * (1 - k) + bg * k;
			b = b * (1 - k) + bb * k;
		}
		if (cflags[i] & CF_BURNING) {
			float f = 0.35f + 0.3f * frand();
			r = r * (1 - f) + 255 * f;
			g = g * (1 - f) + 120 * f;
			b = b * (1 - f) + 20 * f;
		}
		if (view == 2) {
			float l = (r * 0.3f + g * 0.59f + b * 0.11f) * 0.22f;
			float fl = flux[i];
			float e = 1.0f - std::exp(-fl * 0.25f);
			r = l + 120.0f * e;
			g = l + 255.0f * e;
			b = l + 200.0f * e;
			if (M.flags & MF_NUCLEAR) {
				// tint nuclear-active materials so the core layout stays visible
				if (M.nuc.fissile > 0 || M.nuc.fast_fission > 0) {
					g += 25;
				} else if (M.nuc.absorb > 0.3f) {
					r += 30;
				} else {
					b += 25;
				}
			}
		}
		uint8_t *o = out + i * 4;
		o[0] = clamp8(r);
		o[1] = clamp8(g);
		o[2] = clamp8(b);
		o[3] = 255;
	}
	// neutrons on top
	for (const Neutron &nt : neutrons) {
		int x = (int)nt.x, y = (int)nt.y;
		if (!inb(x, y)) continue;
		uint8_t *o = out + (y * W + x) * 4;
		if (nt.fast) {
			o[0] = (uint8_t)((o[0] + 3 * 200) / 4);
			o[1] = (uint8_t)((o[1] + 3 * 230) / 4);
			o[2] = 255;
		} else {
			o[0] = (uint8_t)((o[0] + 3 * 120) / 4);
			o[1] = 255;
			o[2] = (uint8_t)((o[2] + 3 * 140) / 4);
		}
	}
}

} // namespace sim
