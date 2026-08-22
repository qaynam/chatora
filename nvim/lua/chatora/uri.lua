-- cosense:// URI helpers. Percent-encoding follows JS encodeURIComponent
-- semantics (unreserved: A-Z a-z 0-9 - _ . ! ~ * ' ( ), everything else
-- percent-encoded byte-by-byte, which naturally handles multibyte UTF-8
-- titles) to match the server's encodeURIComponent(title) URI scheme.
local M = {}

local SAFE_PATTERN = "^[%w%-%_%.%!%~%*'%(%)]$"

local function is_safe_byte(b)
  return string.char(b):match(SAFE_PATTERN) ~= nil
end

--- Percent-encode a page title for use in a cosense:// URI.
function M.encode_title(title)
  local out = {}
  for i = 1, #title do
    local b = title:byte(i)
    if is_safe_byte(b) then
      out[#out + 1] = string.char(b)
    else
      out[#out + 1] = string.format('%%%02X', b)
    end
  end
  return table.concat(out)
end

--- Decode a percent-encoded page title back to raw UTF-8 text.
function M.decode_title(str)
  return (str:gsub('%%(%x%x)', function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Build a cosense://<project>/<encoded title> URI.
function M.format(project, title)
  return 'cosense://' .. project .. '/' .. M.encode_title(title)
end

--- Parse a cosense:// URI into project, title (decoded).
--- Returns nil, nil if the string is not a valid cosense:// URI.
function M.parse(uri)
  local project, encoded_title = uri:match('^cosense://([^/]+)/(.*)$')
  if not project then
    return nil, nil
  end
  return project, M.decode_title(encoded_title)
end

return M
