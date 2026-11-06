# Сборка Physics

Godot 4.7.2 + C++ GDExtension (godot-cpp 10, submodule `gdextension/godot-cpp`).
Платформы: Linux x86_64 и iOS arm64; macOS — только для локальной проверки.

> **Сверить с `gdextension/README.md`.** Команды scons ниже взяты из договорённости с агентом
> ядра (sim-core): `cd gdextension && scons platform=<linux|ios|macos> target=<template_debug|template_release> [arch=...]`.
> Когда появится `gdextension/README.md`, точные команды и имена файлов — там; если они
> разойдутся с этим документом, нужно поправить и `.github/workflows/build.yml`.

## Что где лежит

| Что | Путь |
|---|---|
| Исходники ядра | `gdextension/` (SConstruct, src/) |
| Описатель расширения | `bin/physics.gdextension` |
| Библиотека Linux | `bin/linux/libphysics.linux.template_release.x86_64.so` |
| Библиотека iOS | `bin/ios/libphysics.ios.template_release.xcframework` |
| Библиотека macOS | `bin/macos/libphysics.macos.template_release.framework` |
| Пресеты экспорта | `export_presets.cfg` — «Linux», «iOS», «macOS» |
| CI | `.github/workflows/build.yml` |
| Результаты экспорта | `build/` (в .gitignore) |

Из экспорта исключены `gdextension/*`, `tests/*`, `docs/*`, `*.md`, `build/*`, `.github/*`.

## Первый checkout

```bash
git clone --recurse-submodules <repo>
# или в уже склонированном:
git submodule update --init --recursive
```

## Локально на macOS

Нужно: Godot 4.7.2 (`brew install --cask godot` или `/opt/homebrew/bin/godot`), Python 3, scons
(`pip install scons`). Для macOS-библиотеки хватает Command Line Tools; для iOS-библиотеки и
Xcode-проекта нужен полный Xcode — без него iOS собирается только в CI.

```bash
cd gdextension
scons platform=macos target=template_debug      # для запуска из редактора
scons platform=macos target=template_release    # для экспорта
cd ..

godot --headless --import
mkdir -p build/macos
godot --headless --export-release "macOS" build/macos/Physics.app
open build/macos/Physics.app
```

Пресет «macOS» — universal (в шаблонах 4.7.2 есть только universal-бинарник, arm64-пресет
падает с «godot_macos_release.arm64 не найден»), подпись ad-hoc (`codesign/codesign=1`, без
сертификата), без нотаризации. Библиотеку для macOS собирать тоже universal (умолчание
godot-cpp для `platform=macos`). Если macOS не даёт запустить:
`xattr -dr com.apple.quarantine build/macos/Physics.app`.

Шаблоны экспорта (≈1,3 ГБ, ставятся один раз): редактор → Editor → Manage Export Templates →
Download, либо вручную:

```bash
curl -LO https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz
mkdir -p ~/Library/Application\ Support/Godot/export_templates/4.7.2.stable
unzip -j Godot_v4.7.2-stable_export_templates.tpz 'templates/*' \
  -d ~/Library/Application\ Support/Godot/export_templates/4.7.2.stable
```

### iOS локально (только при наличии Xcode)

```bash
cd gdextension && scons platform=ios target=template_release arch=arm64 && cd ..
# в export_presets.cfg временно впишите application/app_store_team_id (не коммитьте)
mkdir -p build/ios
godot --headless --export-release "iOS" build/ios/Physics.ipa   # export_project_only=true → build/ios/Physics.xcodeproj
open build/ios/Physics.xcodeproj
```

## Локально на Arch Linux

В `extra` есть `godot` 4.7.2 и `scons` (проверено 2026-11-05). Шаблонов экспорта в
официальных репозиториях нет: в AUR есть `godot-export-templates-bin` (версию сверить)
или ставьте вручную, как ниже.

