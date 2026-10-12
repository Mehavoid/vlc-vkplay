local json = require("dkjson")

local LOG = "VKPlay: "
local unpack = table.unpack or unpack

-- Порядок предпочтения типов потоков
local LIVE_TYPES   = { "live_hls", "live_playback_hls", "hls" }

-- Формат записей:
--   "hls" — ondemand_hls: CDN режет MP4 на сегменты, старт почти мгновенный
--           (не нужно качать индекс MP4, у многочасовой записи это десятки МБ);
--   "mp4" — один MP4-файл (quad_hd/full_hd): старт тем дольше, чем длиннее запись.
-- Если формата нет у записи, берётся следующий по списку.
local RECORD_FORMAT = "hls"
local MP4_TYPES = { "ultra_hd", "quad_hd", "full_hd", "high", "medium", "low", "lowest", "tiny" }
local RECORD_TYPES = {
  hls = { "ondemand_hls", "hls", unpack(MP4_TYPES) },
  mp4 = { unpack(MP4_TYPES) },
}
-- Клипы: HLS. В прямом MP4 клипа первые 2-3 секунды — чёрный экран,
-- поэтому MP4 только запасной вариант, если HLS у клипа нет
local CLIP_TYPES = { "hls", unpack(MP4_TYPES) }

-- Опции, которые VLC применит к элементу плейлиста
-- ВАЖНО: не подменять User-Agent/Referer — ссылка подписана (sig) под
-- агента, который запрашивал API (стандартный UA VLC), иначе CDN вернёт 400.
-- LIVE: качество не фиксируем — адаптивный модуль сам меняет битрейт
local LIVE_OPTIONS = {
  ":network-caching=10000",   -- 10 с буфера против подтормаживаний CDN
  ":codec=avcodec,any",       -- AAC через FFmpeg: faad теряет звук на SBR/сменах конфигурации
  ":no-ts-trust-pcr",         -- не доверять PCR: лечит пропажу звука на разрывах
}

-- Записи: набор опций зависит от того, какой формат реально выбран
local RECORD_OPTIONS = {
  -- один MP4-файл
  mp4 = {
    ":network-caching=10000",
    ":codec=avcodec,any",       -- AAC через FFmpeg: faad теряет звук на SBR/сменах конфигурации
    ":input-fast-seek",         -- перемотка на ключевой кадр без долгого preroll
  },
  -- HLS (ondemand_hls)
  hls = {
    ":network-caching=10000",
    ":codec=avcodec,any",
    ":adaptive-logic=highest",  -- запись: всегда максимальное качество, без переключений
    ":no-ts-trust-pcr",
  },
}


