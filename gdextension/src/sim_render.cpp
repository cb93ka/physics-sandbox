// Colour buffers: world layer (views 0..3) and the coarse air layer. Everything per cell goes
// through lookup tables (no pow/log/exp per cell).
#include "sim.h"

#include <algorithm>
#include <cstring>

namespace sim {

static inline uint8_t clamp8(float v) { return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v)); }
static inline uint32_t pack(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
	return (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)b << 16) | ((uint32_t)a << 24);
}

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

// Air speed palette: dark blue -> turquoise -> white.
static const Stop SPEED[] = {
	{ 0.0f, 10, 25, 90 },
	{ 0.61f, 30, 200, 200 }, // ~20 cells/s
	{ 1.0f, 255, 255, 255 },
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

// thermal_lut index: (int)(T + 300), 1 K steps, -300..3099 °C
static inline int tidx(float T) {
	int k = (int)(T + 300.0f);
	return k < 0 ? 0 : (k > 3399 ? 3399 : k);
}

void World::prepare_render_tables() {
	for (int k = 0; k < 3400; k++) {
		float r, g, b;
		lerp_stops(IRON, 8, thermal_u((float)k - 300.0f), r, g, b);
		thermal_lut[k][0] = clamp8(r), thermal_lut[k][1] = clamp8(g), thermal_lut[k][2] = clamp8(b);
	}
	for (int k = 0; k < 3100; k++) {
		float r, g, b;
		lerp_stops(BB, 7, 450.0f + k, r, g, b);
		bb_lut[k][0] = clamp8(r), bb_lut[k][1] = clamp8(g), bb_lut[k][2] = clamp8(b);
	}
	for (int k = 0; k < 1024; k++) flux_lut[k] = clamp8(255.0f * (1.0f - std::exp(-(k / 8.0f) * 0.25f)));
	for (int k = 0; k < 1024; k++) {
		const float sp = k / 4.0f; // cells per second
		const float u = std::min(1.0f, std::log(1.0f + sp) / std::log(151.0f));
		float r, g, b;
		lerp_stops(SPEED, 3, u, r, g, b);
		float a = 0.15f + 0.65f * u;
		if (sp < 1.0f) a *= sp; // fades out below 1 cell/s
		speed_lut[k][0] = clamp8(r), speed_lut[k][1] = clamp8(g), speed_lut[k][2] = clamp8(b), speed_lut[k][3] = clamp8(a * 255.0f);
	}
	memset(base_rgba, 0, sizeof(base_rgba));
	for (size_t m = 0; m < mats.size() && m < 256; m++) {
		const Material &M = mats[m];
		uint8_t a;
		if (M.state == ST_EMPTY) a = 0;
		else if (M.state == ST_GAS || M.state == ST_FIRE) a = clamp8(M.gas_alpha * 255.0f);
		else a = 255;
		for (int v = 0; v < 32; v++) {
			const uint8_t *c = M.colors[(v >> 3) % M.ncolors];
			float j = (float)((v & 7) - 3) * 2.5f;
			base_rgba[m][v] = pack(clamp8(c[0] + j), clamp8(c[1] + j), clamp8(c[2] + j), a);
		}
	}
	tables_ready = true;
}

void World::render(int view, uint8_t *out_bytes) {
	if (!tables_ready) prepare_render_tables();
	const int n = W * H;
	uint32_t *out = (uint32_t *)out_bytes;
	// per-variant table slot: colour index from var % ncolors, brightness jitter from bits 3..5
	static_assert(sizeof(uint32_t) == 4, "");

	if (view == 1) {
		for (int i = 0; i < n; i++) {
			const int m = mat[i];
			if (m == 0) {
				out[i] = 0;
				continue;
			}
			const uint8_t *c = thermal_lut[tidx(temp[i])];
			const uint8_t a = (uint8_t)(base_rgba[m][0] >> 24);
			out[i] = pack(c[0], c[1], c[2], a);
		}
		return;
	}

	const uint32_t frame = (uint32_t)step_counter;
	for (int i = 0; i < n; i++) {
		const int m = mat[i];
		const Material &M = mats[m];
		const uint8_t v = var[i];
		if (m == 0) {
			if (view == 2) {
				// neutron flux is visible in empty space too
				float fl = flux[i];
				if (fl > 0.05f) {
					int k = (int)(fl * 8.0f);
					uint8_t e = flux_lut[k > 1023 ? 1023 : k];
					out[i] = pack((uint8_t)(e * 120 / 255), e, (uint8_t)(e * 200 / 255), e);
					continue;
				}
			}
			out[i] = 0;
			continue;
		}
		const int slot = ((v % M.ncolors) << 3) | ((v >> 3) & 7);
		uint32_t c = base_rgba[m][slot];
		const uint32_t f = M.flags;
		const bool burning = (cflags[i] & CF_BURNING) != 0;
		const float T = temp[i];
		if (M.state == ST_FIRE) {
			c = base_rgba[m][rnd() & 31];
		} else if (M.state == ST_LIQUID && ((frame + v) & 63) == 0) {
			c = base_rgba[m][(slot & ~7) | 7]; // shimmer: brightest jitter
		}
		const bool hot = (M.glow || burning) && T > 450.0f;
		if (hot || burning || view >= 2) {
			float r = (float)(c & 255), g = (float)((c >> 8) & 255), b = (float)((c >> 16) & 255);
			const uint8_t a = (uint8_t)(c >> 24);
			if (hot) {
				int k = (int)(T - 450.0f);
				if (k > 3099) k = 3099;
				const uint8_t *bb = bb_lut[k];
				float t = k >= 650 ? 1.0f : k * (1.0f / 650.0f);
				r += (bb[0] - r) * t;
				g += (bb[1] - g) * t;
				b += (bb[2] - b) * t;
			}
			if (burning) {
				float q = 0.35f + 0.3f * frand();
				r += (255 - r) * q;
				g += (120 - g) * q;
				b += (20 - b) * q;
			}
			if (view == 2) {
				float l = (r * 0.3f + g * 0.59f + b * 0.11f) * 0.22f;
				int k = (int)(flux[i] * 8.0f);
				float e = flux_lut[k > 1023 ? 1023 : k] * (1.0f / 255.0f);
				r = l + 120.0f * e;
				g = l + 255.0f * e;
				b = l + 200.0f * e;
				if (f & MF_NUCLEAR) {
					if (M.nuc.fissile > 0 || M.nuc.fast_fission > 0) g += 25;
					else if (M.nuc.absorb > 0.3f) r += 30;
					else b += 25;
				}
			} else if (view == 3) {
				r *= 0.45f;
				g *= 0.45f;
				b *= 0.45f;
			}
			c = pack(clamp8(r), clamp8(g), clamp8(b), a);
		}
		out[i] = c;
	}
	if (view == 3) return; // flow view: the front draws tracers, no neutrons
	// neutrons on top (opaque)
	for (const Neutron &nt : neutrons) {
		int x = (int)nt.x, y = (int)nt.y;
		if (!inb(x, y)) continue;
		uint8_t *o = out_bytes + (y * W + x) * 4;
		if (nt.fast) {
			o[0] = (uint8_t)((o[0] + 3 * 200) / 4);
			o[1] = (uint8_t)((o[1] + 3 * 230) / 4);
			o[2] = 255;
		} else {
			o[0] = (uint8_t)((o[0] + 3 * 120) / 4);
			o[1] = 255;
			o[2] = (uint8_t)((o[2] + 3 * 140) / 4);
		}
		o[3] = 255;
	}
}

void World::render_air(int view, uint8_t *out) {
	if (!tables_ready) prepare_render_tables();
	const int n = AW * AH;
	for (int i = 0; i < n; i++) {
		uint8_t *o = out + i * 4;
		o[0] = o[1] = o[2] = o[3] = 0;
		const float T = atemp[i];
		if (view == 0) {
			float d = T - ambient;
			if (d <= 1.0f) continue;
			float a = std::min(1.0f, d / 300.0f) * 0.25f;
			o[0] = 255;
			o[1] = (uint8_t)(170 + std::min(60.0f, d * 0.1f));
			o[2] = 120;
			o[3] = clamp8(a * 255.0f);
		} else if (view == 1) {
			const uint8_t *c = thermal_lut[tidx(T)];
			o[0] = c[0], o[1] = c[1], o[2] = c[2], o[3] = 255;
		} else if (view == 3) {
			// logarithmic: 1 cell/s barely visible, ~20 turquoise, 150+ white
			float s = std::sqrt(au[i] * au[i] + av[i] * av[i]);
			if (s < 0.05f) continue;
			int k = (int)(s * 4.0f);
			const uint8_t *c = speed_lut[k > 1023 ? 1023 : k];
			o[0] = c[0], o[1] = c[1], o[2] = c[2], o[3] = c[3];
		}
	}
}

} // namespace sim
