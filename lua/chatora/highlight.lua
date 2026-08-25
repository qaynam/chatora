-- Defaults for @lsp.type.<token>.cosense semantic token groups, plus the non-LSP
-- groups that must be redefined on the same :colorscheme event.
-- Attributes (bold/italic/…) are set directly instead of linking to groups
-- like Bold/@markup.strong, so decorations render regardless of how the
-- active colorscheme defines those groups; colors are borrowed from standard
-- groups at setup time and re-derived on :colorscheme changes.
-- Terminal fonts have a single cell size, so "big" notation ([* ]..[***** ])
-- can only be emphasized, not enlarged.
local M = {}

local config = require('chatora.config')

local function fg_of(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl and hl.fg then
    return hl.fg
  end
  return nil
end

local function bg_of(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl and hl.bg then
    return hl.bg
  end
  return nil
end

local function specs()
  return {
    title = { fg = fg_of('Title'), bold = true },
    link = { fg = fg_of('Function'), underline = true },
    projectLink = { fg = fg_of('Constant'), underline = true },
    externalLink = { fg = fg_of('Special'), underline = true },
    hashtag = { fg = fg_of('Special') },
    code = { fg = fg_of('String') },
    codeBlock = { fg = fg_of('String') },
    formula = { fg = fg_of('Special'), italic = true },
    icon = { fg = fg_of('Identifier') },
    quote = { fg = fg_of('Comment'), italic = true },
    -- Emphasis levels ([*]=bold, [**]=bold2, [***+]=bold3): terminals have a
    -- single bold weight, so the levels are graded with color on top of bold
    -- (think font-weight 500/600/800). Colors also keep the emphasis visible
    -- when the CJK fallback font lacks a bold variant. bold3 uses a soft
    -- background block instead of underline — underline reads as a link.
    bold = { bold = true },
    bold2 = { bold = true, fg = fg_of('Constant') },
    bold3 = { bold = true, fg = fg_of('Title'), bg = bg_of('CursorLine') },
    italic = { italic = true, fg = fg_of('Comment') },
    strike = { strikethrough = true },
    underline = { underline = true },
    image = { fg = fg_of('Directory'), underline = true },
    table = { fg = fg_of('Structure') },
  }
end

--- Highlight for a notation's full-row rule (`rule = true`). An underline on a
--- line_hl_group runs to the window's right edge, which is the only way to draw a rule
--- wider than its own text — and an underline takes its color from `sp`, not `fg`, so a
--- configured `fg` is translated rather than silently ignored.
---
--- Color precedence is `rule = '<color>'`, `rule_hl`, then the theme; the chain ends at
--- Comment because a theme may leave WinSeparator unset.
local function rule_spec(notation)
  local configured = type(notation.rule) == 'string' and { sp = notation.rule } or notation.rule_hl
  local rule = vim.deepcopy(configured or {})
  rule.sp = rule.sp or rule.fg or fg_of('WinSeparator') or fg_of('Comment')
  rule.fg = nil
  rule.underline = true
  -- Only the derived fallback defers to the colorscheme; a configured color wins.
  rule.default = configured == nil
  return rule
end

local function apply()
  for token, spec in pairs(specs()) do
    spec.default = true
    vim.api.nvim_set_hl(0, '@lsp.type.' .. token .. '.cosense', spec)
  end
  for _, notation in pairs(config.options.notations) do
    local hl = vim.deepcopy(notation.hl or {})
    hl.default = true
    pcall(vim.api.nvim_set_hl, 0, '@lsp.type.' .. notation.name .. '.cosense', hl)
    if notation.rule then
      pcall(vim.api.nvim_set_hl, 0, config.notation_rule_hl(notation.name), rule_spec(notation))
    end
  end
  pcall(require('chatora.quote').ensure_hl)
end

function M.setup()
  apply()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('ChatoraHighlight', { clear = true }),
    callback = apply,
  })
end

return M
