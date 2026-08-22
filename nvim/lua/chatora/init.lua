local M = {}

local config = require('chatora.config')
local highlight = require('chatora.highlight')
local auth = require('chatora.auth')
local lsp = require('chatora.lsp')
local sidebar = require('chatora.sidebar')
local search = require('chatora.search')
local related = require('chatora.related')

-- Remembered for the lifetime of this Neovim session.
M.session = { project = nil }

function M.setup(opts)
  config.setup(opts)
  highlight.setup()
end

--- Resolve the active project: config.project if set, else the session's
--- remembered choice, else prompt via vim.ui.select.
function M.resolve_project(cb)
  if M.session.project then
    cb(M.session.project)
    return
  end
  if config.options.project then
    M.session.project = config.options.project
    cb(M.session.project)
    return
  end

  lsp.request_ok('chatora/projects', {}, function(result)
    local projects = result.projects or {}
    if #projects == 0 then
      vim.notify('[chatora] no projects available', vim.log.levels.ERROR)
      return
    end
    vim.ui.select(projects, {
      prompt = 'Select chatora project',
      format_item = function(p)
        return p.name or p.displayName or tostring(p)
      end,
    }, function(choice)
      if not choice then
        return
      end
      local name = choice.name or choice.displayName
      M.session.project = name
      cb(name)
    end)
  end)
end

function M.open()
  auth.ensure_auth(function()
    M.resolve_project(function(project)
      sidebar.open(project)
    end)
  end)
end

function M.search(query)
  auth.ensure_auth(function()
    M.resolve_project(function(project)
      search.run(project, query)
    end)
  end)
end

function M.related()
  related.toggle()
end

function M.logout()
  auth.logout()
end

--- Dispatcher for the :Chatora user command.
function M.dispatch(subcmd, args)
  if subcmd == '' or subcmd == 'open' then
    M.open()
  elseif subcmd == 'search' then
    M.search(args ~= '' and args or nil)
  elseif subcmd == 'related' then
    M.related()
  elseif subcmd == 'logout' then
    M.logout()
  else
    vim.notify('[chatora] unknown subcommand: ' .. subcmd, vim.log.levels.ERROR)
  end
end

return M
