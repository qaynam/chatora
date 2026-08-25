-- Keeps link completion alive through multi-word queries: clients end their
-- menu at a space, so re-open it whenever the cursor is inside a bracket and
-- nothing is showing. (The other half of the problem — clients re-filtering the
-- server's fuzzy ranking away — is handled server-side in completion.ts.)
local M = {}

local uv = vim.uv or vim.loop
local REOPEN_DEBOUNCE_MS = 120

--- The `[...]` the cursor sits inside, as the 1-based byte positions of its brackets, or
--- nil. Mirrors the server's detectLink: the pair has to be closed, and `[[` is not one.
function M.link_range(line, col)
  local open = nil
  for i = col, 1, -1 do
    local ch = line:sub(i, i)
    if ch == ']' then
      return nil
    end
    if ch == '[' then
      if line:sub(i - 1, i - 1) == '[' then
        return nil
      end
      open = i
      break
    end
  end
  if not open then
    return nil
  end
  for j = col + 1, #line do
    local ch = line:sub(j, j)
    if ch == '[' then
      return nil
    end
    if ch == ']' then
      return open, j
    end
  end
  return nil
end

local function in_link_context(line, col)
  return M.link_range(line, col) ~= nil
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
  pcall(vim.lsp.completion.enable, true, client.id, bufnr, {
    autotrigger = true,
    -- Vim filters the open menu by `word` between a keystroke and the debounced
    -- re-query; the default (a page title) makes items vanish mid-query, while
    -- filterText — the typed text — always matches. Insertion still comes from
    -- the item's textEdit on CompleteDone.
    convert = function(item)
      return { word = item.filterText or item.label, abbr = item.label }
    end,
  })
  vim.b[bufnr].chatora_native_completion = true
end

function M.attach(bufnr)
  enable_native_if_needed(bufnr)
  if vim.b[bufnr].chatora_completion_attached then
    return
  end
  vim.b[bufnr].chatora_completion_attached = true

  -- Debounced: re-opening on every keystroke would put a request (and a
  -- server-side search) behind each one, and the client does its own
  -- isIncomplete re-query anyway once a menu is up. The delay only ever costs
  -- the first character after the menu closed.
  local timer = nil
  local function stop()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end

  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = bufnr,
    callback = function()
      -- A visible menu is already re-querying itself, so only step in once it
      -- has closed — typing a space, or a keystroke that left the client with
      -- nothing to show.
      if tonumber(vim.fn.pumvisible()) == 1 then
        stop()
        return
      end
      local col = vim.api.nvim_win_get_cursor(0)[2]
      if col == 0 or not in_link_context(vim.api.nvim_get_current_line(), col) then
        stop()
        return
      end
      if not timer then
        timer = uv.new_timer()
      end
      timer:stop()
      timer:start(
        REOPEN_DEBOUNCE_MS,
        0,
        vim.schedule_wrap(function()
          if vim.api.nvim_get_current_buf() == bufnr and tonumber(vim.fn.pumvisible()) ~= 1 then
            show_menu(bufnr)
          end
        end)
      )
    end,
  })

  vim.api.nvim_create_autocmd({ 'InsertLeave', 'BufUnload' }, { buffer = bufnr, callback = stop })
end

--- The page title out of a completion entry, whatever shape the engine hands it in. The
--- server puts it in `label`; a menu that only kept the inserted form has it bracketed.
function M.title_of(item)
  if type(item) ~= 'table' then
    return nil
  end
  local label = item.label or item.abbr or item.word
  if type(label) ~= 'string' or label == '' then
    return nil
  end
  label = label:gsub('^%[', ''):gsub('%]$', ''):gsub('^#', '')
  return label ~= '' and label or nil
end

-- Completion engines each own their menu, and none of them agree on how to ask what is
-- selected — so all three are tried and whichever is installed answers.
local SELECTED = {
  function()
    local ok, blink = pcall(require, 'blink.cmp')
    if ok and type(blink.get_selected_item) == 'function' then
      return blink.get_selected_item()
    end
  end,
  function()
    local ok, cmp = pcall(require, 'cmp')
    if ok and type(cmp.get_selected_entry) == 'function' then
      local entry = cmp.get_selected_entry()
      return entry and entry:get_completion_item() or nil
    end
  end,
  function()
    if tonumber(vim.fn.pumvisible()) ~= 1 then
      return nil
    end
    local info = vim.fn.complete_info({ 'selected', 'items' })
    -- -1 is "the menu is open but nothing is highlighted".
    return (info.selected or -1) >= 0 and (info.items or {})[info.selected + 1] or nil
  end,
}

--- The page title the completion menu currently has highlighted, or nil when no menu is
--- open, nothing in it is selected, or the entry is not a page.
function M.selected_title()
  for _, ask in ipairs(SELECTED) do
    local ok, item = pcall(ask)
    if ok and item then
      local title = M.title_of(item)
      if title then
        return title
      end
    end
  end
  return nil
end

--- Close the menu, so the edit that follows is not read as another keystroke into it.
function M.dismiss()
  local ok, blink = pcall(require, 'blink.cmp')
  if ok and type(blink.hide) == 'function' then
    pcall(blink.hide)
  end
  local ok_cmp, cmp = pcall(require, 'cmp')
  if ok_cmp and type(cmp.close) == 'function' then
    pcall(cmp.close)
  end
  if tonumber(vim.fn.pumvisible()) == 1 then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-e>', true, false, true), 'n', false)
  end
end

return M
