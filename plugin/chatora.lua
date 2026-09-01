-- Registers the :Chatora user command (with subcommand completion), which
-- dispatches into lua/chatora's M.dispatch.
if vim.g.loaded_chatora then
  return
end
vim.g.loaded_chatora = true

-- A page title is not a file name, but Neovim reads the end of one the same way: a page
-- called `next.js` matches the `*.js` rule, and everything that keys off filetype — another
-- language server attaching, treesitter, format-on-save — then takes the page for
-- JavaScript. `chatora/page` sets the filetype itself when it loads a page, which settles
-- the buffer but not the question: a plugin asking `vim.filetype.match`, or anything that
-- runs `:filetype detect`, still gets an answer from the name alone. A pattern outranks an
-- extension, so this is what makes that answer `cosense` too.
vim.filetype.add({ pattern = { ['cosense://.*'] = 'cosense' } })

local subcommands = { 'open', 'toggle', 'new', 'search', 'related', 'project', 'account', 'logout', 'log', 'reload', 'help' }

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
