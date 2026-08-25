-- Cosense-style bullet pads: every indented, non-blank line gets a bullet before its text
-- and a cell of widening per level above it (1 whitespace char = 1 indent level, per
-- Cosense notation). Doubles as the indent guide for page buffers — general indent plugins
-- (snacks.indent etc.) skip buftype=acwrite buffers.
local M = {}

local config = require('chatora.config')

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
local DEFAULTS = { bullet = '●', guide = false, spacing = true, gap = 0 }

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

--- Display cells the inline pads add before the text of `line`, which has `indent` leading
--- whitespace chars. Anything positioned by text column (inline images) must shift right by
--- this much to stay aligned. The indent characters themselves are not counted: they are
--- real cells that the pads only draw between.
function M.extra_cells(indent, line)
  if config.options.pads == false or indent <= 0 then
    return 0
  end
  local bullet, _, spacing, gap = pad_opts()
  local width = spacing and indent - 1 or 0
  if not (line and line:match('^[ \t]+%d+%.')) then
    width = width + vim.fn.strdisplaywidth(bullet) + gap
  end
  return width
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
      local ws = line:match('^([ \t]+)')
      if ws then
        local n = #ws
        -- A line that numbers itself already has a marker, and Cosense drops the bullet for
        -- it rather than showing both. The indent still gets its widening, so a numbered
        -- item and a bulleted one at the same depth line up.
        local numbered = line:match('^[ \t]+%d+%.') ~= nil
        for i = 0, n - 1 do
          local last = i == n - 1
          -- One inline run per indent character, drawn before it: the widening that makes
          -- each level read as a step, and on the last level the bullet too.
          local chunks = {}
          if i > 0 and spacing then
            chunks[#chunks + 1] = { ' ', 'ChatoraPadGuide' }
          end
          if last and not numbered then
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
