-- Blockquotes the way the web client draws them: the `>` marker is overlaid with a vertical
-- bar and the quoted text sits on a box. The bar's thickness is a property of the glyph
-- (▏ ▎ ▍ ▌ ┃), so `quote.bar` is the one knob for it; color comes from the two highlight
-- groups.
local M = {}

local config = require('chatora.config')
local indent = require('chatora.indent')

M.ns = vim.api.nvim_create_namespace('chatora_quote')

-- Under the semantic token priority (125) so a link or inline code inside a quote keeps
-- its own color; hl_mode='combine' still lets the box show under them.
local BODY_PRIORITY = 100

local DEFAULT_BAR = '▌'

-- Cells 'breakindentopt' shifts a wrapped row by, on top of the line's indent. One is what
-- every first row has between its indent and its text: a plain item's bullet, a quote's
-- bar. So a wrapped row starts under the text, and the bar repeated into that one cell
-- covers nothing.
local WRAP_SHIFT = 1

local function options()
  local opts = config.options.quote
  if opts == false then
    return nil
  end
  if type(opts) ~= 'table' then
    opts = {}
  end
  return {
    bar = type(opts.bar) == 'string' and opts.bar ~= '' and opts.bar or DEFAULT_BAR,
    -- `dim = true` is the older look, the text in Comment's color instead of on a box;
    -- `text_hl = false` leaves the text alone and draws the bar by itself.
    dim = opts.dim == true,
    paint_text = opts.text_hl ~= false,
    wrap = opts.wrap ~= false,
    hl = opts.hl,
    text_hl = type(opts.text_hl) == 'table' and opts.text_hl or nil,
  }
end

--- Give every window showing bufnr the break indent the wrapped-row bar needs. Skipped
--- when `quote.wrap` is off, since it shifts every wrapped line in the buffer, not just
--- quoted ones.
function M.setup_win(bufnr)
  local opts = options()
  if not (opts and opts.wrap) then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].breakindent = true
    if not vim.wo[win].breakindentopt:find('shift:') then
      vim.wo[win].breakindentopt = 'shift:' .. WRAP_SHIFT
    end
  end
end

local function comment_fg()
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = 'Comment', link = false })
  return ok and hl and hl.fg or nil
end

--- `hl`/`text_hl` reach nvim_set_hl unchanged. Without them the text gets a box one shade
--- off the editor's background, and the bar wears Comment's color on that same box, so the
--- box runs unbroken from the bar into the text. Must be re-run after :colorscheme, which
--- clears every highlight group.
function M.ensure_hl()
  local opts = options()
  local text = opts and opts.text_hl
    or (opts and opts.dim and { link = 'Comment', default = true })
    or (opts and opts.paint_text and { bg = require('chatora.highlight').quote_bg(), default = true })
    or { link = 'Comment', default = true }
  vim.api.nvim_set_hl(0, 'ChatoraQuoteText', text)
  local bar = opts and opts.hl
    or (text.bg and { fg = comment_fg(), bg = text.bg, default = true })
    or { link = 'Comment', default = true }
  vim.api.nvim_set_hl(0, 'ChatoraQuoteBar', bar)
end

--- Draw the bar and the box for `quotes` (from chatora/decorations, UTF-16 columns).
---
--- The bar takes the one cell a plain line has between indent and text: in a list that is
--- the last indent character, the cell after the bullet, and the whole `> ` is concealed;
--- at the top level it is the `>` itself and only the space is concealed. Either way the
--- text starts one cell after the indent, where every wrapped row starts too.
function M.render(bufnr, quotes)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local opts = options()
  if not opts then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, q in ipairs(quotes) do
    local ltext = lines[q.line + 1]
    if ltext then
      local ok1, marker = pcall(vim.str_byteindex, ltext, 'utf-16', q.startChar, false)
      local ok2, body = pcall(vim.str_byteindex, ltext, 'utf-16', q.endChar, false)
      if ok1 and ok2 then
        local levels = indent.scan(ltext)
        local last = levels[#levels]
        local bar_at = last and last.at or marker
        local hide_from = last and marker or marker + 1
        if hide_from < body then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, q.line, hide_from, {
            end_col = body,
            conceal = '',
          })
        end
        -- Overlay rather than conceal: the bar is structure, not markup being edited, so
        -- it should stay put when the cursor lands on the line. repeat_linebreak carries
        -- it down the continuation rows of a wrapped quote, into the break indent.
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, q.line, bar_at, {
          virt_text = { { opts.bar, 'ChatoraQuoteBar' } },
          virt_text_pos = 'overlay',
          virt_text_repeat_linebreak = opts.wrap,
          hl_mode = 'combine',
        })
        -- To the row's end rather than the text's, on every wrapped row: the web client's
        -- box spans the line. Ending at the next line's start is what makes hl_eol reach it.
        if opts.paint_text and #ltext > body then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, q.line, bar_at, {
            end_row = q.line + 1,
            end_col = 0,
            hl_group = 'ChatoraQuoteText',
            hl_eol = true,
            hl_mode = 'combine',
            priority = BODY_PRIORITY,
          })
        end
      end
    end
  end
end

return M
