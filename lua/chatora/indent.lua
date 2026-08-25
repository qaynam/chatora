-- Cosense indentation, as the parser counts it: one leading whitespace *character* is one
-- level, and a full-width space counts like an ASCII one. That last part is why this is
-- shared rather than a pattern each caller writes — `　` is three bytes, so a level count
-- and a byte offset stop being the same number the moment one appears.
local M = {}

local FULL_WIDTH_SPACE = '　'

--- The byte offset of each indent character (0-based, in order) and the byte its text
--- starts at. Both empty/zero for a line that starts with text.
function M.scan(line)
  local offsets = {}
  local at = 1
  while at <= #line do
    local byte = line:sub(at, at)
    local width
    if byte == ' ' or byte == '\t' then
      width = 1
    elseif line:sub(at, at + #FULL_WIDTH_SPACE - 1) == FULL_WIDTH_SPACE then
      width = #FULL_WIDTH_SPACE
    else
      break
    end
    offsets[#offsets + 1] = at - 1
    at = at + width
  end
  return offsets, at - 1
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
