--[[
Purpose: Shrinks a Lua source for the computers in the game without changing what it means: comments and indentation go, the line numbers stay (so a message "file.lua:123" of the game points at line 123 of the source in the repository).
Public API: minify(source) -> text | nil, err; tokens(source) -> list of token texts (comments and white space left out; the test compares the token lists of source and result); measure(source) -> bytes saved.
Notes: a CC:Tweaked computer holds 1 000 000 bytes (fixed; computer_space_limit is not raised) and the source of this repository is rich in comments, so the installer ships the result of this function (dist/, scripts/build_dist.lua). A lexer, not a pattern:
  strings (short and long) are copied as they are, long comments are replaced by as many line ends as they had, a line comment ends at its line end, the white space inside a line becomes one space where two words, two `-`, two `.`, two `[` or `]`
  or a number and `..` would grow together otherwise and disappears next to ( ) { } , ; = + * / % ^ # < > ~. Nothing else is changed: no names are shortened, no code is moved. Lua 5.1 syntax only (no goto labels, no integer division).
]]

local minify = {}

local function long_bracket_level(src, i)
  -- src:sub(i, i) == "[": the level of a long bracket opening here, or nil
  local eq = src:match("^%[(=*)%[", i)
  return eq and #eq or nil
end

-- the list of lexical pieces: { kind = "space" | "newline" | "comment" | "string" | "word" | "number" | "punct", text }
local function lex(src)
  local out, i, n = {}, 1, #src
  local function add(kind, text) out[#out + 1] = { kind = kind, text = text } end
  while i <= n do
    local c = src:sub(i, i)
    if c == "\n" then add("newline", c); i = i + 1
    elseif c == " " or c == "\t" or c == "\r" then
      local s = src:match("^[ \t\r]+", i)
      add("space", s); i = i + #s
    elseif c == "-" and src:sub(i + 1, i + 1) == "-" then
      local level = src:sub(i + 2, i + 2) == "[" and long_bracket_level(src, i + 2)
      if level then
        local close = "]" .. string.rep("=", level) .. "]"
        local _, e = src:find(close, i + 4 + level, true)
        if not e then return nil, "unfinished long comment" end
        add("comment", src:sub(i, e)); i = e + 1
      else
        local e = src:find("\n", i, true) or (n + 1)
        add("comment", src:sub(i, e - 1)); i = e
      end
    elseif c == '"' or c == "'" then
      local j = i + 1
      while true do
        local d = src:sub(j, j)
        if d == "" then return nil, "unfinished string" end
        if d == "\\" then j = j + 2
        elseif d == c then break
        elseif d == "\n" then return nil, "newline in string"
        else j = j + 1 end
      end
      add("string", src:sub(i, j)); i = j + 1
    elseif c == "[" and long_bracket_level(src, i) then
      local level = long_bracket_level(src, i)
      local close = "]" .. string.rep("=", level) .. "]"
      local _, e = src:find(close, i + 2 + level, true)
      if not e then return nil, "unfinished long string" end
      add("string", src:sub(i, e)); i = e + 1
    elseif c:match("[%a_]") then
      local s = src:match("^[%w_]+", i)
      add("word", s); i = i + #s
    elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
      -- a number: digits, a dot, an exponent with sign, hex digits
      local s = src:match("^0[xX][%x]+", i)
      if not s then
        local j = i
        while true do
          local d = src:sub(j, j)
          if d:match("[%d%.]") then j = j + 1
          elseif (d == "e" or d == "E") then
            j = j + 1
            if src:sub(j, j):match("[%+%-]") then j = j + 1 end
          else break end
        end
        s = src:sub(i, j - 1)
      end
      add("number", s); i = i + #s
    else
      local three = src:sub(i, i + 2)
      if three == "..." then add("punct", three); i = i + 3
      else
        local two = src:sub(i, i + 1)
        if two == ".." or two == "==" or two == "~=" or two == "<=" or two == ">=" then add("punct", two); i = i + 2
        else add("punct", c); i = i + 1 end
      end
    end
  end
  return out
end

function minify.tokens(src)
  local pieces, err = lex(src)
  if not pieces then return nil, err end
  local out = {}
  for _, piece in ipairs(pieces) do
    if piece.kind ~= "space" and piece.kind ~= "newline" and piece.kind ~= "comment" then out[#out + 1] = piece.text end
  end
  return out
end

local TIGHT = {}
for ch in ("(){},;=+*/%^#<>~"):gmatch(".") do TIGHT[ch] = true end

local function ends_with(text) return text:sub(-1) end
local function starts_with(text) return text:sub(1, 1) end

-- may two neighbours lose the white space between them?
local function joinable(left, right)
  local l, r = ends_with(left.text), starts_with(right.text)
  if TIGHT[l] or TIGHT[r] then return true end
  return false
end

function minify.minify(src)
  local pieces, err = lex(src)
  if not pieces then return nil, err end
  local out = {}
  local line = {}          -- the pieces of the current line without comments and white space
  local pending_space = false
  local function flush_line()
    local text = {}
    local previous
    for _, piece in ipairs(line) do
      if previous and piece.space_before and not joinable(previous, piece) then text[#text + 1] = " " end
      text[#text + 1] = piece.text
      previous = piece
    end
    out[#out + 1] = table.concat(text)
    line = {}
  end
  for _, piece in ipairs(pieces) do
    if piece.kind == "newline" then
      flush_line(); out[#out + 1] = "\n"; pending_space = false
    elseif piece.kind == "space" then
      pending_space = true
    elseif piece.kind == "comment" then
      -- a long comment keeps its line ends; as a separator it counts as white space
      local _, lines = piece.text:gsub("\n", "")
      if lines > 0 then flush_line(); out[#out + 1] = string.rep("\n", lines) end
      pending_space = true
    else
      local copy = { kind = piece.kind, text = piece.text, space_before = pending_space }
      -- a string with line ends inside (long string) keeps them; the line count stays right because the text is copied whole
      line[#line + 1] = copy
      pending_space = false
    end
  end
  flush_line()
  local text = table.concat(out)
  -- the end of a line carries no white space, a file ends with one line end
  text = text:gsub("[ \t]+\n", "\n")
  return text
end

function minify.measure(src)
  local text = minify.minify(src)
  return text and (#src - #text) or 0
end

return minify
