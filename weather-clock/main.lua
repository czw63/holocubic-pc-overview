local APP_ID = "pc-weather-clock"
local SETTINGS_PATH = "/sd/apps/settings.json"
local PC_CONFIG_PATH = "/sd/apps/pc-overview/config.lua"
local WEATHER_ASSET = "S:/apps/weather/assets/icons/set2/"
local WEATHER_FONT_ZH_12 = "/sd/apps/weather/font/weather_ui_zh_cn_12.bin"
local WEATHER_FONT_ZH_16 = "/sd/apps/weather/font/weather_ui_zh_cn_16.bin"
local WEATHER_FONT_JA_12 = "/sd/apps/weather/font/weather_ui_ja_12.bin"
local WEATHER_FONT_JA_16 = "/sd/apps/weather/font/weather_ui_ja_16.bin"

if _G.__pc_weather_clock and _G.__pc_weather_clock.stop then
  pcall(_G.__pc_weather_clock.stop)
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function read_file(path)
  if not file or type(path) ~= "string" or path == "" then return nil end
  if file.getcontents then
    local ok, value = pcall(file.getcontents, path)
    if ok and type(value) == "string" then return value end
  end
  return nil
end

local function json_decode(raw)
  local codec = rawget(_G, "sjson") or rawget(_G, "json")
  if not codec or not codec.decode or type(raw) ~= "string" then return nil end
  local ok, value = pcall(codec.decode, raw)
  return ok and value or nil
end

