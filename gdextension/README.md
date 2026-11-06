# gdextension — ядро песочницы (класс SandWorld)

C++ GDExtension на godot-cpp **10.0.0-stable** (сабмодуль `godot-cpp/`), целевой API **4.5**
(`api_version` задан в `SConstruct`), поэтому `compatibility_minimum = "4.5"`; работает в Godot 4.5–4.7.x.
Контракт — `docs/api.md`, формат данных — `docs/materials-format.md`, отклонения — `NOTES.md`.

## Структура

```
gdextension/
├── SConstruct              сборка, выходные пути ../bin/<platform>/
├── godot-cpp/              сабмодуль, тег 10.0.0-stable
├── src/
│   ├── register_types.cpp  entry_symbol physics_library_init
│   ├── sand_world.*        класс SandWorld: разбор JSON, API, save/load
│   ├── sim.h / sim.cpp     сетка SoA, чанки 64×64, движение, тепло, фазы, горение, взрывы, кислота, реакции
│   ├── sim_neutrons.cpp    нейтроны (точный обход клеток, DDA)
│   ├── sim_air.cpp         поле воздуха (stable fluids 4×4), ветер, перенос тепла воздухом
│   └── sim_render.cpp      цветовые буферы (виды 0–3 и слой воздуха), всё через LUT
└── test/
    ├── fixture_materials.json   минимальный набор материалов для тестов
    └── test.gd                  headless-проверка (см. ниже)
bin/physics.gdextension     описание библиотек для Godot
```

## Требования

- Python 3 + SCons ≥ 4 (`pip install scons`).
- macOS / iOS: Xcode (для iOS нужен полный Xcode, не Command Line Tools: `xcodebuild`, iPhoneOS SDK).
- Linux: gcc ≥ 9 или clang, `pkg-config` не нужен.
- Перед сборкой: `git submodule update --init --recursive`.

## Команды сборки

Все команды из папки `gdextension/`. `-j$(nproc)` / `-j$(sysctl -n hw.ncpu)` по вкусу.

### Linux x86_64

```bash
cd gdextension
scons platform=linux target=template_release arch=x86_64
scons platform=linux target=template_debug   arch=x86_64
# -> bin/linux/libphysics.linux.template_release.x86_64.so
# -> bin/linux/libphysics.linux.template_debug.x86_64.so
```

### macOS (для разработки, universal arm64+x86_64)

```bash
cd gdextension
scons platform=macos target=template_release
scons platform=macos target=template_debug
# -> bin/macos/libphysics.macos.template_release.framework
# -> bin/macos/libphysics.macos.template_debug.framework
```

Только arm64 (быстрее): добавить `arch=arm64`.

### iOS arm64 (+ упаковка в xcframework)

```bash
cd gdextension
scons platform=ios target=template_release arch=arm64
scons platform=ios target=template_debug   arch=arm64
# -> bin/ios/libphysics.ios.template_release.dylib           (слайс устройства)
# -> bin/ios/libphysics.ios.template_release.xcframework     (упаковывается автоматически)
```

`SConstruct` после сборки dylib сам вызывает упаковку. То же вручную (например, если собирали с
`xcframework=no` или добавили слайс симулятора):

```bash
# необязательно: слайс симулятора
scons platform=ios target=template_release ios_simulator=yes arch=arm64 xcframework=no
# упаковка (берёт все имеющиеся слайсы)
rm -rf ../bin/ios/libphysics.ios.template_release.xcframework
xcodebuild -create-xcframework \
  -library ../bin/ios/libphysics.ios.template_release.dylib \
  -output  ../bin/ios/libphysics.ios.template_release.xcframework
# при наличии симулятора добавить: -library ../bin/ios/libphysics.ios.template_release.simulator.dylib
```

Это схема godot-cpp-template: динамическая библиотека в xcframework; экспорт Godot под iOS сам
превращает dylib в встроенный framework и подписывает его вместе с приложением.

### Предположение CI

`cd gdextension && scons platform=<linux|ios|macos> target=template_release` работает как есть
(arch по умолчанию: linux — архитектура хоста, macos — universal, ios — universal, что для
устройства означает только arm64). Для экспорта
debug-сборок нужен и `target=template_debug`.

## Headless-проверка

```bash
D=/tmp/simtest && mkdir -p $D/.godot
cp -R ../bin $D/ && cp test/fixture_materials.json test/test.gd $D/
printf 'config_version=5\n[application]\nconfig/name="simtest"\n' > $D/project.godot
echo 'res://bin/physics.gdextension' > $D/.godot/extension_list.cfg
godot --headless --path $D -s test.gd                 # все тесты
godot --headless --path $D -s test.gd -- only=pot tts=12   # только кастрюля с другим thermal_time_scale
# на настоящих данных: скопировать data/materials.json и reactions.json в $D и
godot --headless --path $D -s test.gd -- data=res://materials.json reactions=res://reactions.json
# only=sand|pot|nuke|save|misc|air|boron|perf
```

Редактор Godot (и `godot --headless`) грузит `*.debug`-библиотеку. Чтобы замерить release, в копии
`physics.gdextension` во временном проекте поменяйте `macos.debug` на путь к `template_release`.
