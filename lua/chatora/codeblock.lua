-- Syntax highlighting inside Cosense code blocks (`code:<filename>`), via
-- treesitter, layered above the LSP's semantic-token 'codeBlock' coloring.
--
-- Cosense notation: a line `code:<name>` (optionally indented) starts a
-- block; every following line with indent strictly greater than the
-- marker's indent belongs to it (blank lines never end a block); the first
-- line at or below the marker's indent ends it.
local M = {}

local config = require('chatora.config')

M.ns = vim.api.nvim_create_namespace('chatora_codeblock')

local DEBOUNCE_MS = 150
-- Semantic tokens render at priority 125 (nvim default); stay above them.
local PRIORITY = 130

local uv = vim.uv or vim.loop
local timers_by_bufnr = {}

local function is_blank(line)
  return line:match('^%s*$') ~= nil
end

local function indent_of(line)
  return #(line:match('^[ \t]*'))
end

--- Pure scan of buffer `lines` (1-indexed array) for Cosense code blocks.
--- Returns a list of { marker_line, start_line, end_line, name }, all
--- 0-based; interior lines are [start_line, end_line) (end_line exclusive).
function M.find_blocks(lines)
  local blocks = {}
  local i = 1
  local n = #lines
  while i <= n do
    local indent, name = lines[i]:match('^([ \t]*)code:(.+)$')
    if name then
      name = name:gsub('%s+$', '')
      local marker_indent = #indent
      if name ~= '' then
        local j = i + 1
        while j <= n do
          local l = lines[j]
          if not is_blank(l) and indent_of(l) <= marker_indent then
            break
          end
          j = j + 1
        end
        blocks[#blocks + 1] = {
          marker_line = i - 1,
          start_line = i, -- 0-based: marker_line + 1
          end_line = j - 1, -- 0-based, exclusive
          name = name,
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

--- Resolve a treesitter lang for a `code:<name>` marker, or nil if no
--- parser is available. Tries filetype-by-extension first, then falls back
--- to treating the whole name as the lang (`code:lua`, `code:bash`, ...).
local function resolve_lang(name)
  local ok_ft, filetype = pcall(vim.filetype.match, { filename = name })
  if not ok_ft or not filetype or filetype == '' then
    filetype = name
  end
  local ok_get, lang = pcall(vim.treesitter.language.get_lang, filetype)
  if not ok_get or not lang then
    lang = filetype
  end
  -- vim.treesitter.language.add does NOT error on a missing parser; it
  -- returns (nil, message). Check the actual result, not just pcall's ok.
  local ok_add, added = pcall(vim.treesitter.language.add, lang)
  if not ok_add or not added then
    return nil
  end
  return lang
end

--- Interior text of a block, with the common leading indent stripped, plus
--- the amount stripped (needed to map string columns back to buffer columns).
local function block_text(lines, block)
  local raw = {}
  for ln = block.start_line + 1, block.end_line do
    raw[#raw + 1] = lines[ln]
  end
  if #raw == 0 then
    return nil, 0
  end

  local common
  for _, l in ipairs(raw) do
    if not is_blank(l) then
      local ind = indent_of(l)
      if not common or ind < common then
        common = ind
      end
    end
  end
  common = common or 0

  local stripped = {}
  for idx, l in ipairs(raw) do
    stripped[idx] = (#l >= common) and l:sub(common + 1) or ''
  end
  return table.concat(stripped, '\n'), common
end

local function highlight_block(bufnr, lines, block)
  local lang = resolve_lang(block.name)
  if not lang then
    return
  end

  local text, common_indent = block_text(lines, block)
  if not text or text == '' then
    return
  end

  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok_parser or not parser then
    return
  end

  local ok_trees, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_trees or not trees or not trees[1] then
    return
  end

  local ok_root, root = pcall(function()
    return trees[1]:root()
  end)
  if not ok_root or not root then
    return
  end

  local ok_query, query = pcall(vim.treesitter.query.get, lang, 'highlights')
  if not ok_query or not query then
    return
  end

  local hl_group_cache = {}
  pcall(function()
    for id, node in query:iter_captures(root, text, 0, -1) do
      local capture = query.captures[id]
      if capture then
        local hl_group = hl_group_cache[capture]
        if not hl_group then
          hl_group = '@' .. capture .. '.' .. lang
          hl_group_cache[capture] = hl_group
        end
        local srow, scol, erow, ecol = node:range()
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, block.start_line + srow, common_indent + scol, {
          end_row = block.start_line + erow,
          end_col = common_indent + ecol,
          hl_group = hl_group,
          priority = PRIORITY,
          strict = false,
        })
      end
    end
  end)
end

local function ensure_hl()
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  local cursorline = vim.api.nvim_get_hl(0, { name = 'CursorLine', link = false })
  local block_bg = cursorline and cursorline.bg or (normal and normal.bg) or nil
  vim.api.nvim_set_hl(0, 'ChatoraCodeBlock', { bg = block_bg, default = true })
  -- The filename reads as a tab above the block, the way Cosense's web UI
  -- draws it, so it takes the block's own background.
  vim.api.nvim_set_hl(0, 'ChatoraCodeLabel', { bg = block_bg, bold = true, default = true })
  vim.api.nvim_set_hl(0, 'ChatoraCodeLineNr', { link = 'LineNr', default = true })
end

--- Tint the block's interior, number its lines the way Cosense's web UI does,
--- and turn the `code:` marker into a bare filename label. The prefix is
--- concealed like any other notation, so the cursor line still shows what is
--- really in the buffer.
local function decorate_block(bufnr, lines, block)
  local count = block.end_line - block.start_line
  -- Numbering restarts per block and is padded to at least two digits, matching
  -- the web UI; wider blocks grow the gutter rather than misaligning.
  local width = math.max(2, #tostring(count))
  for lnum = block.start_line, block.end_line - 1 do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum, 0, {
      line_hl_group = 'ChatoraCodeBlock',
    })
    if config.options.codeblock_numbers ~= false then
      local n = ('%0' .. width .. 'd '):format(lnum - block.start_line + 1)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum, 0, {
        virt_text = { { n, 'ChatoraCodeLineNr' } },
        virt_text_pos = 'inline',
      })
    end
  end

  local marker = lines[block.marker_line + 1] or ''
  local prefix_start = indent_of(marker)
  local prefix_end = prefix_start + #'code:'
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, block.marker_line, prefix_start, {
    end_col = prefix_end,
    conceal = '',
  })
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, block.marker_line, prefix_end, {
    end_col = #marker,
    hl_group = 'ChatoraCodeLabel',
    priority = PRIORITY,
  })
end

--- Clear and re-decorate every code block in bufnr, synchronously.
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  ensure_hl()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ok, blocks = pcall(M.find_blocks, lines)
  if not ok then
    return
  end
  for _, block in ipairs(blocks) do
    pcall(decorate_block, bufnr, lines, block)
    pcall(highlight_block, bufnr, lines, block)
  end
end

local function schedule_refresh(bufnr)
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
        M.refresh(bufnr)
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

--- Attach to bufnr: highlight now, and keep re-highlighting (debounced) on
--- every buffer change. Safe to call more than once per buffer.
function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.b[bufnr].chatora_codeblock_attached then
    schedule_refresh(bufnr)
    return
  end
  vim.b[bufnr].chatora_codeblock_attached = true

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      schedule_refresh(bufnr)
    end,
    on_detach = function()
      cleanup_timer(bufnr)
      vim.schedule(function()
        pcall(vim.api.nvim_buf_set_var, bufnr, 'chatora_codeblock_attached', false)
      end)
    end,
  })

  schedule_refresh(bufnr)
end

return M