local function url_encode(value)
  value = tostring(value or "")
  return value:gsub("([^%w%-_%.~])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end)
end

local function now_ms()
  if millis then
    local ok, value = pcall(millis)
    if ok and type(value) == "number" then return value end
  end
  return 0
end

local function load_config()
  local ok, config = pcall(dofile, PC_CONFIG_PATH)
  if ok and type(config) == "table" then return config end
  return { host = "192.168.1.100", port = 8088 }
end

local config = load_config()
local settings = json_decode(read_file(SETTINGS_PATH)) or {}
local weather_id = trim(settings.weather_location_id)
local weather_address = trim(settings.weather_address or settings.weatherAddress)
local weather_city = trim(settings.weather_city or settings.city_name or settings.city) or "--"
if weather_city == "" then weather_city = weather_address ~= "" and weather_address or "--" end

local state = {
  stopped = false,
  clock_timer = nil,
  poll_timer = nil,
  weather_timer = nil,
  weather_request = false,
  pc_request = false,
  weather = "--",
  temp = nil,
  icon = "999",
  zh12 = nil,
  zh16 = nil,
  root = nil,
  icon_img = nil,
  time_label = nil,
  city_label = nil,
  weather_label = nil,
  temp_label = nil,
  date_label = nil,
}

local MAIN_STYLE = (rawget(_G, "LV_PART_MAIN") or 0) | (rawget(_G, "LV_STATE_DEFAULT") or 0)
local ALIGN_LEFT = rawget(_G, "LV_TEXT_ALIGN_LEFT") or 0
local ALIGN_CENTER = rawget(_G, "LV_TEXT_ALIGN_CENTER") or 1
local ALIGN_RIGHT = rawget(_G, "LV_TEXT_ALIGN_RIGHT") or 2
local C = {
  bg = 0x000000,
  text = 0xF4F7FB,
  sub = 0x9FADB9,
  temp = 0xFFC65C,
  hot = 0xFF5D5D,
  line = 0x1C2832,
}

local function font_load(path)
  if not lv_font_load then return nil end
  local ok, value = pcall(lv_font_load, path)
  return ok and type(value) == "number" and value > 0 and value or nil
end

local function set_text(label, value, font)
  if not label or not lv_label_set_text then return end
  pcall(lv_label_set_text, label, tostring(value or ""))
  if font and lv_obj_set_style_text_font then
    pcall(lv_obj_set_style_text_font, label, font, MAIN_STYLE)
  end
end

local function make_label(parent, x, y, w, h, font, color, align)
  if not lv_label_create then return nil end
  local label = lv_label_create(parent)
  if lv_obj_set_pos then pcall(lv_obj_set_pos, label, x, y) end
  if lv_obj_set_size then pcall(lv_obj_set_size, label, w, h) end
  if lv_obj_set_style_text_color then pcall(lv_obj_set_style_text_color, label, color, MAIN_STYLE) end
  if lv_obj_set_style_text_align then pcall(lv_obj_set_style_text_align, label, align, MAIN_STYLE) end
  if lv_obj_set_style_bg_opa then pcall(lv_obj_set_style_bg_opa, label, 0, MAIN_STYLE) end
  set_text(label, "", font)
  return label
end

local function local_time()
  if time and time.getlocal then
    local ok, value = pcall(time.getlocal)
    if ok and type(value) == "table" then
      return string.format("%02d:%02d", tonumber(value.hour) or 0, tonumber(value.min) or 0),
        string.format("%04d/%02d/%02d", tonumber(value.year) or 2026,
          tonumber(value.mon or value.month) or 1, tonumber(value.day or value.mday) or 1)
    end
  end
  return os.date("%H:%M"), os.date("%Y/%m/%d")
end

local function update_clock()
  local clock, date = local_time()
  set_text(state.time_label, clock)
  set_text(state.date_label, date)
end

local function set_icon(code)
  code = tostring(code or "999")
  if state.icon == code then return end
  state.icon = code
  if state.icon_img and lv_img_set_src then
    pcall(lv_img_set_src, state.icon_img, WEATHER_ASSET .. code .. ".png")
  end
end

local function request_weather_now(location)
  if not http or not http.cubicserver or not http.cubicserver.get or state.weather_request then return end
  state.weather_request = true
  http.cubicserver.get("/v1/weather/now?location=" .. url_encode(location) .. "&unit=m&lang=zh",
    "Accept-Encoding: gzip\r\n", function(status, body)
      state.weather_request = false
      if state.stopped or status ~= 200 then return end
      local doc = json_decode(body)
      if type(doc) == "table" and type(doc.now) == "table" then
        state.temp = tonumber(doc.now.temp)
        state.weather = tostring(doc.now.text or "--")
        set_icon(doc.now.icon)
        set_text(state.temp_label, state.temp and string.format("%d°C", math.floor(state.temp + 0.5)) or "--°C", state.zh16)
        set_text(state.weather_label, state.weather, state.zh12)
      end
    end)
end

local function request_weather()
  if state.stopped or state.weather_request then return end
  if weather_id ~= "" then
    request_weather_now(weather_id)
    return
  end
  if weather_address == "" or not http or not http.cubicserver or not http.cubicserver.get then return end
  state.weather_request = true
  http.cubicserver.get("/v1/weather/cities?location=" .. url_encode(weather_address) .. "&number=1&lang=zh",
    "Accept-Encoding: gzip\r\n", function(status, body)
      state.weather_request = false
      if state.stopped or status ~= 200 then return end
      local doc = json_decode(body)
      local list = doc and (doc.locations or doc.location)
      local first = type(list) == "table" and list[1] or nil
      local id = type(first) == "table" and trim(first.id) or ""
      if id ~= "" then
        weather_id = id
        weather_city = trim(first.name) ~= "" and trim(first.name) or weather_city
        request_weather_now(id)
      end
    end)
end

local function poll_pc()
  if state.stopped or state.pc_request or not http then return end
  state.pc_request = true
  local host = trim(config.host)
  local port = tonumber(config.port) or 8088
  http.get("http://" .. host .. ":" .. port .. "/state", {}, function(status)
    state.pc_request = false
    if state.stopped then return end
    if status == 200 and app and app.launch then
      pcall(app.launch, "pc-overview")
      state.stopped = true
    end
  end)
end

local function build_ui()
  local root = lv_scr_act()
  state.root = root
  if lv_clear then lv_clear() elseif lv_obj_clean then lv_obj_clean(root) end
  if lv_obj_set_style_bg_color then pcall(lv_obj_set_style_bg_color, root, C.bg, MAIN_STYLE) end
  if lv_obj_set_style_bg_opa then pcall(lv_obj_set_style_bg_opa, root, 255, MAIN_STYLE) end

  state.zh12 = font_load(WEATHER_FONT_ZH_12)
  state.zh16 = font_load(WEATHER_FONT_ZH_16)
  local ja12 = font_load(WEATHER_FONT_JA_12)
  local ja16 = font_load(WEATHER_FONT_JA_16)
  state.zh12 = state.zh12 or ja12
  state.zh16 = state.zh16 or ja16

  state.time_label = make_label(root, 8, 86, 304, 58, nil, C.text, ALIGN_CENTER)
  state.city_label = make_label(root, 118, 8, 190, 22, state.zh12, C.text, ALIGN_RIGHT)
  state.weather_label = make_label(root, 52, 78, 170, 22, state.zh12, C.sub, ALIGN_LEFT)
  state.temp_label = make_label(root, 52, 48, 118, 30, state.zh16, C.temp, ALIGN_LEFT)
  state.date_label = make_label(root, 8, 178, 304, 24, nil, C.sub, ALIGN_CENTER)
  local offline = make_label(root, 12, 10, 90, 18, nil, C.hot, ALIGN_LEFT)
  set_text(offline, "OFFLINE")
  if lv_img_create then
    state.icon_img = lv_img_create(root)
    if lv_obj_set_pos then pcall(lv_obj_set_pos, state.icon_img, 18, 43) end
    if lv_img_set_zoom then pcall(lv_img_set_zoom, state.icon_img, 200) end
    if lv_img_set_src then pcall(lv_img_set_src, state.icon_img, WEATHER_ASSET .. "999.png") end
  end
  set_text(state.city_label, weather_city)
  set_text(state.temp_label, "--°C", state.zh16)
  set_text(state.weather_label, "--", state.zh12)
  update_clock()
end

local function stop()
  state.stopped = true
  for _, timer in pairs({ state.clock_timer, state.poll_timer, state.weather_timer }) do
    if timer then pcall(function() timer:unregister() end) end
  end
  if lv_font_free then
    if state.zh12 then pcall(lv_font_free, state.zh12) end
    if state.zh16 then pcall(lv_font_free, state.zh16) end
  end
end

_G.__pc_weather_clock = { stop = stop }
build_ui()
request_weather()
if tmr and tmr.create then
  state.clock_timer = tmr.create()
  state.clock_timer:alarm(1000, tmr.ALARM_AUTO, update_clock)
  state.poll_timer = tmr.create()
  state.poll_timer:alarm(1000, tmr.ALARM_AUTO, poll_pc)
  state.weather_timer = tmr.create()
  state.weather_timer:alarm(60000, tmr.ALARM_AUTO, request_weather)
end
