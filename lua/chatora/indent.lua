-- Cosense indentation, as the parser counts it: one leading whitespace *character* is one
-- level, and a full-width space counts like an ASCII one. That last part is why this is
-- shared rather than a pattern each caller writes — `　` is three bytes, so a level count
-- and a byte offset stop being the same number the moment one appears.
local M = {}

local FULL_WIDTH_SPACE = '　'

--- Each indent character as `{ at, char }` with `at` its 0-based byte offset, plus the
--- byte the text starts at. Both empty/zero for a line that starts with text.
---
--- The character comes along because the three that count as one level are not one width:
--- a space is a cell, a full-width space is two, and a tab is however many the buffer's
--- 'tabstop' says. Levels only line up if that difference is measured and made up.
function M.scan(line)
  local levels = {}
  local at = 1
  while at <= #line do
    local byte = line:sub(at, at)
    local char
    if byte == ' ' or byte == '\t' then
      char = byte
    elseif line:sub(at, at + #FULL_WIDTH_SPACE - 1) == FULL_WIDTH_SPACE then
      char = FULL_WIDTH_SPACE
    else
      break
    end
    levels[#levels + 1] = { at = at - 1, char = char }
    at = at + #char
  end
  return levels, at - 1
end

--- Display cells one indent character occupies. A leading tab always reaches the next
--- tab stop from a multiple of one, so it is exactly `tabstop` wide.
function M.cells(char, tabstop)
  return char == '\t' and tabstop or vim.fn.strdisplaywidth(char)
end

--- How deep `line` is indented, in levels.
function M.level(line)
  return #(M.scan(line))
end

--- Byte offset where `line`'s text begins, past any indent.
function M.text_at(line)
  local _, text_at = M.scan(line)
  return text_at
end

return M
