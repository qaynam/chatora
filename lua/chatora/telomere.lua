-- Cosense's テロメア, in the sign column: a bar per line whose thickness says how recently
-- the line was written and whose colour says whether it moved since the reader last looked.
-- The page as a whole already has an updated time; this is the only thing that says *where*
-- it changed.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

--- Namespace of the bars, so a caller can read what is drawn.
M.ns = vim.api.nvim_create_namespace('chatora_telomere')

-- The eight widths a terminal cell can be filled to, thinnest first.
local BARS = { '▏', '▎', '▍', '▌', '▋', '▊', '▉', '█' }

--- Cosense's own telomere width in px for a line written `age` seconds ago:
--- `10 - floor(log10(hours + 2) * 2.3)`, never below 1 (calcTelomereWidth, web client).
local function width_px(age)
  local hours = math.max(0, age) / 3600
  return math.max(1, 10 - math.floor((math.log(hours + 2) / math.log(10)) * 2.3))
end

--- The bar drawn for a line written `age` seconds ago; thicker the more recent it is.
---
--- Cosense's ten steps are shifted down onto the eight a cell has, which spends them where
--- a reader is looking: its top two steps (anything from the last hour) become one full
--- block, and everything past a season the same thin rule.
function M.bar(age)
  return BARS[math.max(1, math.min(#BARS, width_px(age) - 2))]
end

--- Cosense's telomere colours, by what the bar is saying.
---
--- The blues are Cosense's own (`--telomere-unread` / `--telomere-updated`). The read bar
--- is derived from the theme instead of borrowing its `#e2e2e2`, which is a light-mode grey
--- and would glow on a dark background.
local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraTelomere', {
    fg = require('chatora.highlight').hairline(),
    default = true,
  })
  vim.api.nvim_set_hl(0, 'ChatoraTelomereUnread', { fg = '#89a3ff', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraTelomereUpdated', { fg = '#6b8cff', default = true })
  -- Text of the reader's own that the server has not seen. Cosense has no equivalent — it
  -- saves as you type — so this borrows the editor's vocabulary for a pending change.
  vim.api.nvim_set_hl(0, 'ChatoraTelomereLocal', { link = 'Changed', default = true })
end

--- Per-buffer history: `lines[i]` is what the server knows about buffer line i, and a line
--- the reader has since edited holds `own = true` instead.
local state = {}

local function enabled()
  return config.options.telomere ~= false
end

local function paint(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local st = state[bufnr]
  if not st then
    return
  end
  local now = os.time()
  for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
    local line = st.lines[row + 1]
    local text, hl
    if not line or line.own or line.updated == 0 then
      text, hl = BARS[#BARS], 'ChatoraTelomereLocal'
    else
      text = M.bar(now - line.updated)
      if line.updated > st.opened_at then
        -- Arrived while this buffer was open: a background sync brought it in.
        hl = 'ChatoraTelomereUpdated'
      elseif line.updated > st.accessed then
        hl = 'ChatoraTelomereUnread'
      else
        hl = 'ChatoraTelomere'
      end
    end
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, { sign_text = text, sign_hl_group = hl })
  end
end

local timers = {}

local function schedule_paint(bufnr)
  local timer = timers[bufnr]
  if timer then
    timer:stop()
  else
    timer = (vim.uv or vim.loop).new_timer()
    timers[bufnr] = timer
  end
  timer:start(
    50,
    0,
    vim.schedule_wrap(function()
      paint(bufnr)
    end)
  )
end

--- Take the reader's edit over the server's history for the lines it touched.
---
--- `on_lines` reports the replacement in buffer rows, which is exactly what the history is
--- indexed by, so the two stay aligned without asking the server anything.
local function splice(bufnr, first, last_old, last_new)
  local st = state[bufnr]
  if not st then
    return
  end
  local head = vim.list_slice(st.lines, 1, first)
  local tail = vim.list_slice(st.lines, last_old + 1)
  local fresh = {}
  for _ = first + 1, last_new do
    fresh[#fresh + 1] = { own = true }
  end
  st.lines = vim.list_extend(vim.list_extend(head, fresh), tail)
end

--- Every window showing the buffer needs somewhere to draw: a reader whose `signcolumn` is
--- off would otherwise see the feature do nothing at all. A column they asked for by any
--- other setting is left as they set it.
local function ensure_signcolumn(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].signcolumn == 'no' then
      vim.wo[win].signcolumn = 'yes:1'
    end
  end
end

--- Ask the server what it knows about the lines the buffer currently holds, and redraw.
---
--- The lines go with the request rather than being read from the synced document, which
--- this can outrun — see `chatora/telomere`.
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not enabled() or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local sent = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tick = vim.b[bufnr].changedtick
  local params = { uri = vim.api.nvim_buf_get_name(bufnr), lines = sent }
  lsp.request_ok('chatora/telomere', params, function(result)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].changedtick ~= tick then
      return
    end
    local st = state[bufnr] or {}
    st.accessed = result.accessed or 0
    -- Fixed at the first answer: it is what separates "this was here when I arrived" from
    -- "this turned up while I was reading".
    st.opened_at = st.opened_at or os.time()
    st.lines = result.lines or {}
    state[bufnr] = st
    ensure_signcolumn(bufnr)
    paint(bufnr)
  end)
end

-- Bars thin as their lines age, which no edit and no reply announces. Cosense redraws
-- hourly for the same reason; one timer covers every attached buffer.
local AGE_TICK_MS = 3600 * 1000
local age_timer

local function ensure_age_timer()
  if age_timer then
    return
  end
  age_timer = (vim.uv or vim.loop).new_timer()
  age_timer:start(
    AGE_TICK_MS,
    AGE_TICK_MS,
    vim.schedule_wrap(function()
      for bufnr in pairs(state) do
        paint(bufnr)
      end
    end)
  )
end

local function forget(bufnr)
  state[bufnr] = nil
  local timer = timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
    timers[bufnr] = nil
  end
end

function M.attach(bufnr)
  if not enabled() or vim.b[bufnr].chatora_telomere_attached then
    return
  end
  vim.b[bufnr].chatora_telomere_attached = true
  ensure_hl()
  ensure_age_timer()

  local group = vim.api.nvim_create_augroup('ChatoraTelomere' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = bufnr,
    callback = function()
      ensure_signcolumn(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      ensure_hl()
      paint(bufnr)
    end,
  })

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, _, first, last_old, last_new)
      splice(bufnr, first, last_old, last_new)
      schedule_paint(bufnr)
    end,
    on_detach = function()
      vim.schedule(function()
        pcall(vim.api.nvim_buf_set_var, bufnr, 'chatora_telomere_attached', false)
        forget(bufnr)
      end)
    end,
  })

  M.refresh(bufnr)
end

return M
