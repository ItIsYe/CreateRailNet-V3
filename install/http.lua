--[[
Purpose: Downloads for the installer: one ref for the whole run, timeout, retries with a changing URL, HTML (CDN error page) detection.
Public API: new(opts) -> client
  opts: base (raw url up to and including the trailing slash), http (the CC http api), parallel, sleep(seconds), clock() -> seconds, timeout_s, retries, delays
  client.valid_ref(ref) -> boolean
  client.url(ref, path) -> url
  client.download(url) -> body | nil, err
  client.download_file(ref, path) -> body | nil, err
  client.is_html(body) -> boolean
Notes: a request has no timeout of its own in CC:Tweaked, so it is raced against a sleep with parallel.waitForAny. The cache-buster in the
  query makes every retry a new URL: raw.githubusercontent.com may serve the old content of a file for a few minutes after a push.
]]

local http_client = {}

local DEFAULT_BASE = "https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/"

function http_client.new(opts)
  local o = opts or {}
  local base = o.base or DEFAULT_BASE
  local http_api = o.http or _G.http
  local parallel_api = o.parallel or _G.parallel
  local sleep = o.sleep or (os and os.sleep) or function() end
  local timeout_s = o.timeout_s or 15
  local retries = o.retries or 4
  local delays = o.delays or { 2, 5, 10, 20 }
  local clock = o.clock or function() return os.epoch and os.epoch("utc") or os.time() end

  local self = {}

  function self.is_html(body)
    if type(body) ~= "string" then return false end
    local head = body:sub(1, 200):lower()
    return head:find("<html", 1, true) ~= nil or head:find("<!doctype", 1, true) ~= nil
  end

  -- branch names and tags: letters, digits and ._-/ ; nothing that could leave the repository path
  function self.valid_ref(ref)
    if type(ref) ~= "string" or ref == "" or #ref > 100 then return false end
    if not ref:match("^[%w%._%-/]+$") then return false end
    if ref:find("..", 1, true) or ref:sub(1, 1) == "/" or ref:sub(-1) == "/" then return false end
    return true
  end

  function self.url(ref, path) return base .. ref .. "/" .. path end

  local function read_response(response)
    if not response then return nil, "empty response" end
    if type(response.getResponseCode) == "function" then
      local ok_code, code = pcall(response.getResponseCode)
      if ok_code and type(code) == "number" and (code < 200 or code >= 300) then
        pcall(response.close)
        return nil, "HTTP " .. tostring(code)
      end
    end
    local ok, body = pcall(response.readAll)
    pcall(response.close)
    if not ok or type(body) ~= "string" or #body == 0 then return nil, "read failed" end
    return body
  end

  local function try_once(url)
    if not http_api or type(http_api.get) ~= "function" then return nil, "http is not available" end
    if type(parallel_api) ~= "table" or type(parallel_api.waitForAny) ~= "function" then
      local ok, response = pcall(http_api.get, url)
      if not ok or not response then return nil, type(response) == "string" and response or "http.get failed" end
      return read_response(response)
    end
    local body, err, done = nil, nil, false
    local ok_race, race_err = pcall(parallel_api.waitForAny,
      function()
        local ok, response = pcall(http_api.get, url)
        if ok and response then body, err = read_response(response)
        else err = type(response) == "string" and response or "http.get failed" end
        done = true
      end,
      function() sleep(timeout_s) end)
    if not ok_race then return nil, "request failed: " .. tostring(race_err) end
    if not done then return nil, "timeout" end
    return body, err
  end

  function self.download(url)
    local last_err
    for attempt = 1, retries do
      local separator = url:find("?", 1, true) and "&" or "?"
      local body, err = try_once(url .. separator .. "crn_cb=" .. attempt .. "_" .. tostring(clock()))
      if body then
        if self.is_html(body) then last_err = "HTML instead of a file (CDN error page)" else return body end
      else
        last_err = err
      end
      if attempt < retries then sleep(delays[attempt] or delays[#delays] or 5) end
    end
    return nil, tostring(last_err or "download failed")
  end

  function self.download_file(ref, path)
    local body, err = self.download(self.url(ref, path))
    if body then return body end
    return nil, "download of " .. path .. " failed: " .. tostring(err)
  end

  return self
end

http_client.DEFAULT_BASE = DEFAULT_BASE

return http_client
