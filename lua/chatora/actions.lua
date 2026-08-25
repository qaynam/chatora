-- Page-scoped actions reachable from the <leader>c namespace, mirroring what Cosense's
-- own page menu offers. Each one works on the cosense:// buffer in the current window.
local M = {}

local config = require('chatora.config')
local uri = require('chatora.uri')

--- Project, title and bufnr of the current buffer, or nil (with a message) when it is
--- not a chatora page.
local function current_page()
  local bufnr = vim.api.nvim_get_current_buf()
  local project, title = uri.parse(vim.api.nvim_buf_get_name(bufnr))
  if not project then
    vim.notify('[chatora] Cosense のページではありません', vim.log.levels.WARN)
    return nil
  end
  return project, title, bufnr
end

local function copy(text, label)
  vim.fn.setreg('+', text)
  vim.fn.setreg('"', text)
  vim.notify('[chatora] ' .. label .. ': ' .. text)
end

function M.copy_url()
  local project, title = current_page()
  if not project then
    return
  end
  copy(uri.web_url(config.options.origin, project, title), 'URL をコピー')
end

function M.copy_link()
  local _, title = current_page()
  if not title then
    return
  end
  copy('[' .. title .. ']', 'リンクをコピー')
end

function M.open_in_browser()
  local project, title = current_page()
  if not project then
    return
  end
  vim.ui.open(uri.web_url(config.options.origin, project, title))
end

--- Refetch the current page — the working copy's `git pull`, and the only way to notice
--- someone else has edited it, since chatora never re-reads an open page on its own.
--- Asks before discarding unsaved edits: the buffer is the only place they exist.
function M.pull()
  local project, _, bufnr = current_page()
  if not project then
    return
  end
  local page = require('chatora.page')
  local function run()
    page.pull(bufnr, function(changed)
      vim.notify('[chatora] ' .. (changed and '最新を取得しました' or 'すでに最新です'))
    end)
  end

  if not vim.bo[bufnr].modified then
    run()
    return
  end
  vim.ui.select({ '破棄して取得', 'やめる' }, {
    prompt = '未保存の変更があります。取得すると失われます',
  }, function(choice)
    if choice == '破棄して取得' then
      run()
    end
  end)
end

function M.paste_image()
  require('chatora.paste').image()
end

local function timestamp(seconds)
  if not seconds or seconds == 0 then
    return '—'
  end
  return os.date('%Y-%m-%d %H:%M', seconds)
end

-- Threshold, suffix and divisor per unit. Past the last one a relative age stops being
-- useful and relative_time falls back to the date.
local UNITS = {
  { 60, '秒前', 1 },
  { 3600, '分前', 60 },
  { 86400, '時間前', 3600 },
  { 86400 * 30, '日前', 86400 },
}

--- Age of a Unix timestamp, worded the way Cosense's mobile page list words it. nil for a
--- page with no such timestamp, so a caller can tell "never" apart from "just now".
function M.relative_time(seconds)
  if not seconds or seconds == 0 then
    return nil
  end
  local diff = os.time() - seconds
  if diff < 0 then
    return timestamp(seconds)
  end
  for _, unit in ipairs(UNITS) do
    if diff < unit[1] then
      return math.max(1, math.floor(diff / unit[3])) .. unit[2]
    end
  end
  return os.date('%Y-%m-%d', seconds)
end

--- Float showing everything Cosense records about the current page.
function M.info()
  local project, title, bufnr = current_page()
  if not project then
    return
  end
  local meta = require('chatora.page').meta(bufnr)
  if not meta then
    vim.notify('[chatora] このページの情報はまだ読み込まれていません', vim.log.levels.WARN)
    return
  end

  local rows = {
    { 'プロジェクト', project },
    { 'タイトル', title },
    { '更新', timestamp(meta.updated) .. ' (' .. (M.relative_time(meta.updated) or '—') .. ')' },
    { '作成', timestamp(meta.created) },
    { '最終閲覧', timestamp(meta.accessed) },
    { '閲覧数', tostring(meta.views) },
    { '被リンク', tostring(meta.linked) },
    { 'ページ履歴', tostring(meta.snapshotCount) },
    { 'ページランク', string.format('%.2f', meta.pageRank) },
    { '行数 / 文字数', meta.linesCount .. ' / ' .. meta.charsCount },
    { 'ピン留め', meta.pin > 0 and 'あり' or 'なし' },
    { 'URL', uri.web_url(config.options.origin, project, title) },
  }

  local label_width = 0
  for _, row in ipairs(rows) do
    label_width = math.max(label_width, vim.fn.strdisplaywidth(row[1]))
  end
  local lines, width = {}, 0
  for _, row in ipairs(rows) do
    local pad = string.rep(' ', label_width - vim.fn.strdisplaywidth(row[1]))
    local line = '  ' .. row[1] .. pad .. '  ' .. row[2]
    lines[#lines + 1] = line
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = math.min(width + 4, vim.o.columns - 4),
    height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' ページ情報 ',
    title_pos = 'center',
  })
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true, silent = true })
  end
end

return M
