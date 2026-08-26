-- Cosense-style bullet pads: every indented, non-blank line gets a bullet before its text
-- and a cell of widening per level above it (1 whitespace char = 1 indent level, per
-- Cosense notation). Doubles as the indent guide for page buffers — general indent plugins
-- (snacks.indent etc.) skip buftype=acwrite buffers.
local M = {}

local config = require('chatora.config')
local indent = require('chatora.indent')

M.ns = vim.api.nvim_create_namespace('chatora_pads')

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraPadGuide', { link = 'NonText', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraPadBullet', { link = 'Comment', default = true })
end

-- Two rules keep the text and the cursor where they belong, both asserted in
-- tests/smoke.lua. The bullet is inline virtual text rather than an overlay, because an
-- overlay replaces a fixed cell while a glyph's width belongs to the font — '●' is East
-- Asian Ambiguous, and drawn two cells wide it would paint over the line's first real
-- character. And it is anchored to the last indent character rather than to the text, so
-- nothing is drawn at the first text byte: Neovim renders an end-of-line cursor *before*
-- inline text, which on an empty list item would otherwise leave the cursor a cell left of
-- where typing lands. That displaced indent character is also the gap the bullet needs, so
-- `gap` is only ever extra slack.
local DEFAULTS = { bullet = '•', guide = false, spacing = true, gap = 0 }

-- Cells one level occupies once padded. A full-width space and a tab (at the default
-- tabstop) already take two, so this is the width every level can be brought up to —
-- shrinking one is not possible, since the characters are real buffer text.
local LEVEL_CELLS = 2

--- A line that carries its own `1.` marker; Cosense drops the bullet for it.
local function numbered(line)
  if not line then
    return false
  end
  return line:sub(indent.text_at(line) + 1):match('^%d+%.') ~= nil
end

local function pad_opts()
  local opts = config.options.pads
  if type(opts) ~= 'table' then
    return DEFAULTS.bullet, DEFAULTS.guide, DEFAULTS.spacing, DEFAULTS.gap
  end
  local guide = opts.guide
  if guide == nil then
    guide = DEFAULTS.guide
  end
  return opts.bullet or DEFAULTS.bullet,
    guide,
    opts.spacing ~= false,
    type(opts.gap) == 'number' and math.max(0, math.floor(opts.gap)) or DEFAULTS.gap
end

--- Display cells the inline pads add before `line`'s text. Anything positioned by text
--- column (inline images) must shift right by this much to stay aligned. The indent
--- characters themselves are not counted: they are real cells the pads only draw between.
--- Padding to draw before each indent character so that every level ends the same number
--- of cells in, whatever character wrote it.
---
--- Walked with a running column rather than computed per character, because a tab's width
--- is not a property of the tab: it reaches the next tab stop from wherever it starts, and
--- inserting padding ahead of it moves that. A level that has already overshot its target
--- gets no padding — the indent is real buffer text and cannot be made narrower.
local function level_pads(line, tabstop)
  local levels = indent.scan(line)
  local _, _, spacing = pad_opts()
  local pads, col = {}, 0
  for level, entry in ipairs(levels) do
    local target = level * LEVEL_CELLS
    local start = col
    if spacing then
      -- A tab is padded to start one cell short of the target so it ends on the tab stop
      -- there; anything else is padded by exactly what it is short of covering.
      start = entry.char == '\t' and math.max(col, target - 1)
        or math.max(col, target - indent.cells(entry.char, tabstop))
    end
    pads[level] = start - col
    col = entry.char == '\t' and (math.floor(start / tabstop) + 1) * tabstop
      or start + indent.cells(entry.char, tabstop)
  end
  return pads
end

--- Display cells the inline pads add before `line`'s text. Anything positioned by text
--- column (inline images) must shift right by this much to stay aligned.
function M.extra_cells(line, tabstop)
  line = line or ''
  if config.options.pads == false or indent.level(line) == 0 then
    return 0
  end
  local bullet, _, _, gap = pad_opts()
  local width = 0
  for _, pad in ipairs(level_pads(line, tabstop or vim.o.tabstop)) do
    width = width + pad
  end
  if not numbered(line) then
    width = width + vim.fn.strdisplaywidth(bullet) + gap
  end
  return width
end

--- The bullet glyph in effect, for callers that need to recognise one on screen.
function M.default_bullet()
  return (pad_opts())
end

function M.render(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  if config.options.pads == false then
    return
  end
  local bullet, guide, spacing, gap = pad_opts()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Code block interiors are indented code, and table block interiors are
  -- grid rows — neither is a list item, so no pads there. (The `code:...` /
  -- `table:...` marker lines themselves keep their pads: their indent is
  -- list structure.)
  local in_block = {}
  for _, block in ipairs(require('chatora.codeblock').find_blocks(lines)) do
    for l = block.start_line, block.end_line - 1 do
      in_block[l] = true
    end
  end
  for _, block in ipairs(require('chatora.table').find_blocks(lines)) do
    for l = block.start_line, block.end_line - 1 do
      in_block[l] = true
    end
  end
  for lnum, line in ipairs(lines) do
    -- Line 1 is the page title. Indent-only lines DO get pads — Cosense
    -- shows the bullet on an empty list item too.
    if lnum > 1 and not in_block[lnum - 1] then
      local levels = indent.scan(line)
      if #levels > 0 then
        -- A line that numbers itself already has a marker, and Cosense drops the bullet for
        -- it rather than showing both. The indent still gets its widening, so a numbered
        -- item and a bulleted one at the same depth line up.
        local is_numbered = numbered(line)
        local pads = level_pads(line, vim.bo[bufnr].tabstop)
        for level, entry in ipairs(levels) do
          local i = entry.at
          local last = level == #levels
          -- One inline run per indent character, drawn before it: the padding that brings
          -- this level up to a fixed width, and on the last level the bullet too. The
          -- padding is what makes depth mean the same thing whatever wrote it — a line
          -- indented with spaces would otherwise sit at half the depth of a sibling
          -- indented with tabs or full-width spaces.
          local chunks = {}
          if pads[level] > 0 then
            chunks[#chunks + 1] = { string.rep(' ', pads[level]), 'ChatoraPadGuide' }
          end
          if last and not is_numbered then
            chunks[#chunks + 1] = { bullet, 'ChatoraPadBullet' }
            if gap > 0 then
              chunks[#chunks + 1] = { string.rep(' ', gap), 'ChatoraPadGuide' }
            end
          end
          if #chunks > 0 then
            vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, i, {
              virt_text = chunks,
              virt_text_pos = 'inline',
            })
          end
          -- Guides mark the levels above this one, so they land on the indent characters
          -- the bullet does not. An overlay is right here: a guide sits *on* its column.
          if guide and not last then
            vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, i, {
              virt_text = { { guide, 'ChatoraPadGuide' } },
              virt_text_pos = 'overlay',
              hl_mode = 'combine',
            })
          end
        end
      end
    end
  end
end

function M.attach(bufnr)
  ensure_hl()
  M.render(bufnr)
  if vim.b[bufnr].chatora_pads_attached then
    return
  end
  vim.b[bufnr].chatora_pads_attached = true
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      vim.schedule(function()
        M.render(bufnr)
      end)
    end,
    on_detach = function()
      vim.schedule(function()
        pcall(vim.api.nvim_buf_set_var, bufnr, 'chatora_pads_attached', false)
      end)
    end,
  })
end

return M
