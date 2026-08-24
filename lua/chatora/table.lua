-- Rendering for Cosense `table:` blocks (render-markdown.nvim style): tab-
-- separated cells are shown as an aligned grid via extmarks only, so the
-- buffer text (and therefore what gets saved) never changes.
--
-- Cosense notation: a line `table:<name>` (optionally indented) starts a
-- block; every following line with indent strictly greater than the marker's
-- indent belongs to it. A blank line, or a line at or below the marker's
-- indent, ends it. Body lines hold tab-separated cells; rows may have
-- differing cell counts.
local M = {}

local config = require('chatora.config')

M.ns = vim.api.nvim_create_namespace('chatora_table')

local DEBOUNCE_MS = 150
local uv = vim.uv or vim.loop
local timers_by_bufnr = {}

local function is_blank(line)
  return line:match('^%s*$') ~= nil
end

local function indent_of(line)
  return #(line:match('^%s*'))
end

--- Pure scan of buffer `lines` (1-indexed array) for Cosense table blocks.
--- Returns a list of { marker_line, start_line, end_line, name, rows }, all
--- line numbers 0-based; interior lines are [start_line, end_line) (end_line
--- exclusive), matching codeblock.lua's convention. Each row is
--- { indent = <leading whitespace char count>, cells = { <tab-split text> } }.
function M.find_blocks(lines)
  local blocks = {}
  local i = 1
  local n = #lines
  while i <= n do
    local indent, name = lines[i]:match('^(%s*)table:(.*)$')
    if name then
      name = name:gsub('%s+$', '')
      local marker_indent = #indent
      if name ~= '' then
        -- The blank-line rule is the one place tables differ from `code:`
        -- blocks (matching @cosense-toolbox/parser); treating blanks as
        -- interior swallows every later indented line as another row.
        local j = i + 1
        while j <= n and not is_blank(lines[j]) and indent_of(lines[j]) > marker_indent do
          j = j + 1
        end

        local rows = {}
        for ln = i + 1, j - 1 do
          local l = lines[ln]
          local row_indent = indent_of(l)
          local content = l:sub(row_indent + 1) .. '\t'
          local cells = {}
          for cell in content:gmatch('(.-)\t') do
            cells[#cells + 1] = cell
          end
          rows[#rows + 1] = { indent = row_indent, cells = cells }
        end

        blocks[#blocks + 1] = {
          marker_line = i - 1,
          start_line = i,
          end_line = j - 1,
          name = name,
          rows = rows,
        }
        i = j
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return blocks
end

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraTableBorder', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraTableHeader', { bold = true, default = true })
  vim.api.nvim_set_hl(0, 'ChatoraTableSeparator', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraTableLabel', { link = 'Label', default = true })
end

--- Turn the `table:` marker into a bare name label. The prefix is concealed
--- like any other notation, so the cursor line still shows the real text.
local function render_marker(bufnr, lines, block)
  local marker = lines[block.marker_line + 1] or ''
  local prefix_start = indent_of(marker)
  local prefix_end = prefix_start + #'table:'
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, block.marker_line, prefix_start, {
    end_col = prefix_end,
    conceal = '',
  })
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, block.marker_line, prefix_end, {
    end_col = #marker,
    hl_group = 'ChatoraTableLabel',
  })
end

