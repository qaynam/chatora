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

--- Hand `url` to whatever `video` names, and say whether it took it. A function declines by
--- returning false, and so does anything naming no player — the default included.
local function play(url)
  local player = config.options.video
  if type(player) == 'function' then
    local ok, took = pcall(player, url)
    if not ok then
      vim.notify('[chatora] video: ' .. tostring(took), vim.log.levels.ERROR)
      return false
    end
    return took ~= false
  end
  if type(player) == 'string' then
    player = { player, '{url}' }
  end
  if type(player) ~= 'table' or #player == 0 then
    return false
  end
  local cmd = {}
  for i, word in ipairs(player) do
    cmd[i] = type(word) == 'string' and word:gsub('{url}', url) or word
  end
  local ok, err = pcall(vim.system, cmd, { detach = true })
  if not ok then
    vim.notify('[chatora] 再生できませんでした: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
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

--- Follow the LSP definition ourselves rather than through `vim.lsp.buf.definition()`.
---
--- The built-in jump edits the target and sets the cursor in one breath, which works for a
--- file that is on disk. A cosense:// buffer is filled by a request, so at that moment it
--- has no lines yet and the row a `[title#lineId]` link resolved to has nowhere to land.
--- The row is handed to the page instead, which applies it once the text arrives.
local function follow_definition(bufnr, row, character)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row - 1, character = character },
  }
  vim.lsp.buf_request(bufnr, 'textDocument/definition', params, function(err, result)
    local location = result
    if vim.islist(location) then
      location = location[1]
    end
    if err or not location or not location.uri then
      return
    end
    local project, title = require('chatora.uri').parse(location.uri)
    if not project then
      return
    end
    local target_row = location.range and location.range.start and location.range.start.line or 0
    require('chatora.page').open(project, title, require('chatora.winutil').ensure_editor_win(), {
      row = target_row + 1,
    })
  end)
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
        follow_definition(bufnr, row, character)
      end
      return
    end
    if result.url then
      if result.play and play(result.play) then
        return
      end
      M.open_external(result.url)
    else
      follow_definition(bufnr, row, character)
    end
  end)
end

return M