-- Корневые сертификаты CDN VK Video Live (*.okcdn.ru и др.).
-- На Windows их часто нет в локальном хранилище (оно наполняется лениво),
-- а GnuTLS в VLC не умеет догружать корни через Windows Update.
-- Доверие добавляется только для потоков, открытых этим скриптом
-- (опция gnutls-dir-trust элемента), а не для системы в целом.
-- Список обновляет scripts/cert_watch.py: из хранилища Mozilla автоматически
-- (через PR), ручные корни — из certs/extra/ (--add-root).
local TRUST_FILE = "vkplay-roots.pem"
local LEGACY_TRUST_FILES = { "harica-roots.pem" }
local TRUST_PEM = [[
# CN=HARICA TLS ECC Root CA 2021,O=Hellenic Academic and Research Institutions CA,C=GR
# SHA-1 BCB0C19DE9989270193857E98DA7B45D6EEE0148  notAfter 2045-02-13
-----BEGIN CERTIFICATE-----
MIICVDCCAdugAwIBAgIQZ3SdjXfYO2rbIvT/WeK/zjAKBggqhkjOPQQDAzBsMQsw
CQYDVQQGEwJHUjE3MDUGA1UECgwuSGVsbGVuaWMgQWNhZGVtaWMgYW5kIFJlc2Vh
cmNoIEluc3RpdHV0aW9ucyBDQTEkMCIGA1UEAwwbSEFSSUNBIFRMUyBFQ0MgUm9v
dCBDQSAyMDIxMB4XDTIxMDIxOTExMDExMFoXDTQ1MDIxMzExMDEwOVowbDELMAkG
A1UEBhMCR1IxNzA1BgNVBAoMLkhlbGxlbmljIEFjYWRlbWljIGFuZCBSZXNlYXJj
aCBJbnN0aXR1dGlvbnMgQ0ExJDAiBgNVBAMMG0hBUklDQSBUTFMgRUNDIFJvb3Qg
Q0EgMjAyMTB2MBAGByqGSM49AgEGBSuBBAAiA2IABDgI/rGgltJ6rK9JOtDA4MM7
KKrxcm1lAEeIhPyaJmuqS7psBAqIXhfyVYf8MLA04jRYVxqEU+kw2anylnTDUR9Y
STHMmE5gEYd103KUkE+bECUqqHgtvpBBWJAVcqeht6NCMEAwDwYDVR0TAQH/BAUw
AwEB/zAdBgNVHQ4EFgQUyRtTgRL+BNUW0aq8mm+3oJUZbsowDgYDVR0PAQH/BAQD
AgGGMAoGCCqGSM49BAMDA2cAMGQCMBHervjcToiwqfAircJRQO9gcS3ujwLEXQNw
SaSS6sUUiHCm0w2wqsosQJz76YJumgIwK0eaB8bRwoF8yguWGEEbo/QwCZ61IygN
nxS2PFOiTAZpffpskcYqSUXm7LcT4Tps
-----END CERTIFICATE-----
# CN=Hellenic Academic and Research Institutions ECC RootCA 2015,O=Hellenic Academic and Research Institutions Cert. Authority,L=Athens,C=GR
# SHA-1 9FF1718D92D59AF37D7497B4BC6F84680BBAB666  notAfter 2040-06-30
-----BEGIN CERTIFICATE-----
MIICwzCCAkqgAwIBAgIBADAKBggqhkjOPQQDAjCBqjELMAkGA1UEBhMCR1IxDzAN
BgNVBAcTBkF0aGVuczFEMEIGA1UEChM7SGVsbGVuaWMgQWNhZGVtaWMgYW5kIFJl
c2VhcmNoIEluc3RpdHV0aW9ucyBDZXJ0LiBBdXRob3JpdHkxRDBCBgNVBAMTO0hl
bGxlbmljIEFjYWRlbWljIGFuZCBSZXNlYXJjaCBJbnN0aXR1dGlvbnMgRUNDIFJv
b3RDQSAyMDE1MB4XDTE1MDcwNzEwMzcxMloXDTQwMDYzMDEwMzcxMlowgaoxCzAJ
BgNVBAYTAkdSMQ8wDQYDVQQHEwZBdGhlbnMxRDBCBgNVBAoTO0hlbGxlbmljIEFj
YWRlbWljIGFuZCBSZXNlYXJjaCBJbnN0aXR1dGlvbnMgQ2VydC4gQXV0aG9yaXR5
MUQwQgYDVQQDEztIZWxsZW5pYyBBY2FkZW1pYyBhbmQgUmVzZWFyY2ggSW5zdGl0
dXRpb25zIEVDQyBSb290Q0EgMjAxNTB2MBAGByqGSM49AgEGBSuBBAAiA2IABJKg
QehLgoRc4vgxEZmGZE4JJS+dQS8KrjVPdJWyUWRrjWvmP3CV8AVER6ZyOFB2lQJa
jq4onvktTpnvLEhvTCUp6NFxW98dwXU3tNf6e3pCnGoKVlp8aQuqgAkkbH7BRqNC
MEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFLQi
C4KZJAEOnLvkDv2/+5cgk5kqMAoGCCqGSM49BAMCA2cAMGQCMGfOFmI4oqxiRaep
lSTAGiecMjvAwNW6qef4BENThe5SId6d9SWDPp5YSy/XZxMOIQIwBeF1Ad5o7Sof
TUwJCA3sS61kFyjndc5FZXIhF8siQQ6ME5g4mlRtm8rifOoCWCKR
-----END CERTIFICATE-----
# CN=Russian Trusted Root CA,O=The Ministry of Digital Development and Communications,C=RU
# SHA-1 8FF915CCAB7BC16F8C5C8099D53E0E115B3AEC2F  notAfter 2032-02-27
-----BEGIN CERTIFICATE-----
MIIFwjCCA6qgAwIBAgICEAAwDQYJKoZIhvcNAQELBQAwcDELMAkGA1UEBhMCUlUx
PzA9BgNVBAoMNlRoZSBNaW5pc3RyeSBvZiBEaWdpdGFsIERldmVsb3BtZW50IGFu
ZCBDb21tdW5pY2F0aW9uczEgMB4GA1UEAwwXUnVzc2lhbiBUcnVzdGVkIFJvb3Qg
Q0EwHhcNMjIwMzAxMjEwNDE1WhcNMzIwMjI3MjEwNDE1WjBwMQswCQYDVQQGEwJS
VTE/MD0GA1UECgw2VGhlIE1pbmlzdHJ5IG9mIERpZ2l0YWwgRGV2ZWxvcG1lbnQg
YW5kIENvbW11bmljYXRpb25zMSAwHgYDVQQDDBdSdXNzaWFuIFRydXN0ZWQgUm9v
dCBDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMfFOZ8pUAL3+r2n
qqE0Zp52selXsKGFYoG0GM5bwz1bSFtCt+AZQMhkWQheI3poZAToYJu69pHLKS6Q
XBiwBC1cvzYmUYKMYZC7jE5YhEU2bSL0mX7NaMxMDmH2/NwuOVRj8OImVa5s1F4U
zn4Kv3PFlDBjjSjXKVY9kmjUBsXQrIHeaqmUIsPIlNWUnimXS0I0abExqkbdrXbX
YwCOXhOO2pDUx3ckmJlCMUGacUTnylyQW2VsJIyIGA8V0xzdaeUXg0VZ6ZmNUr5Y
Ber/EAOLPb8NYpsAhJe2mXjMB/J9HNsoFMBFJ0lLOT/+dQvjbdRZoOT8eqJpWnVD
U+QL/qEZnz57N88OWM3rabJkRNdU/Z7x5SFIM9FrqtN8xewsiBWBI0K6XFuOBOTD
4V08o4TzJ8+Ccq5XlCUW2L48pZNCYuBDfBh7FxkB7qDgGDiaftEkZZfApRg2E+M9
G8wkNKTPLDc4wH0FDTijhgxR3Y4PiS1HL2Zhw7bD3CbslmEGgfnnZojNkJtcLeBH
BLa52/dSwNU4WWLubaYSiAmA9IUMX1/RpfpxOxd4Ykmhz97oFbUaDJFipIggx5sX
ePAlkTdWnv+RWBxlJwMQ25oEHmRguNYf4Zr/Rxr9cS93Y+mdXIZaBEE0KS2iLRqa
OiWBki9IMQU4phqPOBAaG7A+eP8PAgMBAAGjZjBkMB0GA1UdDgQWBBTh0YHlzlpf
BKrS6badZrHF+qwshzAfBgNVHSMEGDAWgBTh0YHlzlpfBKrS6badZrHF+qwshzAS
BgNVHRMBAf8ECDAGAQH/AgEEMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsF
AAOCAgEAALIY1wkilt/urfEVM5vKzr6utOeDWCUczmWX/RX4ljpRdgF+5fAIS4vH
tmXkqpSCOVeWUrJV9QvZn6L227ZwuE15cWi8DCDal3Ue90WgAJJZMfTshN4OI8cq
W9E4EG9wglbEtMnObHlms8F3CHmrw3k6KmUkWGoa+/ENmcVl68u/cMRl1JbW2bM+
/3A+SAg2c6iPDlehczKx2oa95QW0SkPPWGuNA/CE8CpyANIhu9XFrj3RQ3EqeRcS
AQQod1RNuHpfETLU/A2gMmvn/w/sx7TB3W5BPs6rprOA37tutPq9u6FTZOcG1Oqj
C/B7yTqgI7rbyvox7DEXoX7rIiEqyNNUguTk/u3SZ4VXE2kmxdmSh3TQvybfbnXV
4JbCZVaqiZraqc7oZMnRoWrXRG3ztbnbes/9qhRGI7PqXqeKJBztxRTEVj8ONs1d
WN5szTwaPIvhkhO3CO5ErU2rVdUr89wKpNXbBODFKRtgxUT70YpmJ46VVaqdAhOZ
D9EUUn4YaeLaS8AjSF/h7UkjOibNc4qVDiPP+rkehFWM66PVnP1Msh93tc+taIfC
EYVMxjh8zNbFuoc7fzvvrFILLe7ifvEIUqSVIC/AzplM/Jxw7buXFeGP1qVCBEHq
391d/9RAfaZ12zkwFsl+IKwE/OZxW8AHa9i1p4GO0YSNuczzEm4=
-----END CERTIFICATE-----
]]


