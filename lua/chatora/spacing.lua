-- Extra breathing room between lines, approximated with blank virtual lines.
-- A terminal cell has one fixed height, so real line-height is a terminal/GUI
-- setting ('linespace' in Neovide and other GUIs), not something a plugin can
-- change; blank rows are the closest a TUI can get.
local M = {}

local config = require('chatora.config')

M.ns = vim.api.nvim_create_namespace('chatora_spacing')

local function settings()
  local raw = config.options.spacing
  if type(raw) ~= 'table' then
    return { line = 0, code = 0 }
  end
  return { line = tonumber(raw.line) or 0, code = tonumber(raw.code) or 0 }
end

local function blank_virt_lines(count)
  local out = {}
  for i = 1, count do
    out[i] = { { '', 'Normal' } }
  end
  return out
end

--- 0-based line numbers that belong to a code block interior, and to a table
--- block. Tables draw their own frame out of virtual lines, so a blank row
--- inserted mid-frame would break it.
local function classify(lines)
  local in_code, in_table = {}, {}
  local ok_code, codeblock = pcall(require, 'chatora.codeblock')
  if ok_code then
    for _, block in ipairs(codeblock.find_blocks(lines)) do
      for l = block.start_line, block.end_line - 1 do
        in_code[l] = true
      end
    end
  end
  local ok_table, tables = pcall(require, 'chatora.table')
  if ok_table and type(tables.find_blocks) == 'function' then
    for _, block in ipairs(tables.find_blocks(lines)) do
      for l = block.marker_line, block.end_line - 1 do
        in_table[l] = true
      end
    end
  end
  return in_code, in_table
end

function M.render(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local opts = settings()
  if opts.line <= 0 and opts.code <= 0 then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_code, in_table = classify(lines)
  local body_gap = blank_virt_lines(opts.line)
  local code_gap = blank_virt_lines(opts.code)

  -- Gaps go *between* lines: not after the last line, and not after line 1
  -- (the page title), which has its own `title_margin`.
  for lnum = 1, #lines - 2 do
    local gap = in_code[lnum] and code_gap or body_gap
    if #gap > 0 and not in_table[lnum] then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum, 0, { virt_lines = gap })
    end
  end
end

function M.attach(bufnr)
  M.render(bufnr)
  if vim.b[bufnr].chatora_spacing_attached then
    return
  end
  vim.b[bufnr].chatora_spacing_attached = true
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      vim.schedule(function()
        M.render(bufnr)
      end)
    end,
    on_detach = function()
      vim.schedule(function()
        pcall(vim.api.nvim_buf_set_var, bufnr, 'chatora_spacing_attached', false)
      end)
    end,
  })
end

return M
