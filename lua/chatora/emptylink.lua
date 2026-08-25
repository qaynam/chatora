-- Cosense's red links: a link to a page nobody has written yet is drawn differently from
-- one that resolves. Deliberately unhurried — see chatora/emptyLinks for why the answer is
-- allowed to lag.
local M = {}

local lsp = require('chatora.lsp')

M.ns = vim.api.nvim_create_namespace('chatora_emptylink')

local DEBOUNCE_MS = 400

local uv = vim.uv or vim.loop
local timers = {}

local function ensure_hl()
  -- Cosense draws these red; DiagnosticError is the group a colorscheme is most likely to
  -- have made red on purpose, and it degrades sensibly on the ones that have not.
  vim.api.nvim_set_hl(0, 'ChatoraLinkEmpty', { link = 'DiagnosticError', default = true })
end

--- Mark `links` (UTF-16 columns, from chatora/emptyLinks) as pointing at nothing.
--- The mark replaces the link's own color, so it wins on priority over semantic tokens.
local function mark(bufnr, links)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  if #links == 0 then
    return
  end
  ensure_hl()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, link in ipairs(links) do
    local line = lines[link.line + 1]
    if line then
      local ok_from, from = pcall(vim.str_byteindex, line, 'utf-16', link.startChar, false)
      local ok_to, to = pcall(vim.str_byteindex, line, 'utf-16', link.endChar, false)
      if ok_from and ok_to and to > from then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, link.line, from, {
          end_col = to,
          hl_group = 'ChatoraLinkEmpty',
          -- Above the semantic token layer (125), which has already colored this as a link.
          priority = 130,
        })
      end
    end
  end
end

function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  lsp.request('chatora/emptyLinks', { uri = vim.api.nvim_buf_get_name(bufnr) }, function(err, result)
    if err or not result or result.ok == false or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    mark(bufnr, result.links or {})
  end)
end

local function schedule(bufnr)
  local timer = timers[bufnr]
  if not timer then
    timer = uv.new_timer()
    timers[bufnr] = timer
  end
  pcall(function()
    timer:stop()
    timer:start(
      DEBOUNCE_MS,
      0,
      vim.schedule_wrap(function()
        M.refresh(bufnr)
      end)
    )
  end)
end

function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  ensure_hl()
  schedule(bufnr)
  if vim.b[bufnr].chatora_emptylink_attached then
    return
  end
  vim.b[bufnr].chatora_emptylink_attached = true
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      schedule(bufnr)
    end,
    on_detach = function()
      local timer = timers[bufnr]
      if timer then
        pcall(function()
          timer:stop()
          timer:close()
        end)
        timers[bufnr] = nil
      end
      vim.schedule(function()
        pcall(vim.api.nvim_buf_set_var, bufnr, 'chatora_emptylink_attached', false)
      end)
    end,
  })
end

return M
