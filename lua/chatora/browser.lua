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

--- Open `url` in the reader's browser. Errors propagate, so a caller can tell the reader.
function M.open(url)
  local bundle = recorded_browser()
  if bundle then
    -- `open` exits as soon as LaunchServices has taken the URL, so the wait is short. A
    -- browser removed since it was recorded makes it fail, and the default is next.
    local ok, result = pcall(function()
      return vim.system({ 'open', '-b', bundle, url }):wait(3000)
    end)
    if ok and result and result.code == 0 then
      return
    end
  end
  vim.ui.open(url)
end

return M