local function trust_dir()
  if package.config:sub(1, 1) == "\\" then
    local appdata = os.getenv("APPDATA")
    return appdata and (appdata.."\\vlc\\vkplay-certs"), "\\", true
  end
  local base = os.getenv("XDG_DATA_HOME") or ((os.getenv("HOME") or "").."/.local/share")
  return base.."/vlc/vkplay-certs", "/", false
end


-- Кладёт PEM в отдельный каталог (однократно) и возвращает путь к нему
local function ensure_trust_dir()
  if not (io and os and package) then return nil end

  local dir, sep, is_windows = trust_dir()
  if not dir then return nil end
  local path = dir..sep..TRUST_FILE

  local f = io.open(path, "rb")
  if f then
    local current = f:read("*a")
    f:close()
    if current == TRUST_PEM then return dir end
  end

  f = io.open(path, "wb")
  if not f then
    if is_windows then
      os.execute('mkdir "'..dir..'" 2>nul')
    else
      os.execute("mkdir -p '"..dir.."'")
    end
    f = io.open(path, "wb")
  end
  if not f then
    vlc.msg.warn(LOG.."cannot write "..path)
    return nil
  end

  f:write(TRUST_PEM)
  f:close()
  for _, name in ipairs(LEGACY_TRUST_FILES) do
    os.remove(dir..sep..name)
  end
  vlc.msg.info(LOG.."trusted roots written to "..path)
  return dir
