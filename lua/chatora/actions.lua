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

--- Merge the server's copy into the current page — the working copy's `git pull`. Nothing
--- to confirm: unsaved edits are merged, not overwritten, and a line both sides changed
--- keeps the local text and is marked as a conflict.
function M.pull()
  local project, _, bufnr = current_page()
  if not project then
    return
  end
  require('chatora.sync').run(bufnr, function(changed, conflicts)
    if #conflicts > 0 then
      vim.notify(
        ('[chatora] 競合 %d 件（ローカルの内容は残しています）。]c で移動できます'):format(#conflicts),
        vim.log.levels.WARN
      )
    else
      vim.notify('[chatora] ' .. (changed and 'リモートの変更を取り込みました' or 'すでに最新です'))
    end
  end)
end

--- Jump to the next line the last sync found a conflict on.
function M.next_conflict()
  require('chatora.sync').next_conflict()
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

local info_ns = vim.api.nvim_create_namespace('chatora_page_info')

--- Reserved at the head of every value, so an author's picture has somewhere to land and
--- the column stays straight on a terminal that draws nothing there.
local ICON_GUTTER = '   '

local function ensure_info_hl()
  vim.api.nvim_set_hl(0, 'ChatoraInfoLabel', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraInfoRule', { link = 'WinSeparator', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraInfoName', { link = 'Identifier', default = true })
end

local function author_label(author)
  if not author then
    return '—'
  end
  local name = author.displayName ~= '' and author.displayName or author.name
  return name ~= '' and name or author.id
end

--- The panel's rows, grouped the way Cosense's own page menu groups them: who and when
--- first, then where the page sits, then the numbers nobody opens this for. `false` is a
--- horizontal rule. Times are relative — a page's age is what the eye wants, and the exact
--- stamp is a hover away in the web UI.
local function info_rows(project, title, meta)
  return {
    { 'URL', uri.web_url(config.options.origin, project, title) },
    { '作成', author_label(meta.createdBy), M.relative_time(meta.created) or '—', meta.createdBy },
    { '更新', author_label(meta.updatedBy), M.relative_time(meta.updated) or '—', meta.updatedBy },
    false,
    { 'プロジェクト', project },
    { 'ページ履歴', tostring(meta.snapshotCount) },
    { '被リンク', tostring(meta.linked) },
    false,
    { '閲覧数', tostring(meta.views) },
    { 'ページランク', string.format('%.2f', meta.pageRank) },
    { '行数 / 文字数', meta.linesCount .. ' / ' .. meta.charsCount },
    { 'ピン留め', meta.pin > 0 and 'あり' or 'なし' },
    { '最終閲覧', M.relative_time(meta.accessed) or '—' },
  }
end

--- Float showing what Cosense records about the current page.
---
--- Author icons are drawn over the gutter each of their rows reserves, so a terminal that
--- cannot render pictures simply shows the names — the layout does not depend on them.
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
  ensure_info_hl()

  local rows = info_rows(project, title, meta)
  -- Every value carries the icon gutter, not just the rows that will fill it: the column
  -- has to be straight whether or not this terminal can draw a picture.
  local label_width, named_width = 0, 0
  for _, row in ipairs(rows) do
    if row then
      label_width = math.max(label_width, vim.fn.strdisplaywidth(row[1]))
      -- Only the rows that carry a trailing time set that column's position, so it sits
      -- next to the name rather than out past the width of the URL.
      if row[3] then
        named_width = math.max(named_width, vim.fn.strdisplaywidth(row[2]))
      end
    end
  end

  local lines, marks, width = {}, {}, 0
  for _, row in ipairs(rows) do
    if not row then
      lines[#lines + 1] = ''
      marks[#marks + 1] = { rule = true, line = #lines - 1 }
    else
      local label = row[1] .. string.rep(' ', label_width - vim.fn.strdisplaywidth(row[1]))
      local prefix = '  ' .. label .. ICON_GUTTER
      local line = prefix .. row[2]
      if row[3] then
        line = line .. string.rep(' ', named_width - vim.fn.strdisplaywidth(row[2]) + 3) .. row[3]
      end
      lines[#lines + 1] = line
      marks[#marks + 1] = {
        line = #lines - 1,
        label_end = #('  ' .. label),
        value_at = #prefix,
        author = row[4],
      }
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  width = math.min(width + 4, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
  })

  local images = require('chatora.images')
  local placements = {}
  for _, mark in ipairs(marks) do
    if mark.rule then
      -- The separator is an empty line wearing a full-width underline: a row of box glyphs
      -- would be text the reader could put a cursor in the middle of.
      vim.api.nvim_buf_set_extmark(buf, info_ns, mark.line, 0, {
        line_hl_group = 'ChatoraInfoRule',
      })
    else
      vim.api.nvim_buf_set_extmark(buf, info_ns, mark.line, 0, {
        end_col = mark.label_end,
        hl_group = 'ChatoraInfoLabel',
      })
      if mark.author then
        vim.api.nvim_buf_set_extmark(buf, info_ns, mark.line, mark.value_at, {
          end_col = #lines[mark.line + 1],
          hl_group = 'ChatoraInfoName',
        })
      end
      if mark.author and mark.author.name ~= '' then
        images.place_one(
          buf,
          project,
          images.icon_url(config.options.origin, project, mark.author.name),
          mark.line,
          mark.value_at,
          function(placement)
            placements[#placements + 1] = placement
          end
        )
      end
    end
  end

  local function close()
    for _, placement in ipairs(placements) do
      pcall(placement.close)
    end
    pcall(vim.api.nvim_win_close, win, true)
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true, silent = true })
  end
end

return M
