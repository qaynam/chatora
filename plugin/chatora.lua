-- Registers the :Chatora user command (with subcommand completion), which
-- dispatches into lua/chatora's M.dispatch.
if vim.g.loaded_chatora then
  return
end
vim.g.loaded_chatora = true

local subcommands = { 'open', 'new', 'search', 'related', 'logout', 'help' }

vim.api.nvim_create_user_command('Chatora', function(opts)
  local raw = opts.args or ''
  local subcmd, rest = raw:match('^%s*(%S*)%s*(.-)%s*$')
  if subcmd == '' then
    subcmd = 'open'
  end
  require('chatora').dispatch(subcmd, rest)
end, {
  nargs = '*',
  desc = 'chatora: Cosense client',
  complete = function(arglead, cmdline)
    local words = {}
    for w in cmdline:gmatch('%S+') do
      words[#words + 1] = w
    end
    -- Only offer completion for the subcommand (the 2nd word).
    local completing_subcmd = (#words <= 1) or (#words == 2 and arglead ~= '')
    if not completing_subcmd then
      return {}
    end
    return vim.tbl_filter(function(c)
      return arglead == '' or c:sub(1, #arglead) == arglead
    end, subcommands)
  end,
})
