-- Defaults for @lsp.type.<token>.cosense semantic token groups.
-- Attributes (bold/italic/…) are set directly instead of linking to groups
-- like Bold/@markup.strong, so decorations render regardless of how the
-- active colorscheme defines those groups; colors are borrowed from standard
-- groups at setup time and re-derived on :colorscheme changes.
-- Terminal fonts have a single cell size, so "big" notation ([* ]..[***** ])
-- can only be emphasized, not enlarged.
local M = {}

local function fg_of(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl and hl.fg then
    return hl.fg
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
    bold = { bold = true },
    italic = { italic = true },
    strike = { strikethrough = true },
    underline = { underline = true },
    image = { fg = fg_of('Directory'), underline = true },
    table = { fg = fg_of('Structure') },
  }
end

local function apply()
  for token, spec in pairs(specs()) do
    spec.default = true
    vim.api.nvim_set_hl(0, '@lsp.type.' .. token .. '.cosense', spec)
  end
end

function M.setup()
  apply()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('ChatoraHighlight', { clear = true }),
    callback = apply,
  })
end

return M
