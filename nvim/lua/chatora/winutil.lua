-- Window helpers shared by sidebar/related/init: chatora UI windows (sidebar,
-- related panel) must never be used as the "editor" target for opening pages.
local M = {}

function M.is_plugin_win(w)
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
  return name:match('^chatora://') ~= nil
end

--- The rightmost non-floating window that isn't a chatora UI window, or nil.
--- opts.exclude: a window id to skip.
function M.find_editor_win(opts)
  local exclude = opts and opts.exclude
  local best, best_col = nil, nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= exclude and vim.api.nvim_win_get_config(w).relative == '' and not M.is_plugin_win(w) then
      local col = vim.fn.win_screenpos(w)[2]
      if not best_col or col > best_col then
        best_col, best = col, w
      end
    end
  end
  return best
end

--- Like find_editor_win, but creates a vsplit when no editor window exists.
function M.ensure_editor_win(opts)
  local w = M.find_editor_win(opts)
  if w then
    return w
  end
  vim.cmd('rightbelow vsplit')
  return vim.api.nvim_get_current_win()
end

return M
