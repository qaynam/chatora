-- Public plugin API: setup() plus the :Chatora subcommand entry points
-- (open/new/search/related/logout/help), and resolution of the active
-- Cosense project shared by all of them.
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

--- Create (open) a new page. Prompts for the title when not given.
function M.new(title)
  auth.ensure_auth(function()
    M.resolve_project(function(project)
      local function open_new(t)
        if not t or t == '' then
          return
        end
        local target = require('chatora.winutil').ensure_editor_win()
        require('chatora.page').open(project, t, target)
      end
      if title and title ~= '' then
        open_new(title)
      else
        vim.ui.input({ prompt = 'New page title: ' }, open_new)
      end
    end)
  end)
end

function M.help()
  require('chatora.help').open()
end

--- Pick a different project and reopen the sidebar on it. Overrides both the
--- session's remembered choice and a setup({ project = ... }) fixation until
--- the next switch (resolve_project reads the session first).
function M.switch_project()
  auth.ensure_auth(function()
    lsp.request_ok('chatora/projects', {}, function(result)
      local projects = result.projects or {}
      if #projects == 0 then
        vim.notify('[chatora] no projects available', vim.log.levels.ERROR)
        return
      end
      vim.ui.select(projects, {
        prompt = 'Switch chatora project',
        format_item = function(p)
          return p.name or p.displayName or tostring(p)
        end,
      }, function(choice)
        if not choice then
          return
        end
        local name = choice.name or choice.displayName
        M.session.project = name
        sidebar.open(name)
      end)
    end)
  end)
end

function M.related()
  related.toggle()
end

--- Toggle the sidebar. Runs the full open flow (auth, project choice) only
--- when there is nothing to reopen.
function M.toggle()
  sidebar.toggle()
end

--- Switch (or add) the active account, then reopen the sidebar from scratch:
--- projects differ per account, so the remembered project choice is dropped
--- and resolve_project runs again against the new account.
function M.switch_account()
  require('chatora.account').switch(function()
    require('chatora.keymaps').invalidate_account_cache()
    M.session.project = nil
    M.resolve_project(function(project)
      sidebar.open(project)
    end)
  end)
end

function M.logout()
  auth.logout()
end

--- Dispatcher for the :Chatora user command.
function M.dispatch(subcmd, args)
  if subcmd == '' or subcmd == 'open' then
    M.open()
  elseif subcmd == 'new' then
    M.new(args ~= '' and args or nil)
  elseif subcmd == 'search' then
    M.search(args ~= '' and args or nil)
  elseif subcmd == 'toggle' then
    M.toggle()
  elseif subcmd == 'related' then
    M.related()
  elseif subcmd == 'project' then
    M.switch_project()
  elseif subcmd == 'account' then
    M.switch_account()
  elseif subcmd == 'logout' then
    M.logout()
  elseif subcmd == 'help' then
    M.help()
  else
    vim.notify('[chatora] unknown subcommand: ' .. subcmd, vim.log.levels.ERROR)
  end
end

return M
