-- Keeps link completion alive through multi-word queries. Completion clients
-- dismiss their menu on space and blink.cmp additionally *blocks* ' ' as an
-- LSP trigger character by default (show_on_blocked_trigger_characters), so
-- the server-side trigger never reaches it. When a space is typed inside an
-- unclosed `[`, re-open the menu through whichever client is installed.
local M = {}

--- Mirrors the server's detectLink: true only when the cursor sits inside a
--- *closed* bracket pair `[...|...]` (and not inside `[[`).
local function in_link_context(line, col)
  local open = nil
  for i = col, 1, -1 do
    local ch = line:sub(i, i)
    if ch == ']' then
      return false
    end
    if ch == '[' then
      if line:sub(i - 1, i - 1) == '[' then
        return false
      end
      open = i
      break
    end
  end
  if not open then
    return false
  end
  for j = col + 1, #line do
    local ch = line:sub(j, j)
    if ch == '[' then
      return false
    end
    if ch == ']' then
      return true
    end
  end
  return false
end

local function show_menu()
  local ok_blink, blink = pcall(require, 'blink.cmp')
  if ok_blink and type(blink.show) == 'function' then
    blink.show()
    return
  end
  local ok_cmp, cmp = pcall(require, 'cmp')
  if ok_cmp and type(cmp.complete) == 'function' then
    cmp.complete()
    return
  end
  if vim.lsp.completion and type(vim.lsp.completion.get) == 'function' then
    pcall(vim.lsp.completion.get)
  end
end

function M.attach(bufnr)
  if vim.b[bufnr].chatora_completion_attached then
    return
  end
  vim.b[bufnr].chatora_completion_attached = true
  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = bufnr,
    callback = function()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      if col == 0 then
        return
      end
      local line = vim.api.nvim_get_current_line()
      if line:sub(col, col) == ' ' and in_link_context(line, col) then
        show_menu()
      end
    end,
  })
end

return M
