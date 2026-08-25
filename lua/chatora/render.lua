-- Owner of the chatora/decorations request, which returns both the markup ranges to
-- conceal and the quoted lines (UTF-16 columns) in one round trip.
--
-- Concealing follows render-markdown.nvim: conceallevel=2 + concealcursor='' lets
-- Neovim itself reveal the raw source on the cursor line. The quote half is drawn by
-- chatora.quote, which has its own switch.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

M.ns = vim.api.nvim_create_namespace('chatora_render')

local uv = vim.uv or vim.loop
local timers = {}

local function set_win_opts(bufnr)
  if config.options.conceal ~= false then
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      vim.wo[win].conceallevel = 2
      vim.wo[win].concealcursor = ''
    end
  end
  require('chatora.quote').setup_win(bufnr)
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
        local spec = r.notation and config.notation_spec(r.notation)
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, r.line, sb, {
          end_col = eb,
          conceal = spec and spec.icon or '',
        })
        if spec and spec.rule then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, r.line, 0, {
            line_hl_group = config.notation_rule_hl(r.notation),
          })
        end
      end
    end
  end
end

function M.refresh(bufnr)
  local uri = vim.api.nvim_buf_get_name(bufnr)
  -- Cosmetic feature: fail silently rather than notifying on every edit.
  lsp.request('chatora/decorations', { uri = uri }, function(err, result)
    if err or not result or result.ok == false then
      return
    end
    if config.options.conceal == false then
      vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    else
      apply(bufnr, result.conceal or {})
    end
    require('chatora.quote').render(bufnr, result.quotes or {})
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
