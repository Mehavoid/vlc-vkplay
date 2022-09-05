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
local VKPlay = {}


VKPlay = {
  api_call = function(path)
    local data, _, err = get_json("https://api.vkplay.live/v1/blog/"..path)

    if err or data.error then
      vlc.msg.err(LOG..(err or data.error))
      return {}
    end

    return data
  end,

  stream = function(channel)
    local container = VKPlay.api_call(channel.."/public_video_stream?from=layer")

    local data = container.data

    if not data or #data == 0 then
      vlc.msg.info(LOG.."stream is currently offline")
      return container
    end

    local function callback(tab)
        return tab.type == "live_hls"
    end

    return {
      artist = container.daNick,
      description = container.category.title,
      name = container.title,
      path = filter(data[1].playerUrls, callback)[1].url,
    }
  end,
}

function probe()
  return (vlc.access == "http" or vlc.access == "https")
    and vlc.path:match("^vkplay%.live/.+")
end


function parse()
  local channel =
    vlc.path:match("^vkplay%.live/([^/?#]+)")

  local playlist = VKPlay.stream(channel)

  return { playlist, options = { ":http-referrer="..vlc.access.."://"..vlc.path } }
end
