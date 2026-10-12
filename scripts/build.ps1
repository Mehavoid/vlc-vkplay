<#
.SYNOPSIS
  Сборка vkplay-*.luac на Windows 10/11 (MSVC) и, при желании, публикация GitHub Release.

.DESCRIPTION
  Скачивает официальные исходники Lua с lua.org (для 5.1 накладывает патч
  VLC scripts\patches\vlc3-luac-32bits.patch), собирает luac.exe
  и компилирует src\vkplay.lua. Байткод Lua зависит только от версии Lua
  и размеров типов (все цели 64-битные), поэтому на Windows можно собрать
  файлы сразу для всех платформ.

  Требуется Visual Studio 2022 Build Tools с компонентом "C++ build tools":
    winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\build.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Publish -Tag 1.4.0
#>
[CmdletBinding()]
param(
  [ValidateSet('all', 'windows', 'macos', 'linux', 'vlc4')]
  [string[]]$Target = @('all'),
  [switch]$Publish,
  [string]$Tag
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Цель -> версия Lua, встроенная в соответствующий VLC
$Targets = [ordered]@{
  windows = '5.1.5'  # VLC 3.x для Windows (Lua 5.1 + патч VLC)
  macos   = '5.1.5'  # VLC 3.x для macOS (Lua 5.1 + патч VLC)
  linux   = '5.2.4'  # VLC 3.x из репозиториев Debian/Ubuntu (liblua5.2)
  vlc4    = '5.4.7'  # VLC 4.x (все платформы)
}

$BuildAll = $Target -contains 'all'
if ($BuildAll) { $Target = @($Targets.Keys) }
if ($Publish -and -not $Tag) { throw 'С -Publish нужно указать -Tag, например: -Tag 1.4.0' }

$Root = Split-Path -Parent $PSScriptRoot
$Work = Join-Path $Root 'build'
$Dist = Join-Path $Root 'dist'
New-Item -ItemType Directory -Force -Path $Work, $Dist | Out-Null
if ($BuildAll) { Get-ChildItem $Dist -File | Remove-Item -Force }


function Enable-Msvc {
  if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return }

  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) {
    throw 'Visual Studio Build Tools не найдены (см. справку: Get-Help scripts\build.ps1).'
  }

  $vs = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (-not $vs) { throw 'Не найден компонент MSVC x64 (Microsoft.VisualStudio.Component.VC.Tools.x86.x64).' }

  # Переносим окружение vcvars64.bat в текущую сессию PowerShell
  $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
  cmd /c "call `"$vcvars`" >nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
  }
  if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'cl.exe не появился после vcvars64.bat' }
}


function Get-Luac([string]$Version) {
  # Для Lua 5.1 — патч VLC: VLC 3.x для Windows/macOS хранит размеры в байткоде
  # 32-битными (scripts/patches/vlc3-luac-32bits.patch), иначе "bad header".
  $vlcPatch = $Version -like '5.1.*'
  $tag = if ($vlcPatch) { "$Version-vlc" } else { $Version }

  $exe = Join-Path $Work "luac-$tag.exe"
  if (Test-Path $exe) { return $exe }

  $srcRoot = Join-Path $Work "lua-$tag"
  if (-not (Test-Path $srcRoot)) {
    # Распаковка и патч вне репозитория: git apply внутри рабочей копии
    # применяет пути относительно её корня
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("vkplay-lua-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $tgz = Join-Path $tmp "lua-$Version.tar.gz"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "downloading lua-$Version.tar.gz"
    Invoke-WebRequest -UseBasicParsing -Uri "https://www.lua.org/ftp/lua-$Version.tar.gz" -OutFile $tgz
    # Встроенный в Windows bsdtar (tar из Git Bash путает пути вида C:\ с удалённым хостом)
    & "$env:SystemRoot\System32\tar.exe" -xzf $tgz -C $tmp | Out-Host
    if ($LASTEXITCODE) { throw "Не удалось распаковать $tgz" }
    $unpacked = Join-Path $tmp "lua-$Version"

    if ($vlcPatch) {
      if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Для Lua 5.1 нужен git (git apply)' }
      & git -C $unpacked apply -p1 --whitespace=nowarn (Join-Path $PSScriptRoot 'patches\vlc3-luac-32bits.patch') | Out-Host
      if ($LASTEXITCODE) { throw 'Не удалось наложить vlc3-luac-32bits.patch' }
    }
    Move-Item -Path $unpacked -Destination $srcRoot
    Remove-Item -Recurse -Force $tmp
  }

  Enable-Msvc

  # Всё ядро + luac.c, без интерпретатора lua.c
  $files = Get-ChildItem -Path (Join-Path $srcRoot 'src') -Filter '*.c' |
    Where-Object { $_.Name -ne 'lua.c' } |
    ForEach-Object { $_.FullName }

  # Патч VLC использует ssize_t, которого нет в MSVC
  $defines = @('/D_CRT_SECURE_NO_WARNINGS')
  if ($vlcPatch) { $defines += '/Dssize_t=ptrdiff_t' }

  $obj = Join-Path $Work "obj-$tag"
  New-Item -ItemType Directory -Force -Path $obj | Out-Null
  Push-Location $obj
  try {
    & cl.exe /nologo /O2 /MT /W0 @defines "/Fe$exe" @files | Out-Host
    if ($LASTEXITCODE) { throw "cl.exe завершился с ошибкой (Lua $Version)" }
  } finally {
    Pop-Location
  }
  return $exe
}


$script = Join-Path $Root 'src\vkplay.lua'

foreach ($t in $Target) {
  $ver  = $Targets[$t]
  $luac = Get-Luac $ver
  $out  = Join-Path $Dist "vkplay-$t.luac"

  & $luac -s -o $out $script | Out-Host
  if ($LASTEXITCODE) { throw "luac завершился с ошибкой ($t)" }

  # Проверка заголовка: 1B 'Lua' + версия (0x51/0x52/0x54);
  # у 5.1/5.2 байт 8 = sizeof(size_t) в формате байткода:
  #   5.1 — 4 (патч VLC 3.x), 5.2 — 8 (системный Lua в Linux)
  $h = [IO.File]::ReadAllBytes($out)
  $parts  = $ver.Split('.')
  $expect = ([int]$parts[0] -shl 4) + [int]$parts[1]
  if ($h[4] -ne $expect) { throw ("{0}: версия байткода 0x{1:x2}, ожидалась 0x{2:x2}" -f $t, $h[4], $expect) }
  $sizeT = @{ '5.1' = 4; '5.2' = 8 }["$($parts[0]).$($parts[1])"]
  if ($sizeT -and $h[8] -ne $sizeT) {
    throw "${t}: size_t в заголовке = $($h[8]), ожидалось $sizeT — VLC не загрузит такой .luac"
  }

  $hex = ($h[0..11] | ForEach-Object { $_.ToString('x2') }) -join ' '
  Write-Host "built $out (Lua $ver, header: $hex)"
}

# Исходник тоже кладём в релиз: VLC загружает и .lua, это вариант
# для сборок с нестандартной версией Lua (Flatpak, Snap и т. п.)
Copy-Item -Path $script -Destination $Dist -Force

# SHA256SUMS в формате sha256sum (проверка: sha256sum -c SHA256SUMS)
$sums = Get-ChildItem -Path $Dist -File |
  Where-Object { $_.Name -ne 'SHA256SUMS' } |
  Sort-Object Name |
  ForEach-Object { '{0} *{1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name }
[IO.File]::WriteAllText((Join-Path $Dist 'SHA256SUMS'), (($sums -join "`n") + "`n"))
Get-Content (Join-Path $Dist 'SHA256SUMS') | Out-Host

if ($Publish) {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'Нужен GitHub CLI: winget install GitHub.cli, затем gh auth login'
  }
  $assets = Get-ChildItem -Path $Dist -File | ForEach-Object { $_.FullName }
  Push-Location $Root
  try {
    & gh release create $Tag @assets --title $Tag --generate-notes
    if ($LASTEXITCODE) { throw 'gh release create завершился с ошибкой' }
  } finally {
    Pop-Location
  }
}
