-- Save state of cosense page buffers, surfaced as a small icon rather than a
-- toast: the sidebar's mark column, an optional statusline component, and a
-- single cmdline line on state changes. Only failures still go through
-- vim.notify, where covering the screen is the point.
local M = {}

local config = require('chatora.config')

--- bufnr -> 'clean' | 'dirty' | 'saving' | 'error'
local state_by_bufnr = {}

-- The page whose state chatora's own chrome reports. Tracked separately from
-- the current buffer so the sidebar's winbar keeps showing the page you are
-- editing while the cursor sits in the sidebar.
local last_page_bufnr = nil

local DEFAULT_ICONS = { clean = '✓', dirty = '●', saving = '◍', error = '✗' }

local HL_GROUP = {
  clean = 'ChatoraStatusOk',
  dirty = 'ChatoraStatusDirty',
  saving = 'ChatoraStatusPending',
  error = 'ChatoraStatusError',
}

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraStatusOk', { link = 'DiagnosticOk', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraStatusDirty', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraStatusPending', { link = 'DiagnosticWarn', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraStatusError', { link = 'DiagnosticError', default = true })
end

local function settings()
  local raw = config.options.status
  if raw == false then
    return { enabled = false, icons = DEFAULT_ICONS, echo = false }
  end
  if type(raw) ~= 'table' then
    raw = {}
  end
  return {
    enabled = raw.enabled ~= false,
    icons = vim.tbl_extend('force', DEFAULT_ICONS, raw.icons or {}),
    echo = raw.echo ~= false,
  }
end

function M.get(bufnr)
  return state_by_bufnr[bufnr]
end

--- Icon + highlight group for a buffer, or nil when it has no tracked state
--- (never opened as a page, or the indicator is disabled).
function M.icon(bufnr)
  local opts = settings()
  if not opts.enabled then
    return nil
  end
  local state = state_by_bufnr[bufnr]
  if not state then
    return nil
  end
  return opts.icons[state], HL_GROUP[state]
end

--- Buffer-name lookup for callers that only hold a cosense:// URI (the sidebar
--- lists pages, not buffers).
function M.icon_for_uri(uri)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == uri then
      return M.icon(b)
    end
  end
  return nil
end

--- One short line in the cmdline instead of a floating notification. Messages
--- are kept out of :messages history: this is transient feedback, not a log.
local function echo(text, hl_group)
  if not settings().echo then
    return
  end
  ensure_hl()
  vim.api.nvim_echo({ { 'chatora ', 'Comment' }, { text, hl_group } }, false, {})
end

--- Record `state` for bufnr and refresh everything that displays it. `message`
--- (optional) is echoed to the cmdline.
function M.set(bufnr, state, message)
  ensure_hl()
  local previous = state_by_bufnr[bufnr]
  state_by_bufnr[bufnr] = state
  last_page_bufnr = bufnr
  if message then
    echo(message, HL_GROUP[state])
  end
  if previous ~= state then
    require('chatora.sidebar').refresh_marks()
    vim.cmd('redrawstatus')
  end
end

--- Re-derive 'clean'/'dirty' from the buffer's own modified flag. A no-op while
--- a save is in flight, so the pending icon survives the edit events that
--- writing the server's normalized text back into the buffer generates.
function M.sync(bufnr)
  if state_by_bufnr[bufnr] == 'saving' then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    state_by_bufnr[bufnr] = nil
    return
  end
  M.set(bufnr, vim.bo[bufnr].modified and 'dirty' or 'clean')
end

function M.forget(bufnr)
  state_by_bufnr[bufnr] = nil
  if last_page_bufnr == bufnr then
    last_page_bufnr = nil
  end
end

--- Statusline component for `bufnr` (default: the current buffer if it's a
--- tracked page, else the most recently active one): the icon wrapped in its
--- highlight group, or '' when there is nothing to report. Wire it into any
--- statusline plugin, or into Neovim's own:
---   vim.o.statusline = "%f %{%v:lua.require'chatora.status'.component()%}"
function M.component(bufnr)
  local target = bufnr
  if not target then
    local current = vim.api.nvim_get_current_buf()
    target = state_by_bufnr[current] and current or last_page_bufnr
  end
  if not target then
    return ''
  end
  local icon, hl_group = M.icon(target)
  if not icon then
    return ''
  end
  return '%#' .. hl_group .. '#' .. icon .. '%*'
end

return M