```bash
sudo pacman -S --needed godot scons base-devel git

cd gdextension
scons platform=linux target=template_debug arch=x86_64      # для редактора
scons platform=linux target=template_release arch=x86_64    # для экспорта
cd ..

# шаблоны: в ~/.local/share/godot/export_templates/4.7.2.stable/
curl -LO https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz
mkdir -p ~/.local/share/godot/export_templates/4.7.2.stable
unzip -j Godot_v4.7.2-stable_export_templates.tpz \
  templates/version.txt templates/linux_release.x86_64 templates/linux_debug.x86_64 \
  -d ~/.local/share/godot/export_templates/4.7.2.stable

godot --headless --import
mkdir -p build/linux
godot --headless --export-release "Linux" build/linux/Physics.x86_64
./build/linux/Physics.x86_64
```

PCK встроен в исполняемый файл (`binary_format/embed_pck=true`), но `.so` расширения Godot
кладёт рядом — переносить нужно всю папку `build/linux/`.

## CI (GitHub Actions)

Файл `.github/workflows/build.yml`.

| Событие | Linux | iOS | Release |
|---|---|---|---|
| push в `main`, pull request | да | — | — |
| ручной запуск (Actions → build → Run workflow) | да | да (галочка «Собрать iOS») | — |
| тег `v*` (`git tag v0.1.0 && git push --tags`) | да | да | да |

Новый push в ту же ветку отменяет старый запуск (тег-сборки не отменяются).

**Джоба linux** (ubuntu-24.04, до 45 мин): checkout с submodules → pip scons → `scons
platform=linux target=template_release arch=x86_64` → Godot 4.7.2 + шаблоны Linux (скачиваются
с GitHub Releases, сверяются по SHA512, кэшируются) → `godot --headless --import` →
`--export-release "Linux"` → артефакт `Physics-<версия>-linux-x86_64.tar.gz` (tar сохраняет
бит исполнения).

**Джоба ios** (macos-15, до 75 мин): scons `platform=ios arch=arm64 template_release` →
xcframework → Godot для macOS + `ios.zip` из шаблонов → подстановка Team ID в пресет →
экспорт Xcode-проекта `build/ios/Physics.xcodeproj` → `xcodebuild archive` → `.ipa`.

- Есть secrets подписи → подписанная `.ipa` через временный keychain и `xcodebuild -exportArchive`.
- Нет secrets → неподписанная `Physics-<версия>-ios-unsigned.ipa` (`CODE_SIGNING_ALLOWED=NO`,
  `.app` упакован в `Payload/`) для AltStore / SideStore / Sideloadly.

**Джоба release** (только тег `v*`): GitHub Release с обоими файлами и автозаметками; тег с
дефисом (`v0.1.0-rc1`) публикуется как pre-release.

**Кэш.** Объекты scons (godot-cpp и ядро) кэшируются через `SCONS_CACHE` (его поддерживает
SConstruct godot-cpp); ключ — коммит submodule godot-cpp + хэш `gdextension/src/**` и
`gdextension/SConstruct`. Godot и шаблоны кэшируются по версии. Первый прогон долгий
(скачивание 1,3 ГБ шаблонов и полная сборка godot-cpp), дальше — минуты.

### Secrets для подписанной iOS-сборки

Settings → Secrets and variables → Actions:

| Secret | Что это |
|---|---|
| `IOS_TEAM_ID` | Team ID (10 символов, developer.apple.com → Membership) |
| `IOS_P12_BASE64` | Сертификат Apple Development (или Apple Distribution для ad-hoc) с закрытым ключом, `.p12` в base64 |
| `IOS_P12_PASSWORD` | Пароль `.p12` |
| `IOS_PROVISION_BASE64` | Provisioning profile для `io.github.cb93ka.physics`, `.mobileprovision` в base64 |

Variable (не secret) `IOS_EXPORT_METHOD`: `development` (по умолчанию) или `ad-hoc` — должна
соответствовать типу профиля и сертификата.

```bash
base64 -i cert.p12 | gh secret set IOS_P12_BASE64
gh secret set IOS_P12_PASSWORD
base64 -i Physics_Dev.mobileprovision | gh secret set IOS_PROVISION_BASE64
gh secret set IOS_TEAM_ID --body ABCDE12345
gh variable set IOS_EXPORT_METHOD --body development
```

