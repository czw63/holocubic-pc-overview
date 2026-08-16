local APP_DIR = "/sd/apps/pc_overview"
local SETTINGS_PATH = "/sd/apps/settings.json"
local DEFAULT_WEATHER_LOCATION = "Shanghai"

if file and file.exists and not file.exists(APP_DIR .. "/config.lua") then
  local candidates = {
    "/sd/apps/pc-overview",
    "pc_overview/package",
    "pc_overview",
  }

  for _, dir in ipairs(candidates) do
    if file.exists(dir .. "/config.lua") then
      APP_DIR = dir
      break
    end
  end
end

if _G.__pc_overview and _G.__pc_overview.stop then
  pcall(_G.__pc_overview.stop)
end

local config = dofile(APP_DIR .. "/config.lua")
local PcWeb = nil

if file and file.exists and file.exists(APP_DIR .. "/web.lua") then
  local ok, mod = pcall(dofile, APP_DIR .. "/web.lua")
  if ok then
    PcWeb = mod
  else
    print("[pc-overview] web_load_error", mod)
  end
end

local MAIN_STYLE = (rawget(_G, "LV_PART_MAIN") or 0) | (rawget(_G, "LV_STATE_DEFAULT") or 0)
local ALIGN_LEFT = rawget(_G, "LV_TEXT_ALIGN_LEFT") or 0
local ALIGN_CENTER = rawget(_G, "LV_TEXT_ALIGN_CENTER") or 1
local ALIGN_RIGHT = rawget(_G, "LV_TEXT_ALIGN_RIGHT") or 2
local CANVAS_FMT = rawget(_G, "LV_IMG_CF_TRUE_COLOR") or rawget(_G, "CANVAS_FMT_TRUE_COLOR")

local C = {
  bg = 0x000000,
  panel = 0x000000,
  line = 0x1C2832,
  dim = 0x63707C,
  sub = 0x9FADB9,
  text = 0xF4F7FB,
  accent = tonumber(config.accent_color) or 0x35D0BA,
  cpu = tonumber(config.cpu_color) or 0x46C7FF,
  gpu = tonumber(config.gpu_color) or 0x62E493,
  mem = tonumber(config.mem_color) or 0xF2B84B,
  warn = 0xFFB454,
  hot = 0xFF5D5D,
}

local COVER_SIZE = 96
local SPECTRUM_BARS = 30
local SPECTRUM_XS = {}
do
  local slot = 300 / SPECTRUM_BARS
  for i = 1, SPECTRUM_BARS do
    SPECTRUM_XS[i] = math.floor((i - 1) * slot + 2)
  end
end

local S = {
  status = "WAITING",
  status_color = C.warn,
  last_seen_ms = 0,
  cpu = nil,
  gpu = nil,
  mem = nil,
  mem_used = nil,
  mem_total = nil,
  playing = false,
  media_status = "Stopped",
  title = "",
  artist = "",
  album = "",
  app = "",
  cover_version = nil,
  cover_loaded_version = nil,
  cover_data = nil,
  cover_inflight = false,
  cover_retry_ms = 0,
  spectrum = nil,
  spectrum_dirty = false,
  spectrum_frames = 0,
  spectrum_udp_frames = 0,
  spectrum_frame_len = 0,
  spectrum_smooth = {},
  weather_city = "--",
  weather_temp = nil,
  weather_text = "--",
  weather_code = "999",
  weather_inflight = false,
  ws_connected = false,
  ws_connecting = false,
  ws_connect_ms = 0,
  state_inflight = false,
  spectrum_inflight = false,
  state_due_ms = 0,
  spectrum_due_ms = 0,
  state_start_ms = 0,
  spectrum_start_ms = 0,
  full_redraw_ms = 0,
  title_shown = nil,
  artist_shown = nil,
  album_shown = nil,
  app_shown = nil,
}

local UI = {
  canvas = nil,
  spectrum_canvas = nil,
  title_label = nil,
  artist_label = nil,
  album_label = nil,
  app_label = nil,
  w = 320,
  h = 240,
}

local FONT_SMALL = rawget(_G, "LV_FONT_MONTSERRAT_8") or
  rawget(_G, "LV_FONT_MONTSERRAT_10") or 10

local CJK_FONTS = {
  zh_12 = nil,
  zh_16 = nil,
  ja_12 = nil,
  ja_16 = nil,
}
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local string_format = string.format

local state = {
  ws = nil,
  udp = nil,
  tick_timer = nil,
  spectrum_timer = nil,
  weather_timer = nil,
  reconnect_timer = nil,
  web = nil,
  stopped = false,
}

local redraw

local function log(...)
  if config.serial_log == false then
    return
  end
  print("[pc-overview]", ...)
end

local function call(fn, ...)
  if not fn then
    return false
  end
  return pcall(fn, ...)
end

local function now_ms()
  if type(millis) == "function" then
    local ok, value = pcall(millis)
    if ok and type(value) == "number" then
      return value
    end
  end
  if tmr and type(tmr.now) == "function" then
    local ok, value = pcall(function()
      return tmr.now()
    end)
    if ok and type(value) == "number" then
      return math_floor(value / 1000)
    end
  end
  return 0
end

local function clamp(value, min_value, max_value)
  value = tonumber(value)
  if not value then
    return nil
  end
  if value < min_value then return min_value end
  if value > max_value then return max_value end
  return value
end

local function clamp_pct(value)
  return clamp(value, 0, 100)
end

local function text_or(value, fallback)
  if value == nil then
    return fallback or ""
  end
  local text = tostring(value)
  if text == "" then
    return fallback or ""
  end
  return text
end

local function fmt_pct(value)
  value = tonumber(value)
  if not value then return "--%" end
  return string_format("%d%%", math_floor(value + 0.5))
end

