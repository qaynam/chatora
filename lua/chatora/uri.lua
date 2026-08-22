-- cosense:// URI helpers. The URI doubles as the buffer name shown in
-- tablines/statuslines, so unicode (Japanese titles) stays raw and only
-- characters that would break the URI structure (%, /, ?, # and control
-- chars) are percent-encoded. Must stay byte-identical with the server's
-- encodeTitleForUri (packages/server/src/uriScheme.ts).
local M = {}

--- Percent-encode a page title for use in a cosense:// URI.
function M.encode_title(title)
  return (title:gsub('[%%/%?#%c]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
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