end


-- Копия набора опций + каталог доверия GnuTLS
local function with_trust(options)
  local out = {}
  for i, o in ipairs(options) do out[i] = o end
  local dir = ensure_trust_dir()
  if dir then table.insert(out, ":gnutls-dir-trust="..dir) end
  return out
end


local function match_all(str, pattern)
  local matched = {}
  for m in string.gmatch(str, pattern) do
    table.insert(matched, m)
  end
  return unpack(matched)
end


local function get_json(url)
  local stream = vlc.stream(url)
  if not stream then
    return nil, "Failed to create VLC stream"
  end

  local chunks = {}
  while true do
    local chunk = stream:read(65536)
    if not chunk or chunk == "" then break end
    table.insert(chunks, chunk)
  end

  local data, _, err = json.decode(table.concat(chunks))
  if not data then
    return nil, "JSON decode error: "..(err or "unknown error")
  end
  return data
end


local function api_call(path)
  local data, err = get_json("https://api.live.vkvideo.ru/v1/blog/"..path)
  if not data then
    vlc.msg.err(LOG.."API call failed: "..err)
    return {}
  end
  return data
end


-- Выбирает первый непустой URL по списку предпочтений
local function pick_url(player_urls, prefs)
  local by_type = {}
  for _, p in ipairs(player_urls or {}) do
    if p.type and p.url and p.url ~= "" then
      by_type[p.type] = p.url
      vlc.msg.dbg(LOG.."available: "..p.type.." -> "..p.url)
    end
  end

  for _, t in ipairs(prefs) do
    if by_type[t] then
      vlc.msg.info(LOG.."using stream type: "..t)
      return by_type[t], t, by_type
    end
  end

  vlc.msg.err(LOG.."no suitable stream type found")
  return nil
end


-- ---------------------------------------------------------------------------
-- Записи в HLS (ondemand_hls): выбор варианта
--
-- VLC при adaptive-logic=highest берёт вариант с наибольшим (AVERAGE-)BANDWIDTH,
-- а у CDN VK эти числа не соответствуют качеству: 720p объявлен «тяжелее»
-- 1080p/1440p. Поэтому master-плейлист разбираем сами (второй этап parse,
-- VLC к этому моменту уже открыл master с нашим gnutls-dir-trust) и выбираем
-- по разрешению, затем по уровню H.264, затем по битрейту.
-- ---------------------------------------------------------------------------

