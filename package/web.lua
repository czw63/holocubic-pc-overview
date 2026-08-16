local Web = {}

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

local function json_escape(text)
  text = tostring(text or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub("\"", "\\\"")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\n", "\\n")
  return text
end

local function encode_json(value)
  local codec = rawget(_G, "sjson") or rawget(_G, "json")
  if codec and codec.encode then
    local ok, raw = pcall(codec.encode, value)
    if ok and raw then
      return raw
    end
  end

  return string.format(
    '{"ok":%s,"host":"%s","port":%d,"cover":%s,"spectrum":%s,"refresh_ms":%d,"accent_color":"%s","url":"%s","message":"%s"}',
    value.ok and "true" or "false",
    json_escape(value.host),
    tonumber(value.port) or 8088,
    value.cover and "true" or "false",
    value.spectrum and "true" or "false",
    tonumber(value.refresh_ms) or 33,
    json_escape(value.accent_color),
    json_escape(value.url),
    json_escape(value.message or value.error or "")
  )
end

local function url_decode(text)
  text = tostring(text or "")
  text = text:gsub("+", " ")
  text = text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return text
end

local function parse_query(query)
  local out = {}
  for pair in tostring(query or ""):gmatch("([^&]+)") do
    local key, value = pair:match("^([^=]*)=(.*)$")
    if not key then
      key = pair
      value = ""
    end
    out[url_decode(key)] = url_decode(value)
  end
  return out
end

local function response(status, content_type, body, headers)
  local h = {
    ["cache-control"] = "no-store",
    ["connection"] = "close",
  }
  for k, v in pairs(headers or {}) do
    h[k] = v
  end
  return {
    status = status or "200 OK",
    type = content_type or "text/plain; charset=utf-8",
    headers = h,
    body = body or "",
  }
end

local function json_response(status, value)
  return response(status, "application/json; charset=utf-8", encode_json(value), {
    ["access-control-allow-origin"] = "*",
  })
end

local function js_string(text)
  text = tostring(text or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub("\"", "\\\"")
  return text
end

local function trim(text)
  return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function normalize_route_base(value)
  value = trim(value)
  if value == "" or value == "/" then
    return "/pc_overview"
  end
  if value:sub(-1) == "/" then
    value = value:sub(1, -2)
  end
  return value
end

local function valid_ipv4(host)
  local a, b, c, d = tostring(host or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return false
  end
  local parts = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
  for i = 1, 4 do
    if not parts[i] or parts[i] < 0 or parts[i] > 255 then
      return false
    end
  end
  return true
end

local function bool_text(value)
  return value == true and "true" or "false"
end

local function config_text(config)
  return string.format([=[local config = {}

config.host = %q
config.port = %d
config.udp_port = %d
config.cover = %s
config.spectrum = %s
config.refresh_ms = %d
config.full_refresh_ms = %d
config.weather_location = %q
config.timezone = %q
config.serial_log = %s

config.timeout_ms = %d
config.reconnect_ms = %d
config.stale_ms = %d

config.accent_color = 0x%06X
config.cpu_color = 0x46C7FF
config.gpu_color = 0x62E493
config.mem_color = 0xF2B84B

return config
]=],
    tostring(config.host or "192.168.1.100"),
    tonumber(config.port) or 8088,
    tonumber(config.udp_port) or 8090,
    bool_text(config.cover),
    bool_text(config.spectrum),
    tonumber(config.refresh_ms) or 33,
    tonumber(config.full_refresh_ms) or 500,
    tostring(config.weather_location or ""),
    tostring(config.timezone or "CST-8"),
    config.serial_log == false and "false" or "true",
    tonumber(config.timeout_ms) or 6000,
    tonumber(config.reconnect_ms) or 2000,
    tonumber(config.stale_ms) or 5000,
    tonumber(config.accent_color) or 0x35D0BA
  )
end

local function write_config(path, config)
  if not file or not path then
    return false, "file api missing"
  end
  local raw = config_text(config)
  if file.putcontents then
    local ok, saved = pcall(file.putcontents, path, raw)
    if ok and saved then
      return true
    end
  end
  if not file.open then
    return false, "file.open missing"
  end
  local fd = file.open(path, "w")
  if not fd then
    return false, "open failed"
  end
  local ok = pcall(function() fd:write(raw) end)
  pcall(function() fd:close() end)
  return ok, ok and nil or "write failed"
end

local function build_html(api_prefix)
  api_prefix = js_string(api_prefix)
  return table.concat({
[=[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PC Overview Console</title>
<style>
:root{color-scheme:light;--bg:#f4f7fb;--panel:#fff;--line:#dbe3ef;--text:#152033;--muted:#667085;--blue:#1476c8;--green:#188a5c;--red:#d92d20;--radius:8px}
*{box-sizing:border-box}
body{margin:0;background:linear-gradient(180deg,#fff 0%,var(--bg) 100%);color:var(--text);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
button,input,select{font:inherit;color:inherit}
.page{width:min(900px,calc(100% - 32px));margin:0 auto;padding:24px 0 32px}
.top{display:flex;align-items:flex-end;justify-content:space-between;gap:16px;margin-bottom:14px}
h1{margin:0;font-size:28px;line-height:1.1;letter-spacing:0}
.summary{margin:6px 0 0;color:var(--muted)}
.layout{display:grid;grid-template-columns:minmax(0,1fr) minmax(280px,.82fr);gap:14px}
.panel{padding:16px;border:1px solid var(--line);border-radius:var(--radius);background:#fff}
h2{margin:0 0 12px;font-size:18px;line-height:1.25;letter-spacing:0}
.form{display:grid;gap:12px}
.grid2{display:grid;grid-template-columns:1fr 140px;gap:10px}
label{display:block;margin-bottom:6px;color:var(--muted);font-size:13px;font-weight:700}
input,select{width:100%;min-height:44px;border:1px solid var(--line);border-radius:var(--radius);background:#fff;padding:0 11px;outline:none}
.actions{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
button{min-height:44px;border:1px solid var(--line);border-radius:var(--radius);background:#fff;padding:0 14px;cursor:pointer}
.primary{border-color:transparent;background:#1476c8;color:#fff;font-weight:800}
.status{min-height:24px;color:var(--muted);font-size:13px}
.status.ok{color:var(--green)}.status.error{color:var(--red)}
.steps{display:grid;gap:9px;margin:0;padding:0;list-style:none}
.steps li{display:grid;grid-template-columns:28px minmax(0,1fr);gap:8px;color:var(--muted);font-size:13px}
.num{display:grid;place-items:center;width:28px;height:28px;border-radius:var(--radius);background:#eaf5ff;color:var(--blue);font-weight:850}
.steps strong{display:block;color:var(--text);font-size:14px}
.code{display:block;margin-top:6px;padding:8px 10px;border-radius:var(--radius);background:#111827;color:#e5eefb;font:12px/1.45 ui-monospace,Consolas,monospace;overflow-wrap:anywhere}
.footer{margin-top:14px;color:#8a94a6;font-size:12px;text-align:center}
@media(max-width:760px){.page{width:min(100% - 20px,900px);padding-top:14px}.top{align-items:flex-start}.layout{grid-template-columns:1fr}.grid2{grid-template-columns:1fr}h1{font-size:24px}}
</style>
</head>
<body>
<main class="page">
  <header class="top">
    <div>
      <h1>PC Overview Console</h1>
      <p class="summary">Point the HoloCubic at the Windows bridge service.</p>
    </div>
  </header>
  <section class="layout">
    <section class="panel" aria-labelledby="config-title">
      <h2 id="config-title">Bridge Settings</h2>
      <form class="form" id="configForm">
        <div class="grid2">
          <div>
            <label for="hostInput">PC IP</label>
            <input id="hostInput" name="host" inputmode="decimal" autocomplete="off" placeholder="192.168.1.100" required>
          </div>
          <div>
            <label for="portInput">Port</label>
            <input id="portInput" name="port" inputmode="numeric" autocomplete="off" placeholder="8088" required>
          </div>
        </div>
        <div class="grid2">
          <div>
            <label for="refreshInput">Refresh ms</label>
            <input id="refreshInput" name="refresh_ms" inputmode="numeric" autocomplete="off" placeholder="33">
          </div>
          <div>
            <label for="accentInput">Accent</label>
            <input id="accentInput" name="accent_color" type="color" value="#35D0BA">
          </div>
        </div>
        <div class="grid2">
          <label><input id="coverInput" type="checkbox" name="cover"> Album cover</label>
          <label><input id="spectrumInput" type="checkbox" name="spectrum"> Spectrum</label>
        </div>
        <div class="actions">
          <button class="primary" type="submit">Save</button>
        </div>
        <div class="status" id="statusLine" role="status" aria-live="polite">Loading config...</div>
      </form>
    </section>
    <aside class="panel">
      <h2>Windows Bridge</h2>
      <ol class="steps">
        <li><span class="num">1</span><span><strong>Run the bridge</strong><span>Start pc_bridge.ps1 on the PC with Windows PowerShell 5.1 (powershell.exe).</span></span></li>
        <li><span class="num">2</span><span><strong>Allow the port</strong><span>Allow port 8088 through the Windows Firewall for private networks.</span></span></li>
        <li><span class="num">3</span><span><strong>Verify</strong><span>Open the state URL below in a browser.</span><code class="code" id="urlPreview">http://--:8088/state</code></span></li>
      </ol>
    </aside>
  </section>
  <div class="footer">PC Overview 1.0.0</div>
</main>
<script>
const API = "]=], api_prefix, [=[";;
const hostInput = document.getElementById("hostInput");
const portInput = document.getElementById("portInput");
const refreshInput = document.getElementById("refreshInput");
const accentInput = document.getElementById("accentInput");
const coverInput = document.getElementById("coverInput");
const spectrumInput = document.getElementById("spectrumInput");
const statusLine = document.getElementById("statusLine");
const urlPreview = document.getElementById("urlPreview");

function setStatus(text, tone){
  statusLine.textContent = text || "";
  statusLine.className = "status " + (tone || "");
}

function syncPreview(){
  const host = hostInput.value.trim() || "--";
  const port = portInput.value.trim() || "8088";
  urlPreview.textContent = "http://" + host + ":" + port + "/state";
}

async function loadState(){
  const res = await fetch(API + "/state?_=" + Date.now(), {cache:"no-store"});
  if(!res.ok) throw new Error("HTTP " + res.status);
  const data = await res.json();
  hostInput.value = data.host || "";
  portInput.value = data.port || 8088;
  refreshInput.value = data.refresh_ms || 33;
  accentInput.value = data.accent_color || "#35D0BA";
  coverInput.checked = data.cover !== false;
  spectrumInput.checked = data.spectrum !== false;
  syncPreview();
  setStatus("Current config loaded.", "ok");
}

async function saveConfig(ev){
  ev.preventDefault();
  syncPreview();
  setStatus("Saving...", "");
  const params = new URLSearchParams({
    host: hostInput.value.trim(),
    port: portInput.value.trim(),
    refresh_ms: refreshInput.value.trim() || "33",
    accent_color: accentInput.value,
    cover: coverInput.checked ? "1" : "0",
    spectrum: spectrumInput.checked ? "1" : "0"
  });
  const res = await fetch(API + "/save?" + params.toString(), {cache:"no-store"});
  const data = await res.json();
  if(!res.ok || !data.ok) throw new Error(data.error || data.message || "Save failed");
  syncPreview();
  setStatus("Saved. Restart the app to reconnect.", "ok");
}

document.getElementById("configForm").addEventListener("submit", (ev) => {
  saveConfig(ev).catch((err) => setStatus(err.message, "error"));
});
[hostInput, portInput].forEach((input) => input.addEventListener("input", syncPreview));
loadState().catch((err) => setStatus("Config load failed: " + err.message, "error"));
</script>
</body>
</html>
]=]
  })
end

function Web.new(opts)
  opts = opts or {}
  local self = {
    config = opts.config or {},
    config_path = opts.config_path or "/sd/apps/pc_overview/config.lua",
    route_base = normalize_route_base(opts.route_base or "/pc_overview"),
    api_prefix = normalize_route_base(opts.route_base or "/pc_overview") .. "/api",
    canonical_route = "/pc_overview",
    restart = opts.restart,
    snapshot_extra = opts.snapshot_extra,
    routes = {},
    started = false,
  }

  print("[pc-overview] web module loaded", self.route_base)

  function self:snapshot(ok, message)
    local host = tostring(self.config.host or "")
    local port = tonumber(self.config.port) or 8088
    local accent_color = string.format("#%06X", tonumber(self.config.accent_color) or 0x35D0BA)
    return {
      ok = ok ~= false,
      host = host,
      port = port,
      udp_port = tonumber(self.config.udp_port) or 8090,
      cover = self.config.cover ~= false,
      spectrum = self.config.spectrum ~= false,
      refresh_ms = tonumber(self.config.refresh_ms) or 33,
      accent_color = accent_color,
      url = "http://" .. host .. ":" .. tostring(port) .. "/state",
      message = message or "",
    }
  end

  function self:register(method, route, handler)
    if not httpd or not httpd.dynamic then
      print("[pc-overview] web register skipped, httpd missing", route)
      return false, "httpd missing"
    end
    local ok, err = pcall(function()
      return httpd.dynamic(method, route, handler)
    end)
    if not ok then
      print("[pc-overview] web register error", route, tostring(err))
      return false, tostring(err)
    end
    if err then
      print("[pc-overview] web register error", route, tostring(err))
      return false, tostring(err)
    end
    self.routes[#self.routes + 1] = { method = method, route = route }
    print("[pc-overview] web route ok", method, route)
    return true
  end

  function self:route_index(req)
    return response("200 OK", "text/html; charset=utf-8", build_html(self.api_prefix))
  end

  function self:route_state(req)
    local snap = self:snapshot(true, "loaded")
    if self.snapshot_extra then
      local ok, extra = pcall(self.snapshot_extra)
      if ok and type(extra) == "table" then
        for key, value in pairs(extra) do
          snap[key] = value
        end
      end
    end
    return json_response("200 OK", snap)
  end

  function self:route_save(req)
    local q = parse_query(req and req.query or "")
    local host = trim(q.host)
    local port = tonumber(q.port) or 8088
    local refresh_ms = tonumber(q.refresh_ms) or 33
    local accent_raw = trim(q.accent_color):gsub("^#", "")
    local accent_color = accent_raw:match("^%x%x%x%x%x%x$") and tonumber(accent_raw, 16) or nil
    local cover = q.cover ~= "0"
    local spectrum = q.spectrum ~= "0"

    if not valid_ipv4(host) then
      return json_response("400 Bad Request", {
        ok = false,
        error = "Invalid IPv4 address",
      })
    end
    if port < 1 or port > 65535 then
      return json_response("400 Bad Request", {
        ok = false,
        error = "Port must be 1..65535",
      })
    end
    if refresh_ms < 30 or refresh_ms > 2000 then
      refresh_ms = 33
    end
    if not accent_color then
      accent_color = tonumber(self.config.accent_color) or 0x35D0BA
    end

    self.config.host = host
    self.config.port = math.floor(port)
    self.config.refresh_ms = math.floor(refresh_ms)
    self.config.cover = cover
    self.config.spectrum = spectrum
    self.config.accent_color = accent_color

    local ok, err = write_config(self.config_path, self.config)
    if not ok then
      return json_response("500 Internal Server Error", {
        ok = false,
        error = "Config write failed: " .. text_or(err, "unknown"),
      })
    end

    if self.restart then
      pcall(self.restart)
    end

    return json_response("200 OK", self:snapshot(true, "saved"))
  end

  function self:start()
    if self.started then
      return
    end
    if not httpd or not httpd.start then
      print("[pc-overview] web start skipped, httpd missing")
      return
    end

    pcall(function()
      httpd.start({
        webroot = "/sd",
        auto_index = httpd.INDEX_NONE,
        max_handlers = 32,
      })
    end)

    local function register_base(base)
      self:register(httpd.GET, base, function(req) return self:route_index(req) end)
      self:register(httpd.GET, base .. "/", function(req) return self:route_index(req) end)
    end
    register_base(self.route_base)
    if self.canonical_route ~= self.route_base then
      register_base(self.canonical_route)
    end
    self:register(httpd.GET, self.api_prefix .. "/state", function(req) return self:route_state(req) end)
    self:register(httpd.GET, self.api_prefix .. "/save", function(req) return self:route_save(req) end)
    self:register(httpd.GET, self.api_prefix .. "/health", function(req)
      return response("200 OK", "text/plain; charset=utf-8", "ok")
    end)

    self.started = true
    print("[pc-overview] web started", self.route_base)
  end

  function self:stop(reason)
    if httpd and httpd.unregister then
      for i = #self.routes, 1, -1 do
        local item = self.routes[i]
        pcall(function() httpd.unregister(item.method, item.route) end)
      end
    end
    self.routes = {}
    self.started = false
  end

  return self
end

return Web
