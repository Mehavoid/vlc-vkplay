local json = require("dkjson")

local LOG = "VKPlay: "


local function filter(tbl, callback)
  local filtered = {}

  for i, v in ipairs(tbl) do
    if callback(v, i, tbl) then table.insert(filtered, v) end
  end

  return filtered
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

  local lines = {}
  while true do
    local line = stream:readline()
    if not line then
      break
    end
    table.insert(lines, line)
  end

  local data, _, error = json.decode(table.concat(lines, "\n"))

  if not data then
    return nil, "JSON decode error: "..(error or "unknown error")
  end

  return data, nil
end


local function api_call(path)
  local data, error = get_json("https://api.live.vkvideo.ru/v1/blog/"..path)
  if not data then
    vlc.msg.err(LOG.."API call failed: "..error)
    return {}
  end
  return data
end


local function broadcast(channel)
  local container = api_call(channel.."/public_video_stream?from=layer")
  local data = container and container.data
  if not data then
    vlc.msg.err(LOG.."Stream is currently offline or no data")
    return nil
  end

  local playlist = filter(
    data[1].playerUrls or {},
    function(p) return p.type == "live_hls" end)[1]

  if not playlist then
    return nil
  end

  return {
    artist = container.user and container.user.nick,
    description = container.category and container.category.title,
    name = container.title,
    path = playlist.url,
  }
end


local function records(channel, record_id)
  local container = api_call(channel.."/public_video_stream/record/"..record_id)
  local record = container and container.data and container.data.record
  if not record then
    vlc.msg.err(LOG.."Record not found: "..record_id)
    return nil
  end

  local playlist = filter(
    record.data[1].playerUrls or {},
    function(p) return p.type == "full_hd" end)[1]

  if not playlist then
    return nil
  end

  return {
    artist = record.blog and record.blog.owner and record.blog.owner.displayName,
    description = record.category and record.category.title,
    name = record.title,
    path = playlist.url,
  }
end


function probe()
  return (vlc.access == "http" or vlc.access == "https") and (
    vlc.path:match("^vkplay%.live/.+") or
    vlc.path:match("^live%.vkplay%.ru/.+") or
    vlc.path:match("^live%.vkvideo%.ru/.+")
  )
end


function parse()
  local channel, _, record_id = match_all(vlc.path, "/([^/?#]+)")

  if not record_id then
    return { broadcast(channel) }
  else
    return { records(channel, record_id) }
  end
end
