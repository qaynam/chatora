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

--- The first of `names` whose foreground is not already in `taken`, or a synthesized one.
---
--- Emphasis is graded by color, so the levels have to differ from each other and from the
--- link color — an emphasis wearing a link's blue reads as a link. Borrowing alone cannot
--- promise that: Neovim's own default colorscheme gives Constant and Keyword the same hue,
--- which would collapse two levels into one look. So a candidate that is already spoken
--- for is skipped, and when a theme has nothing distinct left the fallback is used, chosen
--- to sit legibly on a light and a dark background alike.
local function distinct_fg(names, taken, fallback)
  for _, name in ipairs(names) do
    local fg = fg_of(name)
    if fg and not taken[fg] then
      taken[fg] = true
      return fg
    end
  end
  return fallback
end

--- A background one step away from the editor's own — lighter on a dark theme, darker on a
--- light one. Cosense draws inline code as a grey box rather than colored text, and mixing
--- toward the far end of the theme is the only way to get "a box" out of an arbitrary
--- colorscheme; borrowing CursorLine instead would make the badge vanish on the cursor line.
local SHADE_RATIO = 0.14

local badge_bg

badge_bg = function()
  local base = bg_of('Normal')
  if not base then
    return bg_of('CursorLine')
  end
  local target = vim.o.background == 'light' and 0 or 0xffffff
  local mixed = 0
  for shift = 0, 16, 8 do
    local from = math.floor(base / 2 ^ shift) % 256
    local to = math.floor(target / 2 ^ shift) % 256
    mixed = mixed + math.floor(from + (to - from) * SHADE_RATIO + 0.5) * 2 ^ shift
  end
  return math.floor(mixed)
end

-- Used only when a colorscheme has no hue left that some other token has not taken.
local EMPHASIS_FALLBACK = { level2 = 0xd78700, level3 = 0xaf5fd7 }

--- The badge background, for the non-LSP groups that have to match the `code` token: the
--- marker line of a code block wears both, and two different greys read as a broken span.
function M.badge_bg()
  return badge_bg()
end

local function specs()
  local link = fg_of('Function')
  -- A hashtag is a link to a page in Cosense, so sharing the link's color is correct and
  -- is not counted as taken; the emphasis levels are what must stay clear of it.
  local taken = {}
  for _, color in ipairs({ link, fg_of('Normal') }) do
    if color then
      taken[color] = true
    end
  end
  return {
    title = { fg = fg_of('Title'), bold = true },
    -- Cosense's own convention, and the only thing that tells the two apart at a glance:
    -- a link inside the project is plain colored text, one that leaves it is underlined.
    -- Same color for both, so the underline is carrying the distinction by itself.
    link = { fg = link },
    projectLink = { fg = link },
    externalLink = { fg = link, underline = true },
    hashtag = { fg = fg_of('Special') },
    -- Cosense draws code as a badge, not as colored text: a grey box, foreground left
    -- alone. That also frees the string color, which the emphasis levels below need.
    code = { bg = badge_bg() },
    codeBlock = { bg = badge_bg() },
    formula = { fg = fg_of('Special'), italic = true },
    icon = { fg = fg_of('Identifier') },
    quote = { fg = fg_of('Comment'), italic = true },
    -- Emphasis levels ([*]=bold, [**]=bold2, [***+]=bold3). Cosense scales these by font
    -- size, which a terminal cannot do, so they are graded by color on top of bold — which
    -- also keeps them visible when the CJK fallback font has no bold variant.
    --
    -- The hues have to steer clear of the ones already spoken for: blue is a link and a
    -- box is code, so an emphasis wearing either would read as the wrong thing entirely.
    bold = { bold = true },
    bold2 = {
      bold = true,
      fg = distinct_fg(
        { 'Constant', 'Number', 'WarningMsg', 'Type' },
        taken,
        EMPHASIS_FALLBACK.level2
      ),
    },
    bold3 = {
      bold = true,
      fg = distinct_fg(
        { 'Keyword', 'PreProc', 'Statement', 'Identifier', 'Special' },
        taken,
        EMPHASIS_FALLBACK.level3
      ),
    },
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

-- apply() re-runs on every :colorscheme, so a rejected spec is reported the first time and
-- then stays quiet rather than warning on every theme switch.
local reported = {}

--- Define `group`, reporting a spec Neovim rejects instead of leaving the group undefined.
--- `hl` reaches nvim_set_hl verbatim, so an unknown key — `textColor` for `fg`, say — is a
--- config mistake worth naming: the whole notation would otherwise just not be colored.
local function set_hl(group, hl)
  local ok, err = pcall(vim.api.nvim_set_hl, 0, group, hl)
  if ok or reported[group] then
    return
  end
  reported[group] = true
  vim.notify(('[chatora] %s のハイライトを適用できません: %s'):format(group, err), vim.log.levels.WARN)
end

local function apply()
  for token, spec in pairs(specs()) do
    spec.default = true
    vim.api.nvim_set_hl(0, '@lsp.type.' .. token .. '.cosense', spec)
  end
  for _, notation in pairs(config.options.notations) do
    local hl = vim.deepcopy(notation.hl or {})
    hl.default = true
    set_hl('@lsp.type.' .. notation.name .. '.cosense', hl)
    if notation.rule then
      set_hl(config.notation_rule_hl(notation.name), rule_spec(notation))
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
