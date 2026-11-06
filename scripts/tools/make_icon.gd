extends SceneTree
## Генерирует пиксельную иконку 1024×1024 в res://assets/icon.png.
## Запуск: godot --headless --path . -s res://scripts/tools/make_icon.gd

const N := 64
const OUT := "res://assets/icon.png"


func _init() -> void:
	var img := Image.create_empty(N, N, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# Фон: тёмный градиент.
	for y in N:
		for x in N:
			var t := float(y) / float(N)
			img.set_pixel(x, y, Color(0.05, 0.06, 0.10).lerp(Color(0.09, 0.08, 0.16), t))
	# Каменное дно.
	for y in range(52, N):
		for x in N:
			var g := 0.32 + rng.randf() * 0.08
			img.set_pixel(x, y, Color(g, g, g * 1.05))
	# Вода справа.
	for y in range(40, 52):
		for x in range(34, N):
			var b := rng.randf() * 0.06
			img.set_pixel(x, y, Color(0.12 + b, 0.38 + b, 0.85 + b))
	# Куча песка слева (треугольник) и струя сверху.
	for y in range(26, 52):
		var half := int((y - 26) * 1.15)
		for x in range(24 - half, 24 + half + 1):
			if x >= 0 and x < N:
				var s := rng.randf() * 0.10
				img.set_pixel(x, y, Color(0.92 - s, 0.76 - s, 0.38 - s))
	for y in range(6, 26):
		for x in range(23, 26):
			if rng.randf() < 0.7:
				img.set_pixel(x, y, Color(0.95, 0.80, 0.42))
	# Светящийся зелёный «уран» со звёздочками нейтронов.
	for y in range(14, 22):
		for x in range(44, 54):
			img.set_pixel(x, y, Color(0.35, 0.95, 0.30))
	for p: Vector2i in [Vector2i(40, 10), Vector2i(57, 12), Vector2i(48, 6), Vector2i(58, 25), Vector2i(39, 26)]:
		img.set_pixel(p.x, p.y, Color(0.75, 1.0, 1.0))
	# Пиксельная рамка.
	for i in N:
		for e: Vector2i in [Vector2i(i, 0), Vector2i(i, N - 1), Vector2i(0, i), Vector2i(N - 1, i)]:
			img.set_pixel(e.x, e.y, Color(0.02, 0.02, 0.04))
	img.resize(1024, 1024, Image.INTERPOLATE_NEAREST)
	var err := img.save_png(OUT)
	print("icon saved: ", OUT, " err=", err)
	quit()
