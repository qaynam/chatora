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

--- Percent-decode a browser URL's path segment. Cosense writes `_` for the space
--- in a title, so a real underscore arrives percent-encoded and survives this.
local function decode_url_segment(segment)
  return (segment:gsub('%%(%x%x)', function(hex)
      return string.char(tonumber(hex, 16))
    end):gsub('_', ' '))
end

-- Hosts that serve Cosense pages regardless of what `origin` is configured to, so a
-- link copied from either brand resolves.
local KNOWN_HOSTS = { ['scrapbox.io'] = true, ['cosense.io'] = true }

-- Top-level paths that are Cosense's own, not a project.
local NON_PROJECT_PATHS = { api = true, settings = true, projects = true }

--- Parse a Cosense/Scrapbox web URL (`https://scrapbox.io/<project>/<title>`) into
--- project, title. A project-root URL yields a nil title. Returns nil, nil for a URL
--- on some other host, or for one of Cosense's own non-project paths.
function M.parse_web(url, origin)
  local host, rest = url:match('^https?://([^/]+)/?(.*)$')
  if not host then
    return nil, nil
  end
  local origin_host = origin and origin:match('^https?://([^/]+)')
  if not (KNOWN_HOSTS[host] or host == origin_host) then
    return nil, nil
  end
  -- Drop the fragment and query: neither is part of the page's identity.
  rest = rest:gsub('[#?].*$', '')
  local project, title = rest:match('^([^/]+)/?(.*)$')
  if not project or NON_PROJECT_PATHS[project] then
    return nil, nil
  end
  return project, (title ~= '' and decode_url_segment(title) or nil)
end

--- Project and title for any form chatora accepts as "a page": its own cosense://
--- URI or a Cosense web URL on a known host or the configured origin.
function M.parse_any(str)
  local project, title = M.parse(str)
  if project then
    return project, title
  end
  return M.parse_web(str, require('chatora.config').options.origin)
end

--- Browser URL for a page, for copying and for `gd` on an external link.
function M.web_url(origin, project, title)
  local encoded = title
    :gsub('[%%/%?#%c]', function(c)
      return string.format('%%%02X', string.byte(c))
    end)
    :gsub(' ', '_')
  return origin:gsub('/$', '') .. '/' .. project .. '/' .. encoded
end

return M