-- Известные домены CDN записей (встречались: *.okcdn.ru, *.vkuser.net)
local CDN_DOMAINS = { "okcdn%.ru", "vkuser%.net" }


local function has_marker()
  local ok, marker = pcall(vlc.var.inherit, nil, "meta-url")
  return ok and marker ~= nil and marker ~= ""
end


-- Второй этап выбора варианта HLS:
--   * master записи  …/ondemand/hls4_*.m3u8 на известном CDN;
--   * любой .m3u8 элемента, созданного нашим первым этапом (метка :meta-url) —
--     записи на новом CDN и HLS клипов (video.m3u8?cmd=videoPlayerCdn).
-- Выбранный вариант отдаётся без :meta-url, поэтому повторно этап не сработает.
local function is_ondemand_master()
  local host = vlc.path:match("^([%w%.%-]+)/.-/ondemand/hls4_[^/?#]*%.m3u8")
  if host then
    for _, d in ipairs(CDN_DOMAINS) do
      if host:match("%."..d.."$") then return true end
    end
  end
  return vlc.path:match("^[%w%.%-]+/[^?#]-%.m3u8") ~= nil and has_marker()
end


local function hls_attr(line, name)
  return line:match("[:,]"..name.."=\"([^\"]*)\"") or line:match("[:,]"..name.."=([^,]*)")
end


-- avc1.PPCCLL -> LL (уровень H.264: 0x1f=3.1 720p, 0x2a=4.2 1080p, 0x33=5.1 1440p)
local function avc_level(codecs)
  local level = codecs and codecs:match("avc1%.%x%x%x%x(%x%x)")
  return level and tonumber(level, 16) or 0
end


local function better(a, b)
  for i = 1, #a do
    if a[i] ~= b[i] then return a[i] > b[i] end
  end
  return false
end


local function inherit(name)
  local ok, value = pcall(vlc.var.inherit, nil, name)
  if ok and value and value ~= "" then return value end
  return nil
end


-- Ссылка из плейлиста -> абсолютный URL (RFC 3986, без ../):
--   https://h/p  — как есть;   //h/p — схема master;
--   /p           — от корня хоста master (так у клипов);   p — от каталога master
local function resolve_url(ref)
  if ref:match("^%a[%w+.-]*://") then return ref end
  local scheme = vlc.access
  local host = vlc.path:match("^([^/?#]+)") or ""
  if ref:sub(1, 2) == "//" then return scheme..":"..ref end
  if ref:sub(1, 1) == "/" then return scheme.."://"..host..ref end
  local dir = vlc.path:gsub("[?#].*$", ""):gsub("[^/]*$", "")
  return scheme.."://"..dir..ref
end


-- Метка времени первого этапа (:start-time) переносится на выбранный вариант
local function with_start(options)
  local out = {}
  for i, o in ipairs(options) do out[i] = o end
  local start = tonumber(inherit("start-time"))
  if start and start > 0 then table.insert(out, ":start-time="..start) end
  return out
end


