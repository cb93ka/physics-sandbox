// Гладкий фон за миром: вертикальный градиент, мягкая виньетка, едва заметный
// размытый «лабораторный» узор (сетка) и плавный value-шум. Без пикселей.
shader_type canvas_item;

uniform vec4 top_color : source_color = vec4(0.085, 0.10, 0.135, 1.0);
uniform vec4 bottom_color : source_color = vec4(0.035, 0.04, 0.055, 1.0);
uniform float vignette = 0.5;
uniform float noise_amount = 0.03;
uniform float grid_amount = 0.018;
uniform float grid_step = 48.0;      // шаг сетки в логических px
uniform float px_scale = 1.0;        // физических px на логический
uniform vec2 size_px = vec2(1280.0, 720.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(17.0, 9.0);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 uv = UV;
	vec2 p = uv * size_px;
	vec3 col = mix(top_color.rgb, bottom_color.rgb, smoothstep(0.0, 1.0, uv.y));
	float n = fbm(p / 220.0 + vec2(TIME * 0.004, 0.0));
	col += (n - 0.5) * noise_amount;
	// Размытая сетка: широкие мягкие линии, к краям слабее.
	vec2 g = abs(fract(p / grid_step) - 0.5) * 2.0;
	float soft = 3.0 / grid_step;
	float line = max(smoothstep(1.0 - soft, 1.0, g.x), smoothstep(1.0 - soft, 1.0, g.y));
	col += line * grid_amount * (0.5 + n);
	vec2 d = uv - 0.5;
	d.x *= size_px.x / size_px.y;
	col *= 1.0 - vignette * smoothstep(0.3, 1.15, length(d));
	// Дизеринг против полос градиента.
	col += (hash(FRAGCOORD.xy + fract(TIME)) - 0.5) / 255.0;
	COLOR = vec4(col, 1.0);
}
