local function contains(tab, key)
  return tab[key] ~= nil
end


local function ternary(condition, True, False)
  if condition then return True else return False end
end


local function filter(tab, callback)
  local filtered = {}

  for i, v in ipairs(tab) do
    if callback(v, i, tab) then table.insert(filtered, v) end
  end

  return filtered
end


local function get_json(url)
  local json = require("dkjson")
  local stream = vlc.stream(url)

  if not stream then
    return nil, nil, "Failed create vlc stream"
  end

  local string = ""

  while true do
    local line = stream:readline()

    if not line then
      break
    end

    string = string..line
  end

  return json.decode(string)
end


local LOG = "VKPlay: "


function api_call(path)
  local data, _, _ = get_json("https://api.vkplay.live/v1/blog/"..path)
  if data then
    return data
  end
  return { }
end


function broadcast(channel)
  local container = api_call(channel.."/public_video_stream?from=layer")
  local data = contains(container, "data") and container.data
  if not data then
    vlc.msg.err(LOG.."stream is currently offline")
    return data
  end

  local user = ternary(
    contains(container, "user"),
    container.user,
    {}
  )

  local artist = ternary(
    contains(user, "nick"),
    user.nick,
    ""
  )

  local category = ternary(
    contains(container, "category"),
    container.category,
    {}
  )

  local description = ternary(
    contains(category, 'title'),
    category.title,
    ""
  )

  local function callback(tbl)
      return tbl.type == "live_hls"
  end

  return {
    artist = artist,
    description = description,
    name = container.title,
    path = filter(data[1].playerUrls, callback)[1].url,
  }
end


function probe()
  return (vlc.access == "http" or vlc.access == "https")
    and vlc.path:match("^vkplay%.live/.+")
end


function parse()
  local channel =
    vlc.path:match("^vkplay%.live/([^/?#]+)")
  return { broadcast(channel) }
end