local function ondemand_variant()
  local best_uri, best_key, pending
  local media_playlist = false   -- #EXTINF без #EXT-X-STREAM-INF: это не master

  while true do
    local line = vlc.readline()
    if not line then break end
    line = line:gsub("\r$", "")
    if line:match("^#EXTINF:") then
      media_playlist = true
    end
    if line:match("^#EXT%-X%-STREAM%-INF:") then
      pending = line
    elseif pending and line ~= "" and not line:match("^#") then
      local w, h = (hls_attr(pending, "RESOLUTION") or ""):match("(%d+)x(%d+)")
      local key = {
        tonumber(h) or 0,
        avc_level(hls_attr(pending, "CODECS")),
        tonumber(hls_attr(pending, "AVERAGE-BANDWIDTH") or hls_attr(pending, "BANDWIDTH")) or 0,
      }
      vlc.msg.dbg(LOG.."variant "..(w or "?").."x"..(h or "?").." level="..key[2].." bw="..key[3])
      if not best_key or better(key, best_key) then
        best_uri, best_key = line, key
      end
      pending = nil
    end
  end

  local item = {
    name        = inherit("meta-title"),
    artist      = inherit("meta-artist"),
    description = inherit("meta-description"),
  }

  if best_uri then
    item.path = resolve_url(best_uri)
    item.options = with_trust(with_start(RECORD_OPTIONS.hls))
    vlc.msg.info(LOG.."selected HLS variant: height="..best_key[1].." level="..best_key[2]
                 .." bw="..best_key[3])
    return item
  end

  -- Не master, а плейлист сегментов (один вариант): отдаём его VLC как есть.
  -- Без :meta-url, поэтому второй этап на нём не сработает повторно.
  if media_playlist then
    item.path = vlc.access.."://"..vlc.path
    item.options = with_trust(with_start(RECORD_OPTIONS.hls))
    vlc.msg.info(LOG.."single-variant HLS playlist, playing as is")
    return item
  end

  -- master не разобрался: запасной вариант — MP4 той же записи
  local mp4 = inherit("meta-url")
  if not mp4 then
    vlc.msg.err(LOG.."no variants in HLS master and no MP4 fallback")
    return nil
  end
  vlc.msg.warn(LOG.."no variants in HLS master, falling back to MP4")
  item.path = mp4
  item.options = with_trust(with_start(RECORD_OPTIONS.mp4))
  return item
end


local function copy(t)
  local out = {}
  for i, v in ipairs(t) do out[i] = v end
  return out
end


local function broadcast(channel)
  local container = api_call(channel.."/public_video_stream?from=layer")
  local data = container and container.data
  if not data or not data[1] then
    vlc.msg.err(LOG.."Stream is currently offline or no data")
    return nil
  end

  local url = pick_url(data[1].playerUrls, LIVE_TYPES)
  if not url then return nil end

  return {
    path        = url,
    name        = container.title,
    artist      = container.user and container.user.nick,
    description = container.category and container.category.title,
    options     = with_trust(LIVE_OPTIONS),
  }
end


-- ---------------------------------------------------------------------------
-- Метка времени: ?tc=1928 (секунды) или ?t=1h2m3s / ?t=90
-- ---------------------------------------------------------------------------

local function start_time()
  local query = vlc.path:match("%?(.*)$")
  if not query then return nil end
  for key, value in query:gmatch("([^&=]+)=([^&#]*)") do
    if key == "tc" or key == "t" then
      local seconds = tonumber(value)
      if not seconds and value:match("^%d+[hms]") and value:match("^[%dhms]+$") then
        -- 1h2m3s / 5m / 90s: каждое число берётся по своему суффиксу
        seconds = (tonumber(value:match("(%d+)h")) or 0) * 3600
                + (tonumber(value:match("(%d+)m")) or 0) * 60
                + (tonumber(value:match("(%d+)s")) or 0)
      end
      if seconds and seconds > 0 then return seconds end
    end
  end
  return nil
end


-- ---------------------------------------------------------------------------
-- Запись или клип -> элемент плейлиста
--   obj: объект API/страницы с полями title, data[1].playerUrls, blog/user, category
-- ---------------------------------------------------------------------------

local function vod_item(obj, start, types)
  local player_urls = obj.data and obj.data[1] and obj.data[1].playerUrls or obj.playerUrls
  local url, kind, by_type = pick_url(player_urls, types or RECORD_TYPES[RECORD_FORMAT] or RECORD_TYPES.hls)
  if not url then return nil end

  -- blog.owner — стример; author у клипа — тот, кто его нарезал
  local owner = (obj.blog and obj.blog.owner) or obj.user or {}
  local title = obj.title and obj.title:gsub("%s+$", "")
  local artist = owner.displayName or owner.nick
  local description = obj.category and obj.category.title
  local clipper = obj.author and (obj.author.displayName or obj.author.nick)
  if clipper and clipper ~= artist then
    description = (description and description.." · " or "").."клип: "..clipper
  end

  local options
  if kind == "ondemand_hls" or kind == "hls" then
    -- второй этап (ondemand_variant) прочитает эти опции через vlc.var.inherit
    options = copy(RECORD_OPTIONS.hls)
    if title then table.insert(options, ":meta-title="..title) end
    if artist then table.insert(options, ":meta-artist="..artist) end
    if description then table.insert(options, ":meta-description="..description) end
    for _, t in ipairs(MP4_TYPES) do
      if by_type[t] then
        table.insert(options, ":meta-url="..by_type[t])
        break
      end
    end
  elseif kind:find("hls", 1, true) then
    options = copy(RECORD_OPTIONS.hls)
  else
    options = copy(RECORD_OPTIONS.mp4)
  end

  if start then
    table.insert(options, ":start-time="..start)
    vlc.msg.info(LOG.."start time: "..start.." s")
  end

  return {
    path        = url,
    name        = title,
    artist      = artist,
    description = description,
    options     = with_trust(options),
  }
