-- luacheck: https://luacheck.readthedocs.io
-- VLC 3.x: Lua 5.1 (Windows/macOS) и 5.2 (сборки Linux-дистрибутивов),
-- VLC 4.x: Lua 5.4. Код должен работать во всех трёх.
std = "max"
codes = true
max_line_length = 120
-- Встроенные PEM/Subject — данные, а не код
max_string_line_length = false

include_files = {
  "src/*.lua",
}

-- Функции, которые VLC вызывает у playlist-скрипта
globals = {
  "probe",
  "parse",
}

-- API, которое VLC предоставляет скрипту
read_globals = {
  "vlc",
}
