-- Cosense-style bullet pads: on every indented, non-blank line, overlay the
-- leading whitespace with indent guides and a bullet at the deepest level
-- (1 whitespace char = 1 indent level, per Cosense notation). Doubles as the
-- indent guide for page buffers — general indent plugins (snacks.indent etc.)
-- skip buftype=acwrite buffers.
local M = {}

local config = require('chatora.config')

M.ns = vim.api.nvim_create_namespace('chatora_pads')

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraPadGuide', { link = 'NonText', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraPadBullet', { link = 'Comment', default = true })
end

local function pad_opts()
  local opts = config.options.pads
  -- gap is cells of slack after the bullet. It defaults to 1 because the
  -- bullet is drawn as an *overlay*: '●' is East Asian Ambiguous, so a
  -- terminal that draws it two cells wide paints over whatever follows, and
  -- with no slack that is the line's first real character. gap = 0 hugs the
  -- text, and is safe with 'ambiwidth' set to match the terminal.
  local bullet, guide, spacing, gap = '●', '┃', true, 1
  if type(opts) == 'table' then
    bullet = opts.bullet or bullet
    guide = opts.guide or guide
    if opts.spacing == false then
      spacing = false
    end
    if type(opts.gap) == 'number' then
      gap = math.max(0, math.floor(opts.gap))
    end
  end
  return bullet, guide, spacing, gap
end

--- Display cells the inline spacing adds before the text of a line with
--- `indent` leading whitespace chars. Anything rendered at a text column
--- (inline images) must shift right by this much to stay aligned.
function M.extra_cells(indent)
  if config.options.pads == false or indent <= 0 then
    return 0
  end
  local _, _, spacing, gap = pad_opts()
  return (spacing and indent - 1 or 0) + gap
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
        for i = 0, n - 1 do
          local last = i == n - 1
          vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, i, {
            virt_text = { { last and bullet or guide, last and 'ChatoraPadBullet' or 'ChatoraPadGuide' } },
            virt_text_pos = 'overlay',
            hl_mode = 'combine',
          })
          -- Widen each *guide* level to 2 display cells ('┃ ') so nesting
          -- reads as a list; the bullet level only gets `gap` extra spaces,
          -- keeping the bullet next to its text.
          local pad = last and gap or (spacing and 1 or 0)
          if pad > 0 then
            vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, i + 1, {
              virt_text = { { string.rep(' ', pad), 'ChatoraPadGuide' } },
              virt_text_pos = 'inline',
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
