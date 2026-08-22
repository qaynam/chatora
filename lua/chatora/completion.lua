-- Keeps link completion alive through multi-word queries. Completion clients
-- dismiss their menu on space and blink.cmp additionally *blocks* ' ' as an
-- LSP trigger character by default (show_on_blocked_trigger_characters), so
-- the server-side trigger never reaches it. When a space is typed inside an
-- unclosed `[`, re-open the menu through whichever client is installed.
local M = {}

--- Mirrors the server's detectLink: true only when the cursor sits inside a
--- *closed* bracket pair `[...|...]` (and not inside `[[`).
local function in_link_context(line, col)
  local open = nil
  for i = col, 1, -1 do
    local ch = line:sub(i, i)
    if ch == ']' then
      return false
    end
    if ch == '[' then
      if line:sub(i - 1, i - 1) == '[' then
        return false
      end
      open = i
      break
    end
  end
  if not open then
    return false
  end
  for j = col + 1, #line do
    local ch = line:sub(j, j)
    if ch == '[' then
      return false
    end
    if ch == ']' then
      return true
    end
  end
  return false
end

local function show_menu(bufnr)
  if vim.b[bufnr].chatora_native_completion then
    pcall(vim.lsp.completion.get)
    return
  end
  local ok_blink, blink = pcall(require, 'blink.cmp')
  if ok_blink and type(blink.show) == 'function' then
    blink.show()
    return
  end
  local ok_cmp, cmp = pcall(require, 'cmp')
  if ok_cmp and type(cmp.complete) == 'function' then
    cmp.complete()
    return
  end
  if vim.lsp.completion and type(vim.lsp.completion.get) == 'function' then
    pcall(vim.lsp.completion.get)
  end
end

--- True when blink.cmp exists and its `enabled` predicate allows this buffer
--- (evaluated with bufnr current — users disable blink per-filetype via
--- `enabled = function() return vim.bo.filetype ~= ... end`).
local function blink_active_for(bufnr)
  local ok, bcfg = pcall(require, 'blink.cmp.config')
  if not ok then
    return false
  end
  local enabled = bcfg.enabled
  if type(enabled) ~= 'function' then
    return enabled ~= false
  end
  local ok_call, res = pcall(function()
    return vim.api.nvim_buf_call(bufnr, enabled)
  end)
  return ok_call and res ~= false
end

--- Enable Neovim's native LSP completion (autotrigger) when no external
--- engine will serve this buffer, so link completion works even where the
--- user disabled blink.cmp for the cosense filetype.
local function enable_native_if_needed(bufnr)
  local mode = require('chatora.config').options.completion
  if mode == false then
    return
  end
  if mode ~= 'native' then
    if blink_active_for(bufnr) then
      return
    end
    -- blink absent/disabled; nvim-cmp's per-buffer state isn't cheaply
    -- readable, so its mere presence defers to it (force with 'native').
    local has_cmp = pcall(require, 'cmp')
    if has_cmp then
      return
    end
  end
  if not (vim.lsp.completion and vim.lsp.completion.enable) then
    return
  end
  local client = vim.lsp.get_clients({ name = 'chatora', bufnr = bufnr })[1]
  if not client then
    return
  end
  pcall(vim.lsp.completion.enable, true, client.id, bufnr, { autotrigger = true })
  vim.b[bufnr].chatora_native_completion = true
end

function M.attach(bufnr)
  enable_native_if_needed(bufnr)
  if vim.b[bufnr].chatora_completion_attached then
    return
  end
  vim.b[bufnr].chatora_completion_attached = true
  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = bufnr,
    callback = function()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      if col == 0 then
        return
      end
      local line = vim.api.nvim_get_current_line()
      if line:sub(col, col) == ' ' and in_link_context(line, col) then
        show_menu(bufnr)
      end
    end,
  })
end

return M