local function fmt_gb(value)
  value = tonumber(value)
  if not value then return "--" end
  if value >= 100 then return string_format("%dG", math_floor(value + 0.5)) end
  return string_format("%.1fG", value)
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function read_text_file(path)
  if not file then return nil end
  if file.getcontents then
    local ok, raw = pcall(file.getcontents, path)
    if ok and type(raw) == "string" then return raw end
  end
  if not file.open then return nil end
  local fd = file.open(path, "r")
  if not fd then return nil end
  local chunks = {}
  while true do
    local part = fd:read(512)
    if not part or part == "" then break end
    chunks[#chunks + 1] = part
  end
  fd:close()
  return table.concat(chunks)
end

local function write_text_file(path, raw)
  if not file or type(raw) ~= "string" then return false end
  if file.putcontents then
    local ok, saved = pcall(file.putcontents, path, raw)
    if ok and saved then return true end
  end
  if not file.open then return false end
  local fd = file.open(path, "w")
  if not fd then return false end
  local ok = pcall(function() fd:write(raw) end)
  pcall(function() fd:close() end)
  return ok
end

local function decode_json(raw)
  local codec = rawget(_G, "sjson") or rawget(_G, "json")
  if not codec or not codec.decode or type(raw) ~= "string" then return nil end
  local ok, value = pcall(codec.decode, raw)
  return ok and value or nil
end

local function encode_json(value)
  local codec = rawget(_G, "sjson") or rawget(_G, "json")
  if not codec or not codec.encode then return nil end
  local ok, raw = pcall(codec.encode, value)
  return ok and type(raw) == "string" and raw or nil
end

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function decode_base64(text)
  text = tostring(text or ""):gsub("%s", "")
  local out = {}
  local n = 0
  local bits = 0
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch ~= "=" then
      local v = B64_CHARS:find(ch, 1, true)
      if v then
        v = v - 1
        n = n + 1
        bits = (bits << 6) | v
        if n == 4 then
          out[#out + 1] = string.char((bits >> 16) & 0xFF, (bits >> 8) & 0xFF, bits & 0xFF)
          n = 0
          bits = 0
        end
      end
    end
  end
  if n == 2 then
    out[#out + 1] = string.char((bits >> 10) & 0xFF)
  elseif n == 3 then
    out[#out + 1] = string.char((bits >> 16) & 0xFF, (bits >> 8) & 0xFF)
  end
  return table.concat(out)
end

local function url_encode(value)
  return (tostring(value or ""):gsub("([^%w%-_%.~])", function(ch)
    return string_format("%%%02X", string.byte(ch))
  end))
end

local function maybe_gunzip(body)
  if body and zlib and zlib.isgzip and zlib.isgzip(body) and zlib.gunzip then
    local ok, plain = pcall(zlib.gunzip, body)
    if ok and type(plain) == "string" then return plain end
  end
  return body
end

local function begin_frame(cvs)
  if lv_canvas_frame_begin then
    local ok = pcall(lv_canvas_frame_begin, cvs)
    return ok
  end
  if lv_canvas_begin then
    local ok = pcall(lv_canvas_begin, cvs)
    return ok
  end
  return false
end

local function end_frame(cvs, explicit)
  if explicit and lv_canvas_frame_end then
    pcall(lv_canvas_frame_end, cvs)
  elseif explicit and lv_canvas_end then
    pcall(lv_canvas_end, cvs)
  end
end

local function draw_rect(cvs, x, y, w, h, color, opa, radius, border_color, border_width)
  if not lv_canvas_draw_rect then return end
  local ok = pcall(lv_canvas_draw_rect, cvs, x, y, w, h, {
    bg_color = color,
    bg_opa = opa or 255,
    radius = radius or 0,
    border_width = border_width or 0,
    border_color = border_color or color,
    border_opa = border_width and (opa or 255) or 0,
  })
  if not ok then
    pcall(lv_canvas_draw_rect, cvs, x, y, w, h, color, opa or 255)
  end
end

local function draw_text(cvs, x, y, w, text, color, size, align, opa, font_handle)
  if not lv_canvas_draw_text then return end
  local ok = pcall(lv_canvas_draw_text, cvs, x, y, w, text_or(text, ""), {
    color = color or C.text,
    opa = opa or 255,
    align = align or ALIGN_LEFT,
    font_size = size or 12,
    font_handle = font_handle,
  })
  if not ok then
    pcall(lv_canvas_draw_text, cvs, x, y, w, text_or(text, ""), color or C.text, opa or 255, align or ALIGN_LEFT, size or 12)
  end
end

local function has_japanese(text)
  text = tostring(text or "")
  local i = 1
  while i <= #text do
    local b = text:byte(i)
    if b == 0xE3 then
      local b2 = text:byte(i + 1)
      if b2 == 0x81 or b2 == 0x82 or b2 == 0x83 then
        return true
      end
    end
    if b >= 0xF0 then
      i = i + 4
    elseif b >= 0xE0 then
      i = i + 3
    elseif b >= 0xC0 then
      i = i + 2
    else
      i = i + 1
    end
  end
  return false
end

local function pick_cjk_font(text, size)
  local jp = has_japanese(text)
  if size >= 15 then
    return (jp and CJK_FONTS.ja_16 or CJK_FONTS.zh_16)
      or (jp and CJK_FONTS.zh_16 or CJK_FONTS.ja_16)
  end
  return (jp and CJK_FONTS.ja_12 or CJK_FONTS.zh_12)
    or (jp and CJK_FONTS.zh_12 or CJK_FONTS.ja_12)
end

local function draw_cjk_text(cvs, x, y, w, text, color, size, align, opa)
  draw_text(cvs, x, y, w, text, color, size, align, opa, pick_cjk_font(text, size))
end

local function clean_app_name(value)
  local app = tostring(value or "")
  app = app:gsub("%.exe$", "")
  app = app:gsub("%.EXE$", "")
  app = app:match("([^/\\]+)$") or app
  return app
end

local function set_label_text(label, text, font_handle)
  if not label then return end
  pcall(lv_label_set_text, label, text)
  if font_handle and lv_obj_set_style_text_font then
    pcall(lv_obj_set_style_text_font, label, font_handle, MAIN_STYLE)
  end
end

local function make_label(x, y, w, h, color, align)
  if not lv_label_create then return nil end
  local id = lv_label_create(lv_scr_act())
  call(lv_obj_set_pos, id, x, y)
  call(lv_obj_set_size, id, w, h)
  if lv_obj_set_style_bg_opa then
    call(lv_obj_set_style_bg_opa, id, 0, MAIN_STYLE)
  end
  if lv_obj_set_style_pad_all then
    call(lv_obj_set_style_pad_all, id, 0, MAIN_STYLE)
  end
  call(lv_obj_set_style_text_color, id, color, MAIN_STYLE)
  if lv_obj_set_style_text_align then
    call(lv_obj_set_style_text_align, id, align or ALIGN_LEFT, MAIN_STYLE)
  end
  if lv_label_set_long_mode then
    local mode = rawget(_G, "LV_LABEL_LONG_SCROLL_CIRCULAR") or
      rawget(_G, "LV_LABEL_LONG_SCROLL") or
      rawget(_G, "LV_LABEL_LONG_CLIP")
    call(lv_label_set_long_mode, id, mode)
  end
  pcall(lv_label_set_text, id, "")
  return id
end

local function update_music_labels()
  if not UI.title_label then return end
  local title = S.title ~= "" and S.title or (S.playing and "NOW PLAYING" or "NO MUSIC")
  if S.title_shown ~= title then
    S.title_shown = title
    set_label_text(UI.title_label, title, pick_cjk_font(title, 16))
  end
  local artist = S.artist
  if S.artist_shown ~= artist then
    S.artist_shown = artist
    set_label_text(UI.artist_label, artist, pick_cjk_font(artist, 12))
  end
  local album = S.album
  if S.album_shown ~= album then
    S.album_shown = album
    set_label_text(UI.album_label, album, pick_cjk_font(album, 12))
  end
  local app = clean_app_name(S.app)
  if S.app_shown ~= app then
    S.app_shown = app
    set_label_text(UI.app_label, app, FONT_SMALL)
  end
end

local function draw_line(cvs, x1, y1, x2, y2, color, opa, width)
  if not lv_canvas_draw_line then return end
  x1, y1, x2, y2 = math_floor(x1 + 0.5), math_floor(y1 + 0.5), math_floor(x2 + 0.5), math_floor(y2 + 0.5)
  local ok = pcall(lv_canvas_draw_line, cvs, x1, y1, x2, y2, color, opa or 255, width or 1)
  if not ok then
    pcall(lv_canvas_draw_line, cvs, { { x = x1, y = y1 }, { x = x2, y = y2 } }, {
      color = color, opa = opa or 255, width = width or 1,
    })
  end
end

local function draw_arc_raw(cvs, cx, cy, r, start_deg, end_deg, color, opa, width)
  if not lv_canvas_draw_arc then return end
  local ok = pcall(lv_canvas_draw_arc, cvs, cx, cy, r, start_deg, end_deg, {
    color = color,
    opa = opa or 255,
    width = width or 4,
  })
  if not ok then
    pcall(lv_canvas_draw_arc, cvs, cx, cy, r, start_deg, end_deg, color, opa or 255, width or 4)
  end
end

local function norm_deg(deg)
  local n = deg % 360
  if n < 0 then n = n + 360 end
  return n
end

local function draw_arc_span(cvs, cx, cy, r, start_deg, span_deg, color, opa, width)
  span_deg = tonumber(span_deg) or 0
  if span_deg <= 0 then return end
  if span_deg >= 359 then
    draw_arc_raw(cvs, cx, cy, r, 0, 359, color, opa, width)
    return
  end
  local a1 = norm_deg(start_deg)
  local a2 = a1 + span_deg
  if a2 <= 360 then
    draw_arc_raw(cvs, cx, cy, r, math_floor(a1), math_floor(a2), color, opa, width)
  else
    draw_arc_raw(cvs, cx, cy, r, math_floor(a1), 359, color, opa, width)
    draw_arc_raw(cvs, cx, cy, r, 0, math_floor(a2 - 360), color, opa, width)
  end
end

local function draw_bar(cvs, x, y, w, h, pct, color)
  local value = clamp_pct(pct) or 0
  draw_rect(cvs, x, y, w, h, C.line, 255, h / 2)
  local fill_w = math_floor(w * value / 100 + 0.5)
  if fill_w > 0 then
    draw_rect(cvs, x, y, fill_w, h, color, 255, h / 2)
  end
end

local function utf8_length(text)
  text = tostring(text or "")
  local count = 0
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    if byte >= 0xF0 then
      count, i = count + 1, i + 4
    elseif byte >= 0xE0 then
      count, i = count + 1, i + 3
    elseif byte >= 0xC0 then
      count, i = count + 1, i + 2
    else
      count, i = count + 1, i + 1
    end
  end
  return count
end

local function utf8_prefix(text, max_chars)
  text = tostring(text or "")
  if utf8_length(text) <= max_chars then return text end
  local out = {}
  local count = 0
  local i = 1
  while i <= #text and count < max_chars do
    local byte = text:byte(i)
    if byte >= 0xF0 then
      out[#out + 1] = text:sub(i, i + 3)
      i = i + 4
    elseif byte >= 0xE0 then
      out[#out + 1] = text:sub(i, i + 2)
      i = i + 3
    elseif byte >= 0xC0 then
      out[#out + 1] = text:sub(i, i + 1)
      i = i + 2
    else
      out[#out + 1] = text:sub(i, i)
      i = i + 1
    end
    count = count + 1
  end
  return table.concat(out)
end

local function weather_text_width(text)
  local width, i = 0, 1
  text = tostring(text or "")
  while i <= #text do
    local byte = text:byte(i)
    if byte >= 0xE0 then
      width, i = width + 13, i + 3
    elseif byte >= 0xC0 then
      width, i = width + 10, i + 2
    else
      local ch = text:sub(i, i)
      width = width + ((ch == " ") and 3 or ((ch == "/") and 5 or 6))
      i = i + 1
    end
  end
  return width
end

local function dashboard_clock()
  if time and time.getlocal then
    local ok, cal = pcall(time.getlocal)
    if ok and type(cal) == "table" then
      local year = tonumber(cal.year or cal.tm_year) or 2026
      local mon = tonumber(cal.mon or cal.month) or 1
      local day = tonumber(cal.day or cal.mday) or 1
      local hour = tonumber(cal.hour or cal.tm_hour) or 0
      local min = tonumber(cal.min or cal.minute) or 0
      local wday = tonumber(cal.wday)
      if not wday or wday < 1 or wday > 7 then
        local offsets = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
        local y = mon < 3 and year - 1 or year
        wday = (y + math_floor(y / 4) - math_floor(y / 100) + math_floor(y / 400) + offsets[mon] + day) % 7 + 1
      end
      local weekdays = { "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" }
      return string_format("%02d:%02d", hour, min),
        string_format("%s %02d/%02d", weekdays[wday] or "---", mon, day)
    end
  end
  if rtctime and rtctime.get and rtctime.epoch2cal then
    local ok_sec, sec = pcall(rtctime.get)
    if ok_sec and type(sec) == "number" and sec > 0 then
      local ok, year, mon, day, hour, min = pcall(rtctime.epoch2cal, sec + 8 * 3600)
      if ok and year and hour and min then
        return string_format("%02d:%02d", hour, min),
          string_format("%02d/%02d", mon or 1, day or 1)
      end
    end
  end
  if os and os.date then
    local ok_time, clock = pcall(os.date, "%H:%M")
    local ok_date, date = pcall(os.date, "%m/%d")
    if ok_time and ok_date then return clock, date end
  end
  return "--:--", "--/--"
end

local function weather_icon(cvs, x, y, code)
  code = tostring(code or "999")
  local is_rain = code:match("^3") ~= nil
  local is_snow = code:match("^4") ~= nil
  local is_storm = code == "302" or code == "303" or code == "304"
  local is_sunny = code == "100" or code == "150"
  local is_partly = code == "101" or code == "102" or code == "103" or
    code == "151" or code == "152" or code == "153"
  local is_fog = code:match("^5") ~= nil
  if is_sunny then
    draw_arc_span(cvs, x + 7, y + 7, 4, 0, 359, 0xFFB22E, 255, 1)
    for a = 0, 315, 45 do
      local r = a * math.pi / 180
      draw_line(cvs, x + 7 + math.cos(r) * 6, y + 7 + math.sin(r) * 6,
        x + 7 + math.cos(r) * 8, y + 7 + math.sin(r) * 8, 0xFFB22E, 255, 1)
    end
    return
  end
  if is_fog then
    draw_arc_span(cvs, x + 7, y + 5, 4, 190, 160, 0xD7E7F5, 255, 1)
    draw_line(cvs, x + 2, y + 9, x + 14, y + 9, 0xD7E7F5, 255, 1)
    draw_line(cvs, x, y + 12, x + 11, y + 12, 0x91A9BC, 255, 1)
    draw_line(cvs, x + 4, y + 15, x + 16, y + 15, 0x91A9BC, 255, 1)
    return
  end
  if is_partly then
    draw_arc_span(cvs, x + 5, y + 5, 3, 0, 359, 0xFFB22E, 255, 1)
    draw_line(cvs, x + 5, y, x + 5, y + 2, 0xFFB22E, 255, 1)
    draw_line(cvs, x, y + 5, x + 2, y + 5, 0xFFB22E, 255, 1)
  end
  draw_arc_span(cvs, x + 5, y + 7, 4, 190, 170, 0xD7E7F5, 255, 1)
  draw_arc_span(cvs, x + 10, y + 7, 5, 180, 180, 0xD7E7F5, 255, 1)
  draw_line(cvs, x + 2, y + 10, x + 15, y + 10, 0xD7E7F5, 255, 1)
  if is_storm then
    draw_line(cvs, x + 9, y + 11, x + 6, y + 15, 0xFFD43B, 255, 1)
    draw_line(cvs, x + 6, y + 15, x + 10, y + 14, 0xFFD43B, 255, 1)
  elseif is_rain then
    draw_line(cvs, x + 5, y + 12, x + 4, y + 15, 0x46C7FF, 255, 1)
    draw_line(cvs, x + 10, y + 12, x + 9, y + 15, 0x46C7FF, 255, 1)
  elseif is_snow then
    draw_line(cvs, x + 4, y + 12, x + 6, y + 15, 0xEAF7FF, 255, 1)
    draw_line(cvs, x + 9, y + 12, x + 11, y + 15, 0xEAF7FF, 255, 1)
  end
end

local function draw_music_placeholder(cvs, x, y, size)
  draw_rect(cvs, x + size * 0.18, y + size * 0.24, 5, size * 0.42, C.accent, 220, 1)
  draw_arc_span(cvs, x + size * 0.23, y + size * 0.66, size * 0.10, 0, 359, C.accent, 220, 3)
  for i, h in ipairs({ 0.20, 0.34, 0.46, 0.30, 0.16 }) do
    local bx = x + size * (0.56 + (i - 1) * 0.075)
    local bh = math_floor(size * h)
    draw_rect(cvs, math_floor(bx), y + size * 0.72 - bh, 4, bh, C.sub, 170, 1)
  end
end

local function draw_cover(cvs)
  local x, y = 10, 42
  draw_rect(cvs, x, y, COVER_SIZE, COVER_SIZE, C.panel, 255, 8)
  draw_rect(cvs, x + 1, y + 1, COVER_SIZE - 2, COVER_SIZE - 2, 0x0B1116, 255, 7)
  if S.cover_data and #S.cover_data >= COVER_SIZE * COVER_SIZE * 2 then
    local ok = pcall(lv_canvas_blit_rgb565, cvs, x, y, COVER_SIZE, COVER_SIZE,
      S.cover_data, { byte_order = "little" })
    if not ok then
      pcall(lv_canvas_blit_rgb565, cvs, x, y, COVER_SIZE, COVER_SIZE, S.cover_data)
    end
  else
    draw_music_placeholder(cvs, x, y, COVER_SIZE)
  end
  draw_line(cvs, x, y, x + COVER_SIZE, y, C.line, 255, 1)
  draw_line(cvs, x + COVER_SIZE, y, x + COVER_SIZE, y + COVER_SIZE, C.line, 255, 1)
  draw_line(cvs, x + COVER_SIZE, y + COVER_SIZE, x, y + COVER_SIZE, C.line, 255, 1)
  draw_line(cvs, x, y + COVER_SIZE, x, y, C.line, 255, 1)
end

local function draw_music(cvs)
  local playing = S.playing
  local status_text = S.media_status ~= "" and S.media_status or (playing and "PLAYING" or "STOPPED")
  local status_color = playing and C.gpu or C.dim
  draw_cjk_text(cvs, 246, 108, 66, utf8_prefix(status_text, 10), status_color, 8, ALIGN_RIGHT, 255)
end

local function draw_system_cell(cvs, x, label, value, color, pct, caption)
  draw_text(cvs, x, 146, 92, label, C.sub, 10, ALIGN_LEFT, 255)
  draw_text(cvs, x + 34, 144, 58, value, C.text, 16, ALIGN_RIGHT, 255)
  draw_bar(cvs, x, 166, 92, 6, pct, color)
  draw_text(cvs, x, 176, 92, caption or "", C.dim, 8, ALIGN_LEFT, 255)
end

local function draw_system(cvs)
  draw_system_cell(cvs, 10, "CPU", fmt_pct(S.cpu), C.cpu, S.cpu, "")
  draw_system_cell(cvs, 114, "GPU", fmt_pct(S.gpu), C.gpu, S.gpu, "")
  local mem_caption = ""
  if S.mem_used and S.mem_total then
    mem_caption = fmt_gb(S.mem_used) .. "/" .. fmt_gb(S.mem_total)
  end
  draw_system_cell(cvs, 218, "RAM", fmt_pct(S.mem), C.mem, S.mem, mem_caption)
end

local function draw_spectrum(cvs)
  if lv_canvas_draw_rect then
    pcall(lv_canvas_draw_rect, cvs, 0, 0, 300, 46, C.panel, 220)
  end
  local live = S.spectrum ~= nil and #S.spectrum >= 4
  draw_text(cvs, 6, 3, 90, "SPECTRUM", C.dim, 8, ALIGN_LEFT, 255)
  local status = live and "LIVE" or "WAITING"
  draw_text(cvs, 240, 3, 54, status, live and C.accent or C.dim, 8, ALIGN_RIGHT, 255)

  local max_h = 30
  local base_y = 44
  local draw_line_fn = lv_canvas_draw_line
  for i = 1, SPECTRUM_BARS do
    local raw = live and S.spectrum[i] or 0
    raw = clamp(raw, 0, 1) or 0
    local smooth = S.spectrum_smooth[i] or 0
    smooth = smooth * 0.25 + raw * 0.75
    S.spectrum_smooth[i] = smooth
    local h = math_floor(smooth * max_h + 0.5)
    local color = C.accent
    if smooth >= 0.78 then
      color = C.hot
    elseif smooth >= 0.5 then
      color = C.warn
    end
    if h > 0 and draw_line_fn then
      local x = SPECTRUM_XS[i]
      draw_line_fn(cvs, x + 2, base_y, x + 2, base_y - h, color, 200, 5)
    end
  end
end

local function redraw_spectrum()
  if not UI.spectrum_canvas then return end
  local frame = begin_frame(UI.spectrum_canvas)
  if lv_canvas_fill_bg then
    pcall(lv_canvas_fill_bg, UI.spectrum_canvas, C.bg, 255)
  elseif lv_canvas_fill then
    pcall(lv_canvas_fill, UI.spectrum_canvas, C.bg, 255)
  end
  draw_spectrum(UI.spectrum_canvas)
  end_frame(UI.spectrum_canvas, frame)
  S.spectrum_dirty = false
end

local function draw_header(cvs)
  local clock, date = dashboard_clock()
  draw_text(cvs, 10, 2, 96, clock, C.text, 28, ALIGN_LEFT, 255)
  draw_text(cvs, 10, 31, 104, date, C.dim, 8, ALIGN_LEFT, 255)

  local weather = S.weather_city .. " " .. S.weather_text .. " " ..
    (S.weather_temp and tostring(math_floor(S.weather_temp + 0.5)) .. "\194\176C" or "--\194\176C")
  weather_icon(cvs, 184, 7, S.weather_code)
  draw_cjk_text(cvs, 202, 7, 110, weather, 0xFFC65C, 12, ALIGN_LEFT, 255)
end

redraw = function()
  if not UI.canvas then return end
  local frame = begin_frame(UI.canvas)
  if lv_canvas_fill_bg then
    pcall(lv_canvas_fill_bg, UI.canvas, C.bg, 255)
  elseif lv_canvas_fill then
    pcall(lv_canvas_fill, UI.canvas, C.bg, 255)
  end
  draw_header(UI.canvas)
  draw_cover(UI.canvas)
  draw_music(UI.canvas)
  draw_system(UI.canvas)
  local status_color = S.status == "LIVE" and C.gpu or S.status_color
  draw_text(UI.canvas, 118, 124, 180, S.status, status_color, 8, ALIGN_LEFT, 255)
  end_frame(UI.canvas, frame)
  redraw_spectrum()
  update_music_labels()
end

local function save_weather_location(raw_location, location_id, city)
  local doc = decode_json(read_text_file(SETTINGS_PATH)) or {}
  local current_address = trim(doc.weather_address or doc.weatherAddress)
  if current_address ~= raw_location then return false end
  doc.weather_location_address = raw_location
  doc.weather_location_id = location_id
  if city ~= "" then doc.weather_city = city end
  local encoded = encode_json(doc)
  return encoded ~= nil and write_text_file(SETTINGS_PATH, encoded)
end

local function load_weather_location()
  local doc = decode_json(read_text_file(SETTINGS_PATH)) or {}
  local raw = trim(doc.weather_address or doc.weatherAddress)
  if raw == "" and trim(config.weather_location) ~= "" then
    raw = trim(config.weather_location)
  end
  if raw == "" then
    raw = DEFAULT_WEATHER_LOCATION
    doc.weather_address = raw
    doc.weather_location_address = nil
    doc.weather_location_raw = nil
    doc.weather_location_id = nil
    doc.weather_city = nil
    local encoded = encode_json(doc)
    if not encoded or not write_text_file(SETTINGS_PATH, encoded) then
      log("default weather address write failed", SETTINGS_PATH)
    end
  end
  local cached_address = trim(doc.weather_location_address or doc.weather_location_raw)
  local location = trim(doc.weather_location_id)
  if location ~= "" and cached_address ~= "" and cached_address ~= raw then
    location = ""
  end
  if location == "" and raw:match("^%d+$") then location = raw end
  local city = raw
  if cached_address == "" or cached_address == raw then
    city = trim(doc.weather_city or doc.city_name or doc.city)
    if city == "" then city = raw end
  end
  S.weather_city = city ~= "" and city or "Weather"
  if type(doc.timezone) == "string" and doc.timezone ~= "" and time and time.settimezone then
    pcall(time.settimezone, doc.timezone)
  elseif time and time.settimezone and trim(config.timezone) ~= "" then
    pcall(time.settimezone, config.timezone)
  end
  return location, raw
end

local function request_weather_for(location)
  local url = "/v1/weather/now?location=" .. url_encode(location) .. "&unit=m&lang=zh"
  http.cubicserver.get(url, "Accept-Encoding: gzip\r\n", function(status_code, body)
    S.weather_inflight = false
    if state.stopped or status_code ~= 200 then return end
    local doc = decode_json(maybe_gunzip(body))
    local now = doc and doc.now
    if tostring(doc and doc.code or "") == "200" and type(now) == "table" then
      S.weather_temp = tonumber(now.temp)
      S.weather_text = text_or(now.text, "--")
      S.weather_code = text_or(now.icon, "999")
      redraw()
    end
  end)
end

local function request_weather()
  if S.weather_inflight or not http or not http.cubicserver or not http.cubicserver.get then return end
  local location, raw_location = load_weather_location()
  if location ~= "" then
    S.weather_inflight = true
    request_weather_for(location)
    return
  end
  if raw_location == "" then return end

  S.weather_inflight = true
  local url = "/v1/weather/cities?location=" .. url_encode(raw_location) .. "&number=1&lang=zh"
  http.cubicserver.get(url, "Accept-Encoding: gzip\r\n", function(status_code, body)
    if state.stopped then return end
    local doc = status_code == 200 and decode_json(maybe_gunzip(body)) or nil
    local locations = doc and (doc.locations or doc.location)
    local first = tostring(doc and doc.code or "") == "200"
      and type(locations) == "table" and locations[1] or nil
    local location_id = type(first) == "table" and trim(first.id) or ""
    if location_id == "" then
      S.weather_inflight = false
      return
    end
    local city = trim(first.name)
    if city ~= "" then S.weather_city = city end
    save_weather_location(raw_location, location_id, city)
    request_weather_for(location_id)
  end)
end

local function base_url()
  return "http://" .. trim(config.host) .. ":" .. tostring(tonumber(config.port) or 8088)
end

local function handle_state(doc)
  if type(doc) ~= "table" then return end
  S.cpu = clamp_pct(doc.cpu)
  S.gpu = clamp_pct(doc.gpu)
  S.mem = clamp_pct(doc.mem)
  S.mem_used = tonumber(doc.mem_used)
  S.mem_total = tonumber(doc.mem_total)
  S.title = text_or(doc.title, "")
  S.artist = text_or(doc.artist, "")
  S.album = text_or(doc.album, "")
  S.app = text_or(doc.app, "")
  S.media_status = text_or(doc.status, "Stopped")
  S.playing = doc.playing == true or tostring(S.media_status):lower():find("play") ~= nil
  if doc.cover_version ~= nil then
    S.cover_version = tonumber(doc.cover_version) or S.cover_version
  end
  S.last_seen_ms = now_ms()
  S.status = "LIVE"
  S.status_color = C.gpu
end

local function handle_ws_message(payload)
  if type(payload) ~= "string" or payload == "" then return end
  local doc = decode_json(payload)
  if type(doc) ~= "table" then return end
  local kind = tostring(doc.type or "")
  if kind == "state" then
    handle_state(doc)
  elseif kind == "spectrum" and config.spectrum ~= false then
    if type(doc.bins) == "table" then
      S.spectrum = doc.bins
      S.spectrum_dirty = true
    end
  end
end

local function handle_spectrum_binary(payload)
  if config.spectrum == false or type(payload) ~= "string" or #payload < 2 then return end
  local bins = S.spectrum
  if type(bins) ~= "table" then
    bins = {}
  end
  local n = math_min(SPECTRUM_BARS, #payload)
  for i = 1, n do
    bins[i] = (payload:byte(i) or 0) / 255
  end
  for i = n + 1, #bins do
    bins[i] = 0
  end
  S.spectrum = bins
  S.spectrum_frames = (S.spectrum_frames or 0) + 1
  S.spectrum_frame_len = #payload
  S.spectrum_dirty = true
end

local function connect_ws()
  if state.stopped or S.ws_connecting or S.ws_connected then return end
  if not websocket or not websocket.createClient then
    S.status = "HTTP MODE"
    S.status_color = C.warn
    return
  end
  S.ws_connecting = true
  S.ws_connect_ms = now_ms()
  local ok, client_or_err = pcall(function()
    return websocket.createClient()
  end)
  if not ok or not client_or_err then
    S.ws_connecting = false
    log("ws_create_error", client_or_err)
    return
  end
  local client = client_or_err
  state.ws = client

  local ok_conn = pcall(function()
    client:on("connection", function(...)
      S.ws_connecting = false
      S.ws_connect_ms = 0
      S.ws_connected = true
      S.status = "LIVE"
      S.status_color = C.gpu
      S.last_seen_ms = now_ms()
      log("ws_connected")
      pcall(function()
        client:send("{\"type\":\"hello\"}", websocket.TEXT)
      end)
    end)
  end)
  if not ok_conn then log("ws_bind_connection_error") end

  local ok_recv = pcall(function()
    client:on("receive", function(...)
      local payload
      local opcode
      for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "string" and payload == nil then
          payload = value
        end
        if type(value) == "number" and (value == 1 or value == 2) and opcode == nil then
          opcode = value
        end
      end
      local binary = opcode == 2 or
        (websocket and websocket.BINARY ~= nil and opcode == websocket.BINARY)
      local ok_handle = binary and pcall(handle_spectrum_binary, payload) or
        pcall(handle_ws_message, payload)
      if not ok_handle then log("ws_message_error") end
    end)
  end)
  if not ok_recv then log("ws_bind_receive_error") end

  local ok_close = pcall(function()
    client:on("close", function(...)
      S.ws_connecting = false
      S.ws_connect_ms = 0
      S.ws_connected = false
      S.status = "OFFLINE"
      S.status_color = C.hot
      log("ws_closed")
    end)
  end)
  if not ok_close then log("ws_bind_close_error") end

  local url = "ws://" .. trim(config.host) .. ":" .. tostring(tonumber(config.port) or 8088) .. "/ws"
  local ok_go = pcall(function()
    client:connect(url)
  end)
  if not ok_go then
    S.ws_connecting = false
    log("ws_connect_error", url)
  end
end

local function stop_ws()
  if state.ws then
    local client = state.ws
    state.ws = nil
    pcall(function()
      client:on("receive", nil)
      client:on("connection", nil)
      client:on("close", nil)
      client:close()
    end)
  end
  S.ws_connecting = false
  S.ws_connect_ms = 0
  S.ws_connected = false
end

local function fetch_cover()
  if config.cover == false then return end
  if S.cover_inflight or S.cover_version == nil then return end
  if S.cover_loaded_version == S.cover_version then return end
  if now_ms() < S.cover_retry_ms then return end
  S.cover_inflight = true
  local url = base_url() .. "/cover64?version=" .. tostring(S.cover_version)
  http.get(url, {}, function(status_code, body)
    S.cover_inflight = false
    if state.stopped then return end
    local doc = status_code == 200 and decode_json(body) or nil
    local data = type(doc) == "table" and doc.data or nil
    local raw = type(data) == "string" and decode_base64(data) or nil
    if raw and #raw >= COVER_SIZE * COVER_SIZE * 2 then
      S.cover_data = raw
      S.cover_loaded_version = S.cover_version
      redraw()
    else
      S.cover_retry_ms = now_ms() + 5000
    end
  end)
end

local function http_poll()
  if not http then return end
  local now = now_ms()
  if S.state_inflight then return end
  S.state_inflight = true
  S.state_start_ms = now_ms()
  http.get(base_url() .. "/state", {}, function(status_code, body)
    S.state_inflight = false
    S.state_start_ms = 0
    if state.stopped or status_code ~= 200 then return end
    handle_state(decode_json(body))
  end)
end

local function http_spectrum_poll()
  if not http then return end
  if config.spectrum == false then return end
  if S.spectrum_inflight then return end
  S.spectrum_inflight = true
  S.spectrum_start_ms = now_ms()
  http.get(base_url() .. "/spectrum", {}, function(status_code, body)
    S.spectrum_inflight = false
    S.spectrum_start_ms = 0
    if state.stopped or status_code ~= 200 then return end
    local doc = decode_json(body)
    if type(doc) == "table" and type(doc.bins) == "table" then
      S.spectrum = doc.bins
      S.spectrum_dirty = true
    end
  end)
end

local function update_stale_status()
  if S.last_seen_ms <= 0 then return end
  if now_ms() - S.last_seen_ms > (config.stale_ms or 5000) and S.status == "LIVE" then
    S.status = "STALE"
    S.status_color = C.warn
  end
end

local function start_tick()
  if not tmr or not tmr.create then return end
  state.tick_timer = tmr.create()
  local interval = math_max(30, math_min(80, tonumber(config.refresh_ms) or 33))
  local full_interval = tonumber(config.full_refresh_ms)
  if not full_interval or full_interval <= 0 then
    full_interval = 500
  end
  state.tick_timer:alarm(interval, tmr.ALARM_AUTO, function()
    if state.stopped then return end
    update_stale_status()
    if S.ws_connected and now_ms() - S.last_seen_ms > (config.stale_ms or 5000) then
      S.status = "STALE"
      S.status_color = C.warn
      stop_ws()
    end
    if not S.ws_connected and not S.ws_connecting and websocket then
      connect_ws()
    end
    if S.ws_connecting and S.ws_connect_ms > 0 and now_ms() - S.ws_connect_ms > (config.timeout_ms or 6000) then
      stop_ws()
    end
    if not websocket then
      local now = now_ms()
      if S.state_inflight and S.state_start_ms > 0 and now - S.state_start_ms > 3000 then
        S.state_inflight = false
        S.state_start_ms = 0
      end
      if now >= S.state_due_ms then
        S.state_due_ms = now + 1000
        http_poll()
      end
    end
    if config.spectrum ~= false and (not websocket or not S.ws_connected) then
      local now = now_ms()
      if S.spectrum_inflight and S.spectrum_start_ms > 0 and now - S.spectrum_start_ms > 3000 then
        S.spectrum_inflight = false
        S.spectrum_start_ms = 0
      end
      if now >= S.spectrum_due_ms then
        S.spectrum_due_ms = now + 300
        http_spectrum_poll()
      end
    end
    fetch_cover()
    update_music_labels()
    local now = now_ms()
    if now >= S.full_redraw_ms then
      S.full_redraw_ms = now + full_interval
      redraw()
    elseif not state.spectrum_timer then
      redraw_spectrum()
    end
  end)
end

local function start_spectrum_timer()
  if not tmr or not tmr.create or config.spectrum == false then return end
  state.spectrum_timer = tmr.create()
  state.spectrum_timer:alarm(20, tmr.ALARM_AUTO, function()
    if state.stopped then return end
    if S.spectrum_dirty and UI.spectrum_canvas then
      redraw_spectrum()
    end
  end)
end

local function stop_udp()
  local sock = state.udp
  state.udp = nil
  if not sock then return end
  pcall(function() sock:on("receive", nil) end)
  pcall(function() sock:close() end)
end

local function start_udp()
  if config.spectrum == false or state.udp then return end
  if not net or not net.createUDPSocket then
    log("udp_unavailable")
    return
  end
  local ok, sock = pcall(net.createUDPSocket)
  if not ok or not sock then
    log("udp_create_error", sock)
    return
  end
  state.udp = sock
  local ok_bind = pcall(function()
    sock:on("receive", function(...)
      local payload
      for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "string" and payload == nil then
          payload = value
        end
      end
      if payload then
        pcall(handle_spectrum_binary, payload)
        S.spectrum_udp_frames = (S.spectrum_udp_frames or 0) + 1
      end
    end)
    sock:listen(tonumber(config.udp_port) or 8090)
  end)
  if not ok_bind then
    log("udp_listen_error")
    stop_udp()
  else
    log("udp_listen", tostring(tonumber(config.udp_port) or 8090))
  end
end

local function load_cjk_fonts()
  if not lv_font_load then return end
  local function load_one(path)
    local ok, handle = pcall(lv_font_load, path)
    if ok and type(handle) == "number" and handle > 0 then
      return handle
    end
    return nil
  end
  CJK_FONTS.zh_12 = load_one("/sd/apps/weather/font/weather_ui_zh_cn_12.bin")
  CJK_FONTS.zh_16 = load_one("/sd/apps/weather/font/weather_ui_zh_cn_16.bin")
  CJK_FONTS.ja_12 = load_one("/sd/apps/weather/font/weather_ui_ja_12.bin")
  CJK_FONTS.ja_16 = load_one("/sd/apps/weather/font/weather_ui_ja_16.bin")
end

local function start_weather()
  request_weather()
  if not tmr or not tmr.create then return end
  state.weather_timer = tmr.create()
  state.weather_timer:alarm(60000, tmr.ALARM_AUTO, function()
    if not state.stopped then request_weather() end
  end)
end

local function build_ui()
  local root = lv_scr_act()
  if lv_obj_clean then
    lv_obj_clean(root)
  elseif lv_clear then
    lv_clear()
  end

  call(lv_obj_set_style_bg_color, root, C.bg, MAIN_STYLE)
  call(lv_obj_set_style_bg_opa, root, 255, MAIN_STYLE)
  if lv_obj_clear_flag and rawget(_G, "LV_OBJ_FLAG_SCROLLABLE") then
    call(lv_obj_clear_flag, root, rawget(_G, "LV_OBJ_FLAG_SCROLLABLE"))
  end

  if lv_canvas_create then
    if CANVAS_FMT then
      UI.canvas = lv_canvas_create(root, UI.w, UI.h, CANVAS_FMT)
    else
      UI.canvas = lv_canvas_create(root, UI.w, UI.h)
    end
    call(lv_obj_set_pos, UI.canvas, 0, 0)

    if CANVAS_FMT then
      UI.spectrum_canvas = lv_canvas_create(root, 300, 46, CANVAS_FMT)
    else
      UI.spectrum_canvas = lv_canvas_create(root, 300, 46)
    end
    call(lv_obj_set_pos, UI.spectrum_canvas, 10, 186)
  end

  UI.title_label = make_label(118, 48, 194, 22, C.text, ALIGN_LEFT)
  UI.artist_label = make_label(118, 70, 194, 18, C.sub, ALIGN_LEFT)
  UI.album_label = make_label(118, 90, 194, 18, C.dim, ALIGN_LEFT)
  UI.app_label = make_label(118, 108, 116, 14, C.dim, ALIGN_LEFT)
  set_label_text(UI.app_label, "", FONT_SMALL)
end

function state.stop()
  state.stopped = true
  stop_ws()
  stop_udp()

  if state.web then
    state.web:stop("app_stop")
  end

  if state.tick_timer then
    state.tick_timer:unregister()
    state.tick_timer = nil
  end
  if state.spectrum_timer then
    state.spectrum_timer:unregister()
    state.spectrum_timer = nil
  end
  if state.weather_timer then
    state.weather_timer:unregister()
    state.weather_timer = nil
  end
  if state.reconnect_timer then
    state.reconnect_timer:unregister()
    state.reconnect_timer = nil
  end

  if key and key.off then
    key.off()
  end
  if lv_font_free then
    for _, handle in pairs(CJK_FONTS) do
      if handle then
        pcall(lv_font_free, handle)
      end
    end
  end
  for key in pairs(CJK_FONTS) do
    CJK_FONTS[key] = nil
  end
end

if key and key.on and key.HOME then
  key.on(key.HOME, function(evt_type)
    if evt_type == key.SHORT then
      state.stop()
      if app and app.exit then
        app.exit()
      end
    end
  end)
end

_G.__pc_overview = state
load_cjk_fonts()
build_ui()
redraw()
start_tick()
start_spectrum_timer()
start_udp()
start_weather()

if PcWeb and PcWeb.new then
  state.web = PcWeb.new({
    config = config,
    config_path = APP_DIR .. "/config.lua",
    route_base = (app and app.route_base and app.route_base()) or "/pc_overview",
    snapshot_extra = function()
      return {
        cover_version = S.cover_version,
        cover_loaded = S.cover_loaded_version,
        cover_bytes = #(S.cover_data or ""),
        cover_inflight = S.cover_inflight,
        app_status = S.status,
        spectrum_frames = S.spectrum_frames or 0,
        spectrum_udp_frames = S.spectrum_udp_frames or 0,
        spectrum_frame_len = S.spectrum_frame_len or 0,
      }
    end,
    restart = function()
      C.accent = tonumber(config.accent_color) or 0x35D0BA
      redraw()
      return true
    end,
  })
  log("web_start_begin", APP_DIR)
  local ok_web, web_err = pcall(function()
    state.web:start()
  end)
  if not ok_web then
    log("web_start_error", web_err)
  else
    log("web_start_ok", state.web and state.web.route_base or "")
  end
end
