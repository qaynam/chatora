-- `gd` on a page buffer: external URLs open in the browser, everything else
-- falls through to the LSP definition jump into another cosense:// buffer.
local M = {}

local config = require('chatora.config')

local URL_PATTERN = 'https?://[^%s%[%]]+'

--- The URL under (or containing) `col` (0-based byte column) on `line`, or nil.
--- Used only when the server can't answer; it cannot tell an image's src from
--- the link laid over it, so `chatora/urlAt` is preferred.
function M.url_at(line, col)
  local from = 1
  while true do
    local s, e = line:find(URL_PATTERN, from)
    if not s then
      return nil
    end
    -- Just past the last byte counts too: `gd` on the closing bracket of
    -- `[https://…]` should still open it.
    if col >= s - 1 and col <= e then
      return line:sub(s, e)
    end
    from = e + 1
  end
end

--- Open `url` in the system browser, asking first unless configured otherwise.
function M.open_external(url)
  local mode = config.options.external_link
  if mode == 'ignore' or mode == false then
    return
  end
  if mode ~= 'open' and vim.fn.confirm('ブラウザで開きますか？\n' .. url, '&Yes\n&No', 1) ~= 1 then
    return
  end
  local ok, err = pcall(vim.ui.open, url)
  if not ok then
    vim.notify('[chatora] ブラウザを開けませんでした: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

--- The `gd` handler for cosense buffers.
function M.goto_definition()
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local character = vim.str_utfindex(line, 'utf-16', math.min(col, #line), false)

  require('chatora.lsp').request('chatora/urlAt', {
    uri = vim.api.nvim_buf_get_name(bufnr),
    line = row - 1,
    character = character,
  }, function(err, result)
    if err or not result or result.ok == false then
      local fallback = M.url_at(line, col)
      if fallback then
        M.open_external(fallback)
      else
        vim.lsp.buf.definition()
      end
      return
    end
    if result.url then
      M.open_external(result.url)
    else
      vim.lsp.buf.definition()
    end
  end)
end

return M
