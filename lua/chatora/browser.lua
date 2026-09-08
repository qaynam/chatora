-- The browser to hand a URL to. `vim.ui.open` asks the system default, and once
-- `chatora-url-handler install` has made chatora that default, a Cosense page would come
-- straight back to this Neovim. The handler wrote down the browser the reader had before,
-- and that is what gets the URL while the handler is installed.
local M = {}

local function handler_dir()
  local override = vim.env.CHATORA_URL_HANDLER_DIR
  if override and override ~= '' then
    return override
  end
  local data = vim.env.XDG_DATA_HOME
  if not data or data == '' then
    data = vim.fn.expand('~/.local/share')
  end
  return data .. '/chatora/url-handler'
end

--- The bundle id the handler recorded, or nil when it is not installed.
local function recorded_browser()
  local ok, lines = pcall(vim.fn.readfile, handler_dir() .. '/fallback')
  local id = ok and type(lines) == 'table' and lines[1] and vim.trim(lines[1]) or ''
  return id ~= '' and id or nil
end

--- `open -b bundle url`, and whether LaunchServices took it. `open` exits as soon as it
--- has, so the wait is short; a browser removed since it was recorded makes it fail.
local function open_with(bundle, url)
  local ok, result = pcall(function()
    return vim.system({ 'open', '-b', bundle, url }):wait(3000)
  end)
  return ok and result ~= nil and result.code == 0
end

--- Open `url` in the reader's browser. Errors propagate, so a caller can tell the reader.
function M.open(url)
  local bundle = recorded_browser()
  if bundle then
    if open_with(bundle, url) then
      return
    end
    -- With the handler installed the system default is the handler, and a Cosense URL
    -- handed to it would come straight back here; Safari is always there to take it.
    if open_with('com.apple.Safari', url) then
      return
    end
  end
  vim.ui.open(url)
end

return M
