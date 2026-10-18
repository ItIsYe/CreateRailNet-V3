--[[
Purpose: Downloads of the installer: retries with new URLs, CDN error pages, HTTP codes, timeout, ref names.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local http_module = dofile("install/http.lua")

local function response(body, code) return { readAll = function() return body end, getResponseCode = function() return code or 200 end, close = function() end } end

local function client(handler, extra)
  local env = { urls = {}, sleeps = {} }
  local fake = { get = function(url) env.urls[#env.urls + 1] = url; return handler(url, #env.urls) end }
  local opts = { base = "https://example.test/", http = fake, sleep = function(s) env.sleeps[#env.sleeps + 1] = s end, clock = function() return 42 end }
  for k, v in pairs(extra or {}) do opts[k] = v end
  env.client = http_module.new(opts)
  return env
end

return {
  test_download_returns_the_body = function()
    local c = client(function() return response("hello") end)
    assert(c.client.download("https://example.test/x") == "hello")
    assert(#c.urls == 1 and c.urls[1]:find("crn_cb=1_42", 1, true))
  end,

  test_every_retry_uses_a_new_url_and_waits_longer = function()
    local c = client(function(_, n) if n < 3 then return nil end; return response("late") end)
    assert(c.client.download("https://example.test/x?a=1") == "late")
    assert(#c.urls == 3 and c.urls[1] ~= c.urls[2] and c.urls[2] ~= c.urls[3])
    assert(c.urls[1]:find("?a=1&crn_cb=", 1, true), "an existing query is extended")
    assert(c.sleeps[1] == 2 and c.sleeps[2] == 5, table.concat(c.sleeps, ","))
  end,

  test_cdn_error_page_is_not_a_file = function()
    local c = client(function() return response("<!DOCTYPE html><html>502</html>") end)
    local body, err = c.client.download("https://example.test/x")
    assert(body == nil and err:find("HTML", 1, true), tostring(err))
    assert(#c.urls == 4, "gave up after four tries: " .. #c.urls)
  end,

  test_http_error_codes_fail = function()
    local c = client(function() return response("Not Found", 404) end)
    local body, err = c.client.download("https://example.test/x")
    assert(body == nil and err == "HTTP 404", tostring(err))
  end,

  test_empty_answer_fails = function()
    local c = client(function() return response("") end)
    assert(c.client.download("https://example.test/x") == nil)
  end,

  test_download_file_names_the_file_in_the_error = function()
    local c = client(function() return nil end)
    local body, err = c.client.download_file("main", "src/shared/net.lua")
    assert(body == nil and err:find("src/shared/net.lua", 1, true))
    assert(c.urls[1]:find("https://example.test/main/src/shared/net.lua", 1, true))
  end,

  test_request_is_raced_against_a_timeout = function()
    -- a parallel.waitForAny whose first function never finishes: only the sleeper ran, the request counts as timed out
    local c = client(function() return response("never read") end, { parallel = { waitForAny = function(_, second) second() end } })
    local body, err = c.client.download("https://example.test/x")
    assert(body == nil and err == "timeout", tostring(err))
    assert(c.sleeps[1] == 15, "the timeout is 15 s: " .. tostring(c.sleeps[1]))
    -- and when the request answers first, the body arrives
    local d = client(function() return response("fast") end, { parallel = { waitForAny = function(first) first() end } })
    assert(d.client.download("https://example.test/x") == "fast")
  end,

  test_ref_names = function()
    local c = client(function() end).client
    for _, ok in ipairs({ "main", "v1.2", "claude/feature-1", "a_b-c.d" }) do assert(c.valid_ref(ok), ok) end
    for _, bad in ipairs({ "", "../x", "a/../b", "/abs", "trailing/", "a b", "a?b=1", "a#b", string.rep("x", 101) }) do assert(not c.valid_ref(bad), bad) end
  end,

  test_urls_are_built_from_base_ref_and_path = function()
    local c = client(function() end).client
    assert(c.url("main", "install/manifest.lua") == "https://example.test/main/install/manifest.lua")
  end,
}