end


local function records(channel, record_id, start)
  local container = api_call(channel.."/public_video_stream/record/"..record_id)
  local record = container and container.data and container.data.record
  if not record or not record.data or not record.data[1] then
    vlc.msg.err(LOG.."Record not found: "..record_id)
    return nil
  end
  return vod_item(record, start)
end


-- ---------------------------------------------------------------------------
-- Клипы (моменты): live.vkvideo.ru/<channel>/clip/<id>
--
-- Отдельного API для клипов нет: и сайт, и плагин берут данные из JSON состояния
-- страницы (<script id='initial-state'>, путь videoClips.currentVideoClip.data),
-- которую VLC уже скачал до вызова parse() — лишних запросов нет.
-- Объект клипа ищется по id, поэтому смена пути в JSON плагин не сломает.
-- ---------------------------------------------------------------------------

local function read_page()
  local chunks = {}
  while true do
    local chunk = vlc.read(65536)
    if not chunk or chunk == "" then break end
    table.insert(chunks, chunk)
  end
  return table.concat(chunks)
end


local function has_player_urls(t)
  local urls = (t.data and type(t.data) == "table" and t.data[1] and t.data[1].playerUrls) or t.playerUrls
  return type(urls) == "table" and next(urls) ~= nil
end


-- Обход JSON в глубину: объект с id == clip_id и непустыми playerUrls
local function find_by_id(node, id, depth)
  if type(node) ~= "table" or depth > 12 then return nil end
  if node.id == id and has_player_urls(node) then return node end
  for _, child in pairs(node) do
    local found = find_by_id(child, id, depth + 1)
    if found then return found end
  end
  return nil
end


local function clip_from_page(clip_id)
  local html = read_page()
  -- тег вида <script type='text/plain' id='initial-state'> (кавычки любые)
  local state = html:match("<script[^>]-id=[\"']initial%-state[\"'][^>]*>(.-)</script>")
  if not state then
    vlc.msg.dbg(LOG.."initial-state not found in page ("..#html.." bytes)")
    return nil
  end
  local data = json.decode(state)
  if type(data) ~= "table" then
    vlc.msg.dbg(LOG.."initial-state is not valid JSON")
    return nil
  end
  local found = find_by_id(data, clip_id, 0)
  if not found then
    local keys = {}
    for k in pairs(data) do table.insert(keys, tostring(k)) end
    vlc.msg.dbg(LOG.."clip "..clip_id.." not in initial-state, top keys: "..table.concat(keys, ","))
  end
  return found
end


local function clip(channel, clip_id, start)
  local found = clip_from_page(clip_id)
  if not found then
    vlc.msg.err(LOG.."Clip not found: "..channel.."/clip/"..clip_id)
    return nil
  end
  return vod_item(found, start, CLIP_TYPES)
end


function probe()
  return (vlc.access == "http" or vlc.access == "https") and (
    vlc.path:match("^vkplay%.live/.+") or
    vlc.path:match("^live%.vkplay%.ru/.+") or
    vlc.path:match("^live%.vkvideo%.ru/.+") or
    is_ondemand_master()
  )
end


function parse()
  if is_ondemand_master() then
    local item = ondemand_variant()
    return item and { item } or {}
  end

  local channel, kind, id = match_all(vlc.path, "/([^/?#]+)")
  local start = start_time()

  local item
  if kind == "record" and id then
    item = records(channel, id, start)
  elseif kind == "clip" and id then
    item = clip(channel, id, start)
  else
    item = broadcast(channel)
  end

  return item and { item } or {}
end