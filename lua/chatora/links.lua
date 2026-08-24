-- `gd` on a page buffer: external URLs open in the browser (the LSP definition
-- handler deliberately ignores them), everything else falls through to the
-- normal definition jump into another cosense:// buffer.
local M = {}

local config = require('chatora.config')

-- Cosense's bracketed forms ([url], [url label], [label url]) and bare URLs all
-- contain the URL as a run of non-space, non-bracket characters.
local URL_PATTERN = 'https?://[^%s%[%]]+'

--- The URL under (or containing) `col` (0-based byte column) on `line`, or nil.
function M.url_at(line, col)
  local from = 1
  while true do
    local s, e = line:find(URL_PATTERN, from)
    if not s then
      return nil
    end
    -- Cursor anywhere in the URL, including just past its last byte, counts:
    -- `gd` on the closing bracket of `[https://…]` should still open it.
    if col >= s - 1 and col <= e then
      return line:sub(s, e)
    end
    from = e + 1
  end
end

--- Open `url` in the system browser, asking first unless configured otherwise.
--- Returns false when the user declined or external links are disabled.
function M.open_external(url)
  local mode = config.options.external_link
  if mode == 'ignore' or mode == false then
    return false
  end
  if mode ~= 'open' then
    local choice = vim.fn.confirm('ブラウザで開きますか？\n' .. url, '&Yes\n&No', 1)
    if choice ~= 1 then
      return false
    end
  end
  local ok, err = pcall(vim.ui.open, url)
  if not ok then
    vim.notify('[chatora] ブラウザを開けませんでした: ' .. tostring(err), vim.log.levels.ERROR)
  end
  return true
end

--- The `gd` handler for cosense buffers.
function M.goto_definition()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local url = M.url_at(vim.api.nvim_get_current_line(), col)
  if url then
    M.open_external(url)
    return
  end
  vim.lsp.buf.definition()
end

return M
