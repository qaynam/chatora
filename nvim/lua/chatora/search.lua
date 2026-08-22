local M = {}

local lsp = require('chatora.lsp')
local page = require('chatora.page')

local function do_search(project, query)
  lsp.request_ok('chatora/search', { project = project, query = query }, function(result)
    local pages = result.pages or {}
    if #pages == 0 then
      vim.notify('[chatora] no results for: ' .. query, vim.log.levels.INFO)
      return
    end

    vim.ui.select(pages, {
      prompt = 'chatora search: ' .. query,
      format_item = function(p)
        local snippet = ''
        if p.lines and #p.lines > 0 then
          snippet = p.lines[2] or p.lines[1] or ''
        end
        local title = p.title or '(untitled)'
        if snippet ~= '' then
          return title .. ' — ' .. snippet
        end
        return title
      end,
    }, function(choice)
      if not choice then
        return
      end
      page.open(project, choice.title)
    end)
  end)
end

--- Run a search for project. Prompts via vim.ui.input when query is nil.
function M.run(project, query)
  if query and query ~= '' then
    do_search(project, query)
    return
  end
  vim.ui.input({ prompt = 'Search chatora: ' }, function(input)
    if not input or input == '' then
      return
    end
    do_search(project, input)
  end)
end

return M