`.p12`: «Связка ключей» → сертификат «Apple Development: …» вместе с ключом → Экспортировать.
Профиль: developer.apple.com → Profiles → Development (или Ad Hoc) для App ID
`io.github.cb93ka.physics`, с UDID вашего iPhone.

Если задан хоть не весь набор (`IOS_P12_BASE64`, `IOS_PROVISION_BASE64`, `IOS_TEAM_ID`),
CI собирает неподписанную `.ipa`.

## Установка на iPhone

### Без платного аккаунта: неподписанная .ipa

Скачайте артефакт `physics-ios` из запуска CI (или файл из Release) и переподпишите его
своим бесплатным Apple ID одним из инструментов:

- **Sideloadly** (macOS/Windows): подключить iPhone кабелем, перетащить `.ipa`, ввести Apple ID.
- **AltStore** (нужен AltServer на компьютере в той же сети) — My Apps → «+» → выбрать `.ipa`.
- **SideStore** — как AltStore, но продлевает подпись с самого телефона (через VPN-туннель
  StosVPN/LocalDevVPN), компьютер нужен только для первой установки.

На iPhone: Настройки → Конфиденциальность и безопасность → **Режим разработчика** (iOS 16+),
затем Основные → VPN и управление устройством → доверять своему Apple ID.

Ограничения бесплатного Apple ID: подпись живёт **7 дней** (потом приложение не запускается,
пока его не переподписать — AltStore/SideStore делают это сами при наличии связи), не больше
3 таких приложений на устройстве и 10 App ID в неделю.

### С платным Apple Developer Program (99 $ в год)

- Development/Ad Hoc-профили живут год, `.ipa` из CI ставится на зарегистрированные устройства
  (UDID в профиле) через Finder/Apple Configurator или `xcrun devicectl device install app`.
- **TestFlight и App Store доступны только с платным аккаунтом.** Для них нужен метод
  `app-store` (`app-store-connect`), сертификат Apple Distribution, App Store-профиль и
  загрузка через `xcrun altool`/`notarytool`-ключ App Store Connect API — в текущий workflow
  это не входит (план — v0.4).

## Известные ограничения и что сверить

- **Ориентация.** Только landscape задаётся в `project.godot`:
  `display/window/handheld/orientation=4` (sensor landscape — обе альбомные). Godot переносит
  её в Info.plist при экспорте; в пресете iOS такой опции нет.
- **Сжатие текстур для iOS.** В `project.godot` обязателен
  `rendering/textures/vram_compression/import_etc2_astc=true` — без него экспорт iOS падает
  с «configuration errors» (проверено на 4.7.2).
- **Иконка.** Экспорт iOS падает с `Invalid icon (icons/settings_58x58): ''`, если в
  `project.godot` нет `application/config/icon` (или `icons/icon_1024x1024` в пресете).
  Нужна квадратная PNG, лучше 1024×1024 без прозрачности.
- **Редактор в CI** собирается без `template_debug`-библиотеки, поэтому при `--import` Godot
  может писать, что не нашёл библиотеку для `editor`/`debug`. На экспорт это не влияет:
  в экспорт идёт `template_release`. Если описатель мапит `*.debug` на отсутствующий файл и
  импорт начнёт падать — собирать в CI ещё и `template_debug`.
- **`gdextension/.gdignore`** (зона sim-core) избавит Godot от сканирования тысяч файлов
  godot-cpp при импорте — рекомендуется.
- **Минимальная iOS** — 15.0 (умолчание Godot 4.7). godot-cpp по умолчанию собирает с
  `ios_min_version=12.0`, это совместимо.
- **Team ID** в `export_presets.cfg` пустой намеренно: Godot требует его даже для экспорта
  только проекта, CI подставляет secret или заглушку `UNSIGNED00`.
- `xcodebuild` из CI проверен только синтаксически; первый реальный прогон iOS — вручную
  через Run workflow.
