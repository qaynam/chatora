-- Cosense shows a page's own picture beside its title in the suggestion list. A completion
-- engine draws its menu into an ordinary buffer in a floating window, so the picture can go
-- there too: one per visible row, in the blank cells that follow the title.
--
-- Only nvim-cmp's custom view is read here. Its menu buffer holds one line per entry, in
-- the order `cmp.get_entries()` returns them, which is what makes a row nameable at all.
-- Neovim's own popup menu is drawn by the UI rather than into a buffer, so nothing can be
-- placed in it.
local M = {}

local images = require('chatora.images')
local uri = require('chatora.uri')

local MENU_FILETYPE = 'cmp_menu'
-- Fetched once per page and cached; the cell it lands in is two columns wide.
local ICON_PX = 64
local ICON_CELLS = 2
-- The menu is rewritten on every keystroke, so drawing waits for the typing to settle.
local DEBOUNCE_MS = 80

local uv = vim.uv or vim.loop
local placed = {}
local menu_buf = nil
local timer = nil

local function options()
  return require('chatora.config').options.image
end

local function enabled()
  local image = options()
  return image.enabled ~= false and image.completion ~= false
end

--- Take every icon down. Placements are bound to the window they were made in, so a menu
--- that closed leaves nothing behind to reuse.
function M.clear()
  for _, entry in pairs(placed) do
    pcall(entry.close)
  end
  placed = {}
  menu_buf = nil
end

--- The window and buffer of an open completion menu, or nil when none is up.
local function menu_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
    if ok and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == MENU_FILETYPE then
      return win, buf
    end
  end
  return nil, nil
end

--- The page title each row of the menu stands for, by 0-based row.
local function titles_by_row()
  local ok, cmp = pcall(require, 'cmp')
  if not ok or type(cmp.get_entries) ~= 'function' then
    return {}
  end
  local ok_entries, entries = pcall(cmp.get_entries)
  if not ok_entries or type(entries) ~= 'table' then
    return {}
  end
  local titles = {}
  for i, entry in ipairs(entries) do
    local ok_item, item = pcall(entry.get_completion_item, entry)
    local title = ok_item and type(item) == 'table' and require('chatora.completion').title_of(item)
    titles[i - 1] = title or nil
  end
  return titles
end

--- Where the icon goes on `line`: after the title, in the padding the menu leaves before
--- the next column. nil when the title is not on the line as written — a formatter the
--- reader configured may have changed it, and guessing a column would draw over text.
function M.icon_column(line, title)
  local start = line:find(title, 1, true)
  if not start then
    return nil
  end
  local byte_col = start - 1 + #title
  if line:sub(byte_col + 1, byte_col + ICON_CELLS) ~= string.rep(' ', ICON_CELLS) then
    return nil
  end
  return byte_col, vim.fn.strdisplaywidth(line:sub(1, byte_col))
end

--- Draw the icon of every row on screen, and take down the ones whose row now holds
--- another page. The fetch behind each is cached, so a settled menu costs nothing.
function M.draw()
  if not enabled() then
    return M.clear()
  end
  local win, buf = menu_window()
  if not win or not buf then
    return M.clear()
  end
  if menu_buf ~= buf then
    M.clear()
    menu_buf = buf
  end
  local project = uri.parse(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
  if not project then
    return M.clear()
  end
  local origin = require('chatora.config').options.origin
  local titles = titles_by_row()
  local top, bottom
  vim.api.nvim_win_call(win, function()
    top, bottom = vim.fn.line('w0') - 1, vim.fn.line('w$') - 1
  end)
  local lines = vim.api.nvim_buf_get_lines(buf, top, bottom + 1, false)

  for row, entry in pairs(placed) do
    if titles[row] ~= entry.title or row < top or row > bottom then
      pcall(entry.close)
      placed[row] = nil
    end
  end

  for row = top, bottom do
    local title = titles[row]
    local line = lines[row - top + 1]
    if title and line and not placed[row] then
      local byte_col, screen_col = M.icon_column(line, title)
      if byte_col then
        local entry = { title = title, close = function() end }
        placed[row] = entry
        images.place_one(buf, project, images.icon_url(origin, project, title), row, byte_col, function(placement)
          -- The menu moved on while the picture was being fetched.
          if placed[row] ~= entry or not vim.api.nvim_buf_is_valid(buf) then
            pcall(placement.close)
            return
          end
          entry.close = placement.close
        end, { thumb = ICON_PX, cells = ICON_CELLS, screen_col = screen_col, conceal = true })
      end
    end
  end
end

local function schedule_draw()
  if not timer then
    timer = uv.new_timer()
  end
  timer:stop()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(M.draw))
end

--- Follow the menu of `bufnr`'s insert mode. Once per buffer: the autocmds live as long as
--- the buffer does.
function M.attach(bufnr)
  if vim.b[bufnr].chatora_completion_icons then
    return
  end
  vim.b[bufnr].chatora_completion_icons = true
  vim.api.nvim_create_autocmd('TextChangedI', { buffer = bufnr, callback = schedule_draw })
  vim.api.nvim_create_autocmd({ 'InsertLeave', 'BufUnload' }, {
    buffer = bufnr,
    callback = function()
      if timer then
        timer:stop()
      end
      M.clear()
    end,
  })
  local ok, cmp = pcall(require, 'cmp')
  if ok and type(cmp.event) == 'table' and type(cmp.event.on) == 'function' then
    cmp.event:on('menu_opened', schedule_draw)
    cmp.event:on('menu_closed', function()
      M.clear()
    end)
  end
end

return M
