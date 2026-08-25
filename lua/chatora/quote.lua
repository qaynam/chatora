-- GitHub-style blockquotes: the `>` marker is overlaid with a vertical bar and the
-- quoted text is dimmed. The bar's thickness is a property of the glyph (▏ ▎ ▍ ▌ ┃),
-- so `quote.bar` is the one knob for it; color comes from the two highlight groups.
local M = {}

local config = require('chatora.config')

M.ns = vim.api.nvim_create_namespace('chatora_quote')

-- Under the semantic token priority (125) so a link or inline code inside a quote keeps
-- its own color; hl_mode='combine' still lets the dimming show through elsewhere.
local BODY_PRIORITY = 100

local DEFAULT_BAR = '▌'

-- Cells 'breakindentopt' shifts a wrapped row by. The bar is drawn *over* the row's first
-- cell, so without a shift it would eat the first character of every continuation row.
local WRAP_SHIFT = 2

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
    dim = opts.dim ~= false,
    wrap = opts.wrap ~= false,
    hl = opts.hl,
    text_hl = opts.text_hl,
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

--- `hl`/`text_hl` reach nvim_set_hl unchanged; without them the groups link to Comment.
--- Must be re-run after :colorscheme, which clears every highlight group.
function M.ensure_hl()
  local opts = options()
  vim.api.nvim_set_hl(0, 'ChatoraQuoteBar', opts and opts.hl or { link = 'Comment', default = true })
  vim.api.nvim_set_hl(
    0,
    'ChatoraQuoteText',
    opts and opts.text_hl or { link = 'Comment', default = true }
  )
end

--- Draw the bar and dimming for `quotes` (from chatora/decorations, UTF-16 columns).
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
        -- Overlay rather than conceal: the bar is structure, not markup being edited, so
        -- it should stay put when the cursor lands on the line. repeat_linebreak carries
        -- it down the continuation rows of a wrapped quote, into the break indent.
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, q.line, marker, {
          virt_text = { { opts.bar, 'ChatoraQuoteBar' } },
          virt_text_pos = 'overlay',
          virt_text_repeat_linebreak = opts.wrap,
          hl_mode = 'combine',
        })
        if opts.dim and #ltext > body then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, q.line, body, {
            end_col = #ltext,
            hl_group = 'ChatoraQuoteText',
            hl_mode = 'combine',
            priority = BODY_PRIORITY,
          })
        end
      end
    end
  end
end

return M
