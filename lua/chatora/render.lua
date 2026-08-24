-- render-markdown.nvim style notation concealing for cosense buffers: the
-- server returns markup ranges (chatora/decorations, UTF-16 columns) and we
-- hide them via conceal extmarks. conceallevel=2 + concealcursor='' means
-- Neovim itself reveals the raw source on the cursor line.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

M.ns = vim.api.nvim_create_namespace('chatora_render')

local uv = vim.uv or vim.loop
local timers = {}

local function set_win_opts(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = ''
  end
end

local function apply(bufnr, ranges)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, r in ipairs(ranges) do
    local ltext = lines[r.line + 1]
    if ltext then
      -- Server columns are UTF-16 code units; extmarks want byte columns.
      local ok1, sb = pcall(vim.str_byteindex, ltext, 'utf-16', r.startChar, false)
      local ok2, eb = pcall(vim.str_byteindex, ltext, 'utf-16', r.endChar, false)
      if ok1 and ok2 and eb > sb then
        local icon = r.notation and config.notation_icon(r.notation)
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, r.line, sb, {
          end_col = eb,
          conceal = icon or '',
        })
      end
    end
  end
end

function M.refresh(bufnr)
  if config.options.conceal == false then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    return
  end
  local uri = vim.api.nvim_buf_get_name(bufnr)
  -- Cosmetic feature: fail silently rather than notifying on every edit.
  lsp.request('chatora/decorations', { uri = uri }, function(err, result)
    if err or not result or result.ok == false then
      return
    end
    apply(bufnr, result.conceal or {})
  end)
end

local function debounced_refresh(bufnr)
  local timer = timers[bufnr]
  if not timer then
    timer = uv.new_timer()
    timers[bufnr] = timer
  end
  timer:stop()
  timer:start(
    200,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.refresh(bufnr)
      end
    end)
  )
end

function M.attach(bufnr)
  if config.options.conceal == false then
    return
  end
  set_win_opts(bufnr)
  M.refresh(bufnr)
  if vim.b[bufnr].chatora_render_attached then
    return
  end
  vim.b[bufnr].chatora_render_attached = true
  vim.api.nvim_create_autocmd('BufWinEnter', {
    buffer = bufnr,
    callback = function()
      set_win_opts(bufnr)
    end,
  })
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      vim.schedule(function()
        debounced_refresh(bufnr)
      end)
    end,
    on_detach = function()
      vim.schedule(function()
        local timer = timers[bufnr]
        if timer then
          timer:stop()
          timer:close()
          timers[bufnr] = nil
        end
        pcall(vim.api.nvim_buf_set_var, bufnr, 'chatora_render_attached', false)
      end)
    end,
  })
end

return M
