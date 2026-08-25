-- Cosense full-text search as a telescope picker, for people who would rather
-- stay in telescope than learn chatora's own picker (`:Chatora search`). Both
-- talk to the same `chatora/search` and `chatora/previewPage` requests.
--
--   require('telescope').load_extension('chatora')
--   :Telescope chatora search
--
-- Only loaded on demand by telescope, so chatora itself never requires it.
local ok_telescope, telescope = pcall(require, 'telescope')
if not ok_telescope then
  error('telescope.nvim is required for the chatora telescope extension')
end

local channel = require('plenary.async.control').channel
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local finders = require('telescope.finders')
local pickers = require('telescope.pickers')
local previewers = require('telescope.previewers')
local sorters = require('telescope.sorters')

local chatora_config = require('chatora.config')
local lsp = require('chatora.lsp')
local search = require('chatora.search')
local winutil = require('chatora.winutil')

local RECENT_LIMIT = 30

--- Await a chatora/* request from inside telescope's async finder coroutine.
--- Resolves to nil on any failure, so a dead request ends the finder rather
--- than blocking it forever.
local function await(method, params)
  local tx, rx = channel.oneshot()
  lsp.request(method, params, function(err, result)
    tx((not err and result and result.ok ~= false) and result or nil)
  end)
  return rx()
end

local function resolve_project(opts)
  local project = opts.project or chatora_config.options.project
  if not project or project == '' then
    error('chatora: no project configured; pass { project = "..." } or set it in setup()')
  end
  return project
end

--- A search hit as a telescope entry. `ordinal` is the title alone so the
--- highlighter marks the title rather than the snippet, and `words` rides along
--- for the previewer to jump to.
---
--- `query` is read at call time, not captured: a dynamic finder builds its
--- entry_maker once, but the query changes on every keystroke.
local function make_entry(query)
  return function(page)
    local snippet = search.snippet(page)
    return {
      value = page,
      title = page.title,
      words = search.match_words(page, query()),
      ordinal = page.title,
      display = snippet ~= '' and (page.title .. '  — ' .. snippet) or page.title,
    }
  end
end

local function page_previewer(project)
  return previewers.new_buffer_previewer({
    title = 'Cosense Preview',
    dyn_title = function(_, entry)
      return entry.title
    end,
    get_buffer_by_name = function(_, entry)
      return entry.title
    end,
    define_preview = function(self, entry)
      local bufnr = self.state.bufnr
      lsp.request(
        'chatora/previewPage',
        { project = project, title = entry.title },
        function(err, result)
          if err or not result or result.ok == false or not vim.api.nvim_buf_is_valid(bufnr) then
            return
          end
          local lines = vim.split(result.text or '', '\n', { plain = true })
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

          local lnum, from, to = search.find_match(lines, entry.words)
          if not lnum then
            return
          end
          vim.api.nvim_buf_set_extmark(bufnr, vim.api.nvim_create_namespace('chatora_telescope'), lnum - 1, from, {
            end_col = to,
            hl_group = 'TelescopePreviewMatch',
          })
          -- The preview window may already show a different entry by the time
          -- this lands; only recentre when it is still ours.
          local winid = self.state.winid
          if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            pcall(vim.api.nvim_win_set_cursor, winid, { lnum, from })
            pcall(vim.api.nvim_win_call, winid, function()
              vim.cmd('normal! zz')
            end)
          end
        end
      )
    end,
  })
end

local function search_picker(opts)
  opts = opts or {}
  local project = resolve_project(opts)
  local query = ''

  pickers
    .new(opts, {
      prompt_title = 'Cosense: ' .. project,
      finder = finders.new_dynamic({
        entry_maker = make_entry(function()
          return query
        end),
        fn = function(prompt)
          query = prompt or ''
          local method, params
          if query == '' then
            method, params = 'chatora/listPages', { project = project, limit = RECENT_LIMIT }
          else
            method, params = 'chatora/search', { project = project, query = query }
          end
          local result = await(method, params)
          return (result and result.pages) or {}
        end,
      }),
      -- The server already ranks by pageRank; re-sorting client-side would
      -- throw that away, so the sorter only highlights the matched characters.
      sorter = sorters.highlighter_only(opts),
      previewer = page_previewer(project),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry and entry.title then
            require('chatora.page').open(project, entry.title, winutil.ensure_editor_win())
          end
        end)
        return true
      end,
    })
    :find()
end

return telescope.register_extension({
  exports = {
    chatora = search_picker,
    search = search_picker,
  },
})
