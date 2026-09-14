-- "Export for AI" (Cosense's Smart Context): write the page and the pages within one or two
-- links of it to a file an AI can read.
local M = {}

local lsp = require('chatora.lsp')
local uri = require('chatora.uri')

local HOPS = { 1, 2 }
local KB = 1024

local function notify(message, level)
  vim.notify('[chatora] ' .. message, level or vim.log.levels.INFO)
end

local function human_size(bytes)
  if type(bytes) ~= 'number' then
    return '?'
  end
  return bytes < KB and ('%d B'):format(bytes) or ('%.1f KB'):format(bytes / KB)
end

--- Write the export and open it beside the page. A split rather than this window: the page
--- is what the reader was working on, and the export is there to be copied out of.
local function fetch(project, title, hop)
  notify(('%d hop でエクスポートしています…'):format(hop))
  lsp.request('chatora/exportForAi', { project = project, title = title, hop = hop }, function(err, result)
    if err or not result or result.ok == false then
      local reason = (result and result.message) or tostring(err)
      notify('エクスポートできませんでした: ' .. reason, vim.log.levels.ERROR)
      return
    end
    vim.cmd('split ' .. vim.fn.fnameescape(result.path))
    notify(('%s に書き出しました（%s）'):format(result.path, human_size(result.bytes)))
  end)
end

--- How many pages each hop count would carry, the way the web's dialog names them: the page
--- itself, plus what it links to. nil when the server could not say.
local function page_counts(result)
  if type(result) ~= 'table' or result.ok == false then
    return nil
  end
  local one = 1 + #(result.links1hop or {})
  return { one, one + #(result.links2hop or {}) }
end

--- `:Chatora export [1|2]`. Without a hop count it asks, showing how many pages each would
--- take with it.
function M.run(hop)
  local project, title = uri.parse(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
  if not project then
    notify('Cosense のページで実行してください', vim.log.levels.WARN)
    return
  end
  if hop then
    fetch(project, title, hop)
    return
  end
  lsp.request('chatora/relatedPages', { project = project, title = title }, function(_, result)
    local counts = page_counts(result)
    vim.ui.select(HOPS, {
      prompt = 'Export for AI',
      format_item = function(choice)
        if not counts then
          return ('%d hop リンク'):format(choice)
        end
        return ('%d hop リンク（%d ページ）'):format(choice, counts[choice])
      end,
    }, function(choice)
      if choice then
        fetch(project, title, choice)
      end
    end)
  end)
end

--- The hop count written as `1`, `2`, `1hop` or `2hop`, or nil for anything else.
function M.parse_hop(args)
  local hop = tonumber((args or ''):match('^(%d)hop$') or (args or ''):match('^(%d)$'))
  return (hop == 1 or hop == 2) and hop or nil
end

return M
