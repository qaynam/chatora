-- Default links for @lsp.type.<token>.cosense semantic token groups.
-- See docs/ARCHITECTURE.md「ハイライト（lua/chatora/highlight.lua）」.
local M = {}

local links = {
  title = 'Title',
  link = 'Underlined',
  projectLink = 'Constant',
  externalLink = 'Underlined',
  hashtag = 'Special',
  code = 'String',
  codeBlock = 'String',
  formula = 'Special',
  icon = 'Identifier',
  quote = 'Comment',
  bold = '@markup.strong',
  italic = '@markup.italic',
  strike = '@markup.strikethrough',
  underline = 'Underlined',
  image = 'Directory',
  table = 'Structure',
}

function M.setup()
  for token, group in pairs(links) do
    vim.api.nvim_set_hl(0, '@lsp.type.' .. token .. '.cosense', { link = group, default = true })
  end
end

return M