local function set_win_opts(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = ''
  end
end

--- Resolve the `tables` option into per-feature flags. `true` (the default)
--- enables both; a table selectively disables one via `border`/`header` set
--- to `false` (any other value, including omission, stays enabled).
local function table_opts()
  local opt = config.options.tables
  local border, header = true, true
  if type(opt) == 'table' then
    if opt.border == false then
      border = false
    end
    if opt.header == false then
      header = false
    end
  end
  return border, header
end

--- 0-based cursor line if bufnr is showing in the current window, else nil.
--- Used to hide inline decoration on the cursor's row (anti-conceal).
local function cursor_row(bufnr)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return nil
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok then
    return nil
  end
  return cursor[1] - 1
end

--- A border line for `widths` columns. Each column is drawn one cell wider on
--- both sides than its content, matching the ` ` that `render_row` puts inside
--- every `│`.
local function build_border(widths, left, junction, right, fill)
  if #widths == 0 then
    return ''
  end
  local parts = { left }
  for i, w in ipairs(widths) do
    parts[#parts + 1] = string.rep(fill, w + 2)
    parts[#parts + 1] = (i == #widths) and right or junction
  end
  return table.concat(parts)
end

--- Draw one row as `│ cell │ cell │`: the inter-cell tabs are concealed and
--- replaced by the separators, each cell is padded out to its column width, and
--- the row is closed on both sides so it lines up with the border lines. Rows
--- with fewer cells than the table has columns get the rest as empty ones.
--- Skipped entirely on the cursor's row (anti-conceal), since inline virt_text
--- isn't hidden by 'concealcursor' the way `conceal` ranges are.
local function render_row(bufnr, line_no, row, widths)
  local ncells = #row.cells
  if ncells == 0 then
    return
  end

  local function mark(col, opts)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line_no, col, opts)
  end

  mark(row.indent, {
    virt_text = { { '│ ', 'ChatoraTableBorder' } },
    virt_text_pos = 'inline',
  })

  local col = row.indent
  for idx, cell in ipairs(row.cells) do
    local cell_end = col + #cell
    local chunks = {}
    local pad_n = (widths[idx] or 0) - vim.fn.strdisplaywidth(cell)
    if pad_n > 0 then
      chunks[#chunks + 1] = { string.rep(' ', pad_n) }
    end

    if idx < ncells then
      chunks[#chunks + 1] = { ' │ ', 'ChatoraTableBorder' }
      mark(cell_end, {
        end_col = cell_end + 1,
        conceal = '',
        virt_text = chunks,
        virt_text_pos = 'inline',
      })
      col = cell_end + 1
    else
      for missing = idx + 1, #widths do
        chunks[#chunks + 1] = { ' │ ', 'ChatoraTableBorder' }
        chunks[#chunks + 1] = { string.rep(' ', widths[missing]) }
      end
      chunks[#chunks + 1] = { ' │', 'ChatoraTableBorder' }
      mark(cell_end, { virt_text = chunks, virt_text_pos = 'inline' })
    end
  end
end

local function render_borders(bufnr, lines, block, widths, header_enabled)
  local first_line_no = block.start_line
  local last_line_no = block.end_line - 1
  local first_indent = block.rows[1].indent
  local last_indent = block.rows[#block.rows].indent
  local first_prefix = (lines[first_line_no + 1] or ''):sub(1, first_indent)
  local last_prefix = (lines[last_line_no + 1] or ''):sub(1, last_indent)

  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, first_line_no, 0, {
    virt_lines = { { { first_prefix .. build_border(widths, '╭', '┬', '╮', '─'), 'ChatoraTableBorder' } } },
    virt_lines_above = true,
  })

  if header_enabled and #block.rows >= 2 then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, first_line_no, 0, {
      virt_lines = { { { first_prefix .. build_border(widths, '├', '┼', '┤', '─'), 'ChatoraTableSeparator' } } },
      virt_lines_above = false,
    })
  end

  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, last_line_no, 0, {
    virt_lines = { { { last_prefix .. build_border(widths, '╰', '┴', '╯', '─'), 'ChatoraTableBorder' } } },
    virt_lines_above = false,
  })
end

local function render_block(bufnr, lines, block, border_enabled, header_enabled, active_line)
  if active_line ~= block.marker_line then
    render_marker(bufnr, lines, block)
  end
  local rows = block.rows
  if #rows == 0 then
    return
  end

  local ncols = 0
  for _, row in ipairs(rows) do
    if #row.cells > ncols then
      ncols = #row.cells
    end
  end

  local widths = {}
  for c = 1, ncols do
    local w = 0
    for _, row in ipairs(rows) do
      local cell = row.cells[c]
      if cell then
        w = math.max(w, vim.fn.strdisplaywidth(cell))
      end
    end
    widths[c] = w
  end

  for idx, row in ipairs(rows) do
    local line_no = block.start_line + idx - 1
    if active_line ~= line_no then
      render_row(bufnr, line_no, row, widths)
    end
    if header_enabled and idx == 1 then
      local line_text = lines[line_no + 1] or ''
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line_no, row.indent, {
        end_col = #line_text,
        hl_group = 'ChatoraTableHeader',
        hl_mode = 'combine',
      })
    end
  end

  if border_enabled then
    render_borders(bufnr, lines, block, widths, header_enabled)
  end
end

--- Clear and re-lay-out every table block in bufnr, synchronously.
function M.render(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  ensure_hl()
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  if config.options.tables == false then
    return
  end

  local border_enabled, header_enabled = table_opts()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ok, blocks = pcall(M.find_blocks, lines)
  if not ok then
    return
  end

  local active_line = cursor_row(bufnr)
  for _, block in ipairs(blocks) do
    pcall(render_block, bufnr, lines, block, border_enabled, header_enabled, active_line)
  end
end

local function schedule_render(bufnr)
  local timer = timers_by_bufnr[bufnr]
  if not timer then
    timer = uv.new_timer()
    timers_by_bufnr[bufnr] = timer
  end
  pcall(function()
    timer:stop()
    timer:start(
      DEBOUNCE_MS,
      0,
      vim.schedule_wrap(function()
        M.render(bufnr)
      end)
    )
  end)
end

local function cleanup_timer(bufnr)
  local timer = timers_by_bufnr[bufnr]
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    timers_by_bufnr[bufnr] = nil
  end
end

--- Attach to bufnr: render now, keep re-laying-out (debounced) on every
--- buffer change, and redraw immediately on cursor move so the row under
--- the cursor shows its raw tab-separated source (anti-conceal). Safe to
--- call more than once per buffer.
function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  set_win_opts(bufnr)
  M.render(bufnr)

  if vim.b[bufnr].chatora_table_attached then
    return
  end
  vim.b[bufnr].chatora_table_attached = true

  vim.api.nvim_create_autocmd('BufWinEnter', {
    buffer = bufnr,
    callback = function()
      set_win_opts(bufnr)
    end,
  })

  -- Cursor moves must redraw synchronously (not debounced): a delayed
  -- reveal of the raw source under the cursor reads as jitter.
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    buffer = bufnr,
    callback = function()
      M.render(bufnr)
    end,
  })

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      schedule_render(bufnr)
    end,
    on_detach = function()
      cleanup_timer(bufnr)
      vim.schedule(function()
        pcall(vim.api.nvim_buf_set_var, bufnr, 'chatora_table_attached', false)
      end)
    end,
  })
end

return M
