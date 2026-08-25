-- Save state of cosense page buffers, surfaced as a small icon rather than a
-- toast: the sidebar's mark column, an optional statusline component, and a
-- single cmdline line on state changes. Only failures still go through
-- vim.notify, where covering the screen is the point.
local M = {}

local config = require('chatora.config')

--- bufnr -> 'clean' | 'dirty' | 'loading' | 'saving' | 'error'
local state_by_bufnr = {}

local PENDING = { loading = true, saving = true }

local spinner = require('chatora.spinner')

local placeholder_ns = vim.api.nvim_create_namespace('chatora_status_placeholder')

-- The page whose state chatora's own chrome reports. Tracked separately from
-- the current buffer so the sidebar's winbar keeps showing the page you are
-- editing while the cursor sits in the sidebar.
local last_page_bufnr = nil

-- `loading` and `saving` have no icon of their own: they animate.
local DEFAULT_ICONS = { clean = '✓', dirty = '●', error = '✗' }

local HL_GROUP = {
  clean = 'ChatoraStatusOk',
  dirty = 'ChatoraStatusDirty',
  loading = 'ChatoraStatusPending',
  saving = 'ChatoraStatusPending',
  error = 'ChatoraStatusError',
}

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraStatusOk', { link = 'DiagnosticOk', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraStatusDirty', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraStatusPending', { link = 'DiagnosticWarn', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraStatusError', { link = 'DiagnosticError', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraStatusMuted', { link = 'Comment', default = true })
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

--- A page buffer has no text until its content arrives, which looks identical
--- to a broken one — so say so, in the buffer, next to the spinner.
local function render_placeholder(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, placeholder_ns, 0, -1)
  if state_by_bufnr[bufnr] ~= 'loading' then
    return
  end
  ensure_hl()
  pcall(vim.api.nvim_buf_set_extmark, bufnr, placeholder_ns, 0, 0, {
    virt_text = { { spinner.frame() .. ' 読み込み中…', 'ChatoraStatusPending' } },
    virt_text_pos = 'overlay',
  })
end

--- Animate for as long as any buffer is mid-request.
local function sync_spinner()
  local pending = false
  for _, state in pairs(state_by_bufnr) do
    if PENDING[state] then
      pending = true
    end
  end
  if not pending then
    spinner.release('status')
    return
  end
  spinner.subscribe('status', function()
    local still_pending = false
    for bufnr, state in pairs(state_by_bufnr) do
      if state == 'loading' then
        render_placeholder(bufnr)
      end
      if PENDING[state] then
        still_pending = true
      end
    end
    require('chatora.sidebar').refresh_marks()
    vim.cmd('redrawstatus')
    if not still_pending then
      spinner.release('status')
    end
  end)
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
  if PENDING[state] then
    return spinner.frame(), HL_GROUP[state]
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
  render_placeholder(bufnr)
  sync_spinner()
  if previous ~= state then
    require('chatora.sidebar').refresh_marks()
    vim.cmd('redrawstatus')
  end
end

--- Re-derive 'clean'/'dirty' from the buffer's own modified flag. A no-op while
--- a request is in flight, so the spinner survives the edit events that
--- filling the buffer from a response generates.
function M.sync(bufnr)
  if PENDING[state_by_bufnr[bufnr]] then
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
  sync_spinner()
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

--- Cosense's own numbers for the page in `bufnr` (default: the current buffer), or nil
--- for a buffer that is not a page and before its metadata has arrived.
local function page_meta(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return require('chatora.page').meta(bufnr)
end

--- How long ago Cosense last saw a change to the page, e.g. `更新 3時間前`.
function M.updated(bufnr)
  local meta = page_meta(bufnr)
  if not meta then
    return nil
  end
  local relative = require('chatora.actions').relative_time(meta.updated)
  return relative and ('更新 ' .. relative) or nil
end

-- Cosense's timestamps describe the copy on the *server*. An unsaved buffer makes them
-- quietly wrong — this badge is what says so, in the same place the reader is already
-- looking for "how fresh is this".
local BADGE = { dirty = '● 未保存', saving = '◍ 保存中', error = '✗ 保存失敗' }

--- The page's numbers as one statusline string, matching what Cosense's web page menu
--- shows: `更新 43分前 · 閲覧 39 · 被リンク 6`, led by the unsaved badge when there is one.
--- Empty for a non-page buffer, so it can be dropped straight into lualine without a
--- condition. Plain text — pair it with `page_info_hl()` for colour.
function M.page_info(bufnr)
  local meta = page_meta(bufnr)
  if not meta then
    return ''
  end
  local parts = {}
  local badge = BADGE[state_by_bufnr[bufnr or vim.api.nvim_get_current_buf()]]
  if badge then
    parts[#parts + 1] = badge
  end
  local relative = require('chatora.actions').relative_time(meta.updated)
  if relative then
    parts[#parts + 1] = '更新 ' .. relative
  end
  if meta.views > 0 then
    parts[#parts + 1] = '閲覧 ' .. meta.views
  end
  if meta.linked > 0 then
    parts[#parts + 1] = '被リンク ' .. meta.linked
  end
  return table.concat(parts, ' · ')
end

--- Highlight group for `page_info()`: the save state's colour while the buffer differs
--- from the server, else the muted one the rest of the statusline uses. nil when
--- `page_info()` is empty.
---
--- For lualine: `{ require('chatora.status').page_info, color = function() return { fg = ... } end }`
--- is one way, but the group name works directly as lualine's `color`.
function M.page_info_hl(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not page_meta(bufnr) then
    return nil
  end
  local state = state_by_bufnr[bufnr]
  return BADGE[state] and HL_GROUP[state] or 'ChatoraStatusMuted'
end

return M
