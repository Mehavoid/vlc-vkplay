**Русский** | [English](README_en.md)

# VLC-VKPlay
Плагин (playlist-скрипт) для VLC, позволяющий смотреть трансляции и записи [VK Видео Live](https://live.vkvideo.ru/).

## TODO:
VLC v4 Lua 5.4

## Установка
1. Скачайте файл для вашей версии VLC со страницы [Releases](../../releases):

| VLC | Файл |
|---|---|
| VLC 3.x, Windows (x64) | `vkplay-windows.luac` |
| VLC 3.x, macOS | `vkplay-macos.luac` |
| VLC 3.x, Linux (пакеты Debian/Ubuntu) | `vkplay-linux.luac` |
| VLC 4.x, любая ОС | `vkplay-vlc4.luac` |
| Flatpak / Snap / всё остальное | `vkplay.lua` (исходник, работает везде) |

2. Положите его в каталог playlist-скриптов (создайте, если его нет) и перезапустите VLC:

| ОС | Каталог |
|---|---|
| Windows | `%APPDATA%\vlc\lua\playlist\` |
| macOS | `~/Library/Application Support/org.videolan.vlc/lua/playlist/` |
| Linux | `~/.local/share/vlc/lua/playlist/` |

Контрольные суммы: `sha256sum -c SHA256SUMS`.

## Использование
1. Скопируйте [ссылку](#faq) на канал или запись.
2. Откройте диалог: `Медиа → Открыть URL...`
3. Вставьте ссылку и нажмите `Воспроизвести`.

## F.A.Q
- **Какие ссылки поддерживаются?**
```
https://live.vkvideo.ru/maddyson
https://live.vkvideo.ru/maddyson?share=stream_link
https://live.vkvideo.ru/maddyson/record/eaacfda0-2432-4e81-8107-cb34358d3789?share=stream_link
```
- **В каком качестве открываются записи?** В максимальном доступном (до 1440p). Записи
  открываются через HLS, поэтому старт почти мгновенный даже у многочасовых стримов.
  Если нужен один MP4-файл, поменяйте в начале `vkplay.lua` строку
  `local RECORD_FORMAT = "hls"` на `"mp4"`.
- **Окно VLC растягивается при перемотке.** Это настройка VLC, а не плагина:
  `Инструменты → Настройки → Интерфейс → снять «Изменять размер интерфейса по размеру видео»`.
- **Появляется диалог «Небезопасный сайт».** Обновите плагин: он сам добавляет корневые
  сертификаты CDN (см. [Сертификаты CDN](#сертификаты-cdn)). В логе VLC должна быть строка
  `loaded N trusted CAs from ...\vkplay-certs`.

## Сборка
- Windows 10/11 (Visual Studio 2022 Build Tools):  
  `powershell -ExecutionPolicy Bypass -File scripts\build.ps1` → `dist\`  
  добавьте `-Publish -Tag <версия>`, чтобы создать GitHub Release через `gh`.
- Linux / macOS: `scripts/build.sh <версия-lua> <суффикс>`, например `scripts/build.sh 5.2.4 linux`.
- Для Lua 5.1 (цели `windows`/`macos`) скрипты накладывают патч VLC
  `scripts/patches/vlc3-luac-32bits.patch`: VLC 3.x хранит размеры в байткоде 32-битными,
  и обычный `luac` 5.1 даёт файл, который VLC отвергает с `bad header in precompiled chunk`.
- CI: при push тега собираются все файлы и публикуется Release.

## Сертификаты CDN
Плагин содержит корневые сертификаты CDN VK Видео Live (`TRUST_PEM` в `src/vkplay.lua`)
и передаёт их VLC через `gnutls-dir-trust` **только для потоков, которые открывает сам** —
системное хранилище и другие программы не затрагиваются.

Встроенные корни:
- **HARICA TLS ECC Root CA 2021** / **HARICA ECC RootCA 2015** — текущая цепочка
  `*.okcdn.ru` / `*.vkuser.net` (хранилище Mozilla).
- **Russian Trusted Root CA** (Минцифры, `certs/extra/`), SHA-256
  `D26D2D0231B7C39F92CC738512BA54103519E4405D68B5BD703E9788CA8ECF31`, действует до 27.02.2032.
  Не входит в публичные программы доверия; встроен на случай перехода CDN на него.

`.github/workflows/cert-watch.yml` запускается еженедельно: получает хосты CDN через API VK
(ссылки из `scripts/cdn-probe.json`), проверяет каждый хост по хранилищу Mozilla на runner'е
и `certs/extra/`, и открывает pull request, если цепочка ведёт к корню Mozilla, которого нет
в плагине. Корни никогда не берутся из ответа сервера. Проверьте PR, затем поставьте тег релиза.

Корни вне хранилища Mozilla добавляются только вручную, после сверки отпечатка
с официальным источником:

    python scripts/cert_watch.py --add-root russian_trusted_root_ca.cer --name russian-trusted-root-ca

- Если VK/CDN не отвечают runner'ам GitHub, задайте переменную репозитория
  `CERT_WATCH_RUNNER=self-hosted` и используйте runner без TLS-инспекции.
- Включите *Settings → Actions → General → Allow GitHub Actions to create pull requests*.

## Ссылки
- [Документация Lua](https://www.lua.org/manual/5.4/)
- [Документация по Lua-расширениям VLC](https://github.com/videolan/vlc/blob/e8f0b72538c90bfc630c1c926a88990daaf9b448/share/lua/README.txt)
