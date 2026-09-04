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
  require('chatora.keymaps').setup_global()
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

--- Open the sidebar, or — given a Cosense page URL (or a cosense:// URI) — the page
--- it names, switching the session to that page's project. Anything else is an error
--- rather than a silent fall-back to the sidebar, so a mistyped URL is visible.
function M.open(target)
  if target and target ~= '' then
    local project, title = require('chatora.uri').parse_any(target)
    if not project then
      vim.notify('[chatora] Cosense のページ URL ではありません: ' .. target, vim.log.levels.ERROR)
      return
    end
    auth.ensure_auth(function()
      -- The URL names a project, which names an account: following a link into a project
      -- that lives on another one of the reader's accounts should not open it read-only.
      M.use_project(project, { quiet = true }, function()
        if not title then
          sidebar.open(project)
          return
        end
        sidebar.open(project)
        require('chatora.page').open(project, title, require('chatora.winutil').ensure_editor_win())
      end)
    end)
    return
  end

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
      local target = require('chatora.winutil').ensure_editor_win()
      if title and title ~= '' then
        require('chatora.page').open(project, title, target)
      else
        require('chatora.page').open_untitled(project, target)
      end
    end)
  end)
end

function M.help()
  require('chatora.help').open()
end

-- Buffers chatora owns outright, which reloading wipes: a page buffer left behind would
-- still be bound to the stopped LSP client.
local OWNED_BUFFER_PATTERNS = { '^cosense://', '^chatora://' }

local function is_owned_buffer(name)
  for _, pattern in ipairs(OWNED_BUFFER_PATTERNS) do
    if name:match(pattern) then
      return true
    end
  end
  return false
end

--- Reload the plugin in place, for developing it without restarting Neovim.
---
--- Server-side changes need `bun run build` first: this respawns the server process but
--- does not rebuild it. Every chatora augroup is created with `clear = true` at module
--- load, so re-requiring re-registers the autocmds instead of stacking them.
function M.reload()
  local opts = config.user_opts
  for _, client in ipairs(vim.lsp.get_clients({ name = 'chatora' })) do
    pcall(function()
      client:stop(true)
    end)
  end
  pcall(sidebar.close)
  pcall(related.close)
  pcall(require('chatora.picker').close)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if is_owned_buffer(vim.api.nvim_buf_get_name(b)) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end

  for name in pairs(package.loaded) do
    if name == 'chatora' or name:match('^chatora%.') or name == 'telescope._extensions.chatora' then
      package.loaded[name] = nil
    end
  end
  -- Scheduled so this function finishes against the modules it was loaded from.
  vim.schedule(function()
    require('chatora').setup(opts)
    vim.notify('[chatora] 再読み込みしました')
  end)
end

--- Open the server's diagnostic log, or explain how to turn it on.
function M.log()
  lsp.request_ok('chatora/logPath', {}, function(result)
    if not result.path then
      vim.notify(
        '[chatora] ログは無効です。setup({ log = true }) か CHATORA_LOG=1 で有効にしてください',
        vim.log.levels.WARN
      )
      return
    end
    vim.cmd('tabedit ' .. vim.fn.fnameescape(result.path))
  end)
end

--- Switch the session to `name`, moving to whichever stored account can see it, and call
--- `cb(name)`. Announces the account change; `opts.quiet` drops the note about a project no
--- account holds, which is ordinary when following a link into a public project.
function M.use_project(name, opts, cb)
  lsp.request_ok('chatora/useProject', { project = name }, function(result)
    if result.switched then
      require('chatora.keymaps').invalidate_account_cache()
      vim.notify(
        '[chatora] アカウントを切り替えました: ' .. require('chatora.account').label(result.switched),
        vim.log.levels.INFO
      )
    elseif result.foreign and not (opts and opts.quiet) then
      vim.notify(
        ('[chatora] %s はどのアカウントにもありません。公開プロジェクトなら読み取り専用で開きます'):format(name),
        vim.log.levels.WARN
      )
    end
    M.session.project = result.project
    if cb then
      cb(result.project)
    end
  end)
end

--- Pick a different project and reopen the sidebar on it. Overrides both the
--- session's remembered choice and a setup({ project = ... }) fixation until
--- the next switch (resolve_project reads the session first). Given a name, switches
--- straight to it — including the account it is on — instead of prompting.
function M.switch_project(name)
  auth.ensure_auth(function()
    if name and name ~= '' then
      M.use_project(name, nil, sidebar.open)
      return
    end
    -- Every account's projects, not just the active one's: switching to a project on
    -- another account is the case that is hard to do any other way.
    lsp.request_ok('chatora/allProjects', {}, function(result)
      local projects = result.projects or {}
      if #projects == 0 then
        vim.notify('[chatora] 開けるプロジェクトがありません', vim.log.levels.ERROR)
        return
      end
      -- The account goes first, in a column of its own, on every row: with two accounts'
      -- projects in one list, whose project this is must never need working out. The
      -- project in front of the reader right now is marked.
      local account = require('chatora.account')
      local width = 0
      for _, p in ipairs(projects) do
        width = math.max(width, vim.fn.strdisplaywidth(account.short(p.account) or ''))
      end
      vim.ui.select(projects, {
        prompt = 'chatora プロジェクトを切り替え',
        format_item = function(p)
          local who = account.short(p.account) or ''
          local pad = string.rep(' ', width - vim.fn.strdisplaywidth(who))
          return ('%s %s%s  %s'):format(p.name == M.session.project and '●' or ' ', who, pad, p.name)
        end,
      }, function(choice)
        if not choice then
          return
        end
        M.use_project(choice.name, nil, sidebar.open)
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

--- `:Chatora images` says what each picture of the page is doing; `redraw` draws them again.
function M.images(args)
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_get_name(bufnr):match('^cosense://') then
    vim.notify('[chatora] ページのバッファで実行してください', vim.log.levels.WARN)
    return
  end
  local images = require('chatora.images')
  if args == 'redraw' then
    images.redraw(bufnr)
    vim.notify('[chatora] 画像を描き直しました', vim.log.levels.INFO)
    return
  end
  vim.notify(table.concat(images.status(bufnr), '\n'), vim.log.levels.INFO)
end

--- Dispatcher for the :Chatora user command.
function M.dispatch(subcmd, args)
  -- `:Chatora <url>` — a pasted page URL is not a subcommand, so it reaches `open`
  -- directly rather than tripping the unknown-subcommand error.
  if subcmd:match('^https?://') or subcmd:match('^cosense://') then
    M.open(subcmd)
  elseif subcmd == '' or subcmd == 'open' then
    M.open(args ~= '' and args or nil)
  elseif subcmd == 'new' then
    M.new(args ~= '' and args or nil)
  elseif subcmd == 'search' then
    M.search(args ~= '' and args or nil)
  elseif subcmd == 'toggle' then
    M.toggle()
  elseif subcmd == 'related' then
    M.related()
  elseif subcmd == 'project' then
    M.switch_project(args ~= '' and args or nil)
  elseif subcmd == 'account' then
    M.switch_account()
  elseif subcmd == 'logout' then
    M.logout()
  elseif subcmd == 'images' then
    M.images(args)
  elseif subcmd == 'help' then
    M.help()
  elseif subcmd == 'log' then
    M.log()
  elseif subcmd == 'reload' then
    M.reload()
  else
    vim.notify('[chatora] unknown subcommand: ' .. subcmd, vim.log.levels.ERROR)
  end
end

return M
