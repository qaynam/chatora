-- In-nvim e2e scenario for chatora. Loaded via `luafile` after tests/e2e/init.lua has set
-- up the plugin (see that file for the exact driving command). Exercises the real chain
-- (Neovim Lua plugin -> chatora LSP server (node, stdio) -> HTTP) against the fake Cosense
-- server started by tests/e2e/run.ts, which also performs the HTTP-traffic assertions after
-- this script exits.
--
-- Prints '--- STEP: <name> ---' / progress lines to stdout as it goes; on success prints
-- 'SCENARIO OK' and quits with :qa!; on any failure prints
-- 'SCENARIO FAIL: <step>: <detail>' and quits with :cquit! (nonzero exit).

local current_step = '(init)'

local function step(name)
  current_step = name
  print('--- STEP: ' .. name .. ' ---')
  io.stdout:flush()
end

local function log(msg)
  print('[' .. current_step .. '] ' .. msg)
  io.stdout:flush()
end

local function fail(detail)
  print('SCENARIO FAIL: ' .. current_step .. ': ' .. tostring(detail))
  io.stdout:flush()
  vim.cmd('cquit!')
  error('scenario failed: ' .. current_step) -- unwind, in case cquit! doesn't stop us cold
end

--- Poll cond() every 50ms up to timeout_ms. Returns true once cond() returns true, else false.
local function wait_for(timeout_ms, cond)
  return vim.wait(timeout_ms, cond, 50) == true
end

-- Record every vim.notify call for the whole scenario so we can assert no ERROR-level
-- notification ever fired (while still letting the expected INFO ones through normally).
local notify_log = {}
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  notify_log[#notify_log + 1] = { level = level, msg = msg }
  return orig_notify(msg, level, opts)
end

local ok, err = pcall(function()
  -- ===================================================================================
  -- STEP: auth + open
  -- ===================================================================================
  step('auth+open')

  local lsp_helper = require('chatora.lsp')

  local auth_result, auth_done = nil, false
  lsp_helper.request_ok('chatora/authStatus', {}, function(result)
    auth_result = result
    auth_done = true
  end)

  if not wait_for(10000, function()
    return auth_done
  end) then
    fail('timed out waiting for chatora/authStatus response')
  end
  if not (auth_result and auth_result.authenticated == true) then
    fail('expected authStatus.authenticated == true, got: ' .. vim.inspect(auth_result))
  end
  if not (auth_result.user and auth_result.user.id == 'user1') then
    fail('expected authStatus.user.id == "user1", got: ' .. vim.inspect(auth_result.user))
  end
  log('chatora/authStatus OK: ' .. vim.inspect(auth_result.user))

  local page = require('chatora.page')
  local uri_mod = require('chatora.uri')

  -- Percent-encoded (Japanese) titles must open through the real entry point;
  -- a regression here (e.g. :edit expanding %XX as cmdline specials, E499)
  -- should fail the scenario loudly.
  local open_ok, open_err = pcall(page.open, 'testproj', 'ホーム')
  if not open_ok then
    fail('page.open(testproj, ホーム) failed: ' .. tostring(open_err))
  end

  local expected_uri = uri_mod.format('testproj', 'ホーム')
  local page_buf = nil
  if not wait_for(10000, function()
    local b = vim.fn.bufnr(expected_uri)
    if b == -1 then
      return false
    end
    local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    if
      not vim.deep_equal(
        lines,
        { 'ホーム', 'これは[メモ]へのリンク', '#tag もある', '[|* 特徴]', '> 引用された行' }
      )
    then
      return false
    end
    page_buf = b
    return true
  end) then
    local b = vim.fn.bufnr(expected_uri)
    local lines = (b ~= -1) and vim.api.nvim_buf_get_lines(b, 0, -1, false) or nil
    fail(
      'timed out waiting for page buffer content; uri='
        .. expected_uri
        .. ' bufnr='
        .. tostring(b)
        .. ' lines='
        .. vim.inspect(lines)
    )
  end

  if vim.bo[page_buf].filetype ~= 'cosense' then
    fail('expected filetype=cosense, got ' .. tostring(vim.bo[page_buf].filetype))
  end
  if vim.bo[page_buf].buftype ~= 'acwrite' then
    fail('expected buftype=acwrite, got ' .. tostring(vim.bo[page_buf].buftype))
  end
  if vim.bo[page_buf].modified then
    fail('expected modified=false right after open')
  end
  log('page buffer OK: ' .. expected_uri .. ' (buf ' .. page_buf .. ')')

  -- ===================================================================================
  -- STEP: lsp
  -- ===================================================================================
  step('lsp')

  local chatora_client = nil
  if not wait_for(10000, function()
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = page_buf, name = 'chatora' })) do
      chatora_client = c
      return true
    end
    return false
  end) then
    local names = {}
    for _, c in ipairs(vim.lsp.get_clients({})) do
      names[#names + 1] = c.name .. '(id=' .. c.id .. ')'
    end
    fail(
      'no chatora LSP client attached to page buffer; clients='
        .. vim.inspect(names)
        .. '; lsp log at '
        .. vim.lsp.log.get_filename()
    )
  end
  log('chatora LSP client attached: id=' .. chatora_client.id)

  -- ===================================================================================
  -- STEP: semantic-tokens
  -- ===================================================================================
  step('semantic-tokens')

  -- get_at_pos's col is a 0-based buffer *byte* column (vim/lsp/semantic_tokens.lua's
  -- tokens_to_ranges converts server offsets into buffer byte offsets via
  -- client.offset_encoding before storing them) -- but rather than hand-deriving exact
  -- byte offsets for multibyte Japanese text, just sweep every byte column on the line and
  -- check whether any of them carries the expected token type.
  local function has_token_type(buf, row, expected_type)
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
    for col = 0, #line do
      local pos_ok, tokens = pcall(vim.lsp.semantic_tokens.get_at_pos, buf, row, col)
      if pos_ok and tokens then
        for _, t in ipairs(tokens) do
          if t.type == expected_type then
            return true
          end
        end
      end
    end
    return false
  end

  -- NOTE: force_refresh() resets the highlighter's cached token ranges before re-requesting
  -- them (STHighlighter:reset() then :send_request()) -- calling it on every poll tick would
  -- wipe the cache faster than responses can repopulate it, livelocking get_at_pos into
  -- perpetually seeing nothing. Call it once up front (the client already auto-starts
  -- semantic tokens on attach, so this is mostly a headless-mode safety net) and then just
  -- poll the cache as it fills in.
  vim.lsp.semantic_tokens.force_refresh(page_buf)

  local found_title, found_link, found_hashtag = false, false, false
  wait_for(10000, function()
    found_title = has_token_type(page_buf, 0, 'title')
    found_link = has_token_type(page_buf, 1, 'link')
    found_hashtag = has_token_type(page_buf, 2, 'hashtag')
    return found_title and found_link and found_hashtag
  end)

  if not (found_title and found_link and found_hashtag) then
    log('get_at_pos empty after 10s; falling back to raw textDocument/semanticTokens/full')
    local legend = chatora_client.server_capabilities.semanticTokensProvider.legend.tokenTypes
    local results = vim.lsp.buf_request_sync(page_buf, 'textDocument/semanticTokens/full', {
      textDocument = { uri = vim.uri_from_bufnr(page_buf) },
    }, 5000)
    if not results then
      fail('semanticTokens/full request timed out')
    end

    local data = nil
    for _, res in pairs(results) do
      if res.result and res.result.data then
        data = res.result.data
      end
      if res.err then
        fail('semanticTokens/full returned an error: ' .. vim.inspect(res.err))
      end
    end
    if not data then
      fail('semanticTokens/full returned no data: ' .. vim.inspect(results))
    end

    -- Decode LSP relative 5-tuples: [deltaLine, deltaStartChar, length, tokenType, tokenModifiers]
    local decoded = {}
    local line, char = 0, 0
    for i = 1, #data, 5 do
      local delta_line = data[i]
      local delta_char = data[i + 1]
      local length = data[i + 2]
      local type_idx = data[i + 3]
      if delta_line == 0 then
        char = char + delta_char
      else
        char = delta_char
      end
      line = line + delta_line
      decoded[#decoded + 1] = { line = line, char = char, length = length, type = legend[type_idx + 1] }
    end

    for _, t in ipairs(decoded) do
      if t.line == 0 and t.type == 'title' then
        found_title = true
      end
      if t.line == 1 and t.type == 'link' then
        found_link = true
      end
      if t.line == 2 and t.type == 'hashtag' then
        found_hashtag = true
      end
    end

    if not (found_title and found_link and found_hashtag) then
      fail(
        'missing expected semantic tokens (title on line 0 / link on line 1 / hashtag on line 2); decoded='
          .. vim.inspect(decoded)
      )
    end
  end

  log('semantic tokens OK: title(line0) / link(line1) / hashtag(line2) all found')

  -- ===================================================================================
  -- STEP: custom-notation
  -- ===================================================================================
  step('custom-notation')

  -- A marker run carrying both the configured `|` notation (init.lua) and the official
  -- `*`: the notation must win the token type, and its icon must replace the whole
  -- opening run rather than just the first marker character.
  local NOTATION_ROW = 3
  local NOTATION_OPENING = '[|* '
  local notation_line = vim.api.nvim_buf_get_lines(page_buf, NOTATION_ROW, NOTATION_ROW + 1, false)[1]
  if notation_line ~= NOTATION_OPENING .. '特徴]' then
    fail('fixture drift: line ' .. NOTATION_ROW .. ' is ' .. vim.inspect(notation_line))
  end

  if not wait_for(10000, function()
    return has_token_type(page_buf, NOTATION_ROW, 'pinned')
  end) then
    fail('custom notation token missing on ' .. notation_line)
  end

  local render_ns = require('chatora.render').ns
  local function icon_mark()
    local marks = vim.api.nvim_buf_get_extmarks(
      page_buf,
      render_ns,
      { NOTATION_ROW, 0 },
      { NOTATION_ROW, -1 },
      { details = true }
    )
    for _, mark in ipairs(marks) do
      if mark[4].conceal == '📌' then
        return mark
      end
    end
    return nil
  end

  local opening = nil
  if not wait_for(10000, function()
    opening = icon_mark()
    return opening ~= nil
  end) then
    fail('no 📌 conceal extmark on ' .. notation_line)
  end
  if opening[3] ~= 0 or opening[4].end_col ~= #NOTATION_OPENING then
    fail('📌 conceal covers the wrong span: ' .. vim.inspect(opening))
  end
  log('custom notation OK ([|* ] tokenized as pinned, opening run concealed to 📌)')

  -- ===================================================================================
  -- STEP: quote-bar
  -- ===================================================================================
  step('quote-bar')

  -- The `>` marker is overlaid with the bar glyph and the text after it is dimmed.
  local QUOTE_ROW = 4
  local quote_ns = require('chatora.quote').ns
  local bar, dim = nil, nil
  if not wait_for(10000, function()
    bar, dim = nil, nil
    local marks = vim.api.nvim_buf_get_extmarks(
      page_buf,
      quote_ns,
      { QUOTE_ROW, 0 },
      { QUOTE_ROW, -1 },
      { details = true }
    )
    for _, mark in ipairs(marks) do
      if mark[4].virt_text then
        bar = mark
      elseif mark[4].hl_group == 'ChatoraQuoteText' then
        dim = mark
      end
    end
    return bar ~= nil and dim ~= nil
  end) then
    fail('quote decorations missing on line ' .. QUOTE_ROW .. ': bar=' .. vim.inspect(bar) .. ' dim=' .. vim.inspect(dim))
  end

  if bar[3] ~= 0 or bar[4].virt_text[1][1] ~= '▌' or bar[4].virt_text_pos ~= 'overlay' then
    fail('quote bar is not an overlay at the marker: ' .. vim.inspect(bar))
  end
  -- The dimming must start past the marker, or it would wash out the bar's own color.
  if dim[3] ~= #'> ' then
    fail('quote dimming does not start at the quoted text: ' .. vim.inspect(dim))
  end
  log('quote bar OK (▌ overlay on the marker, ChatoraQuoteText over the text)')

  -- ===================================================================================
  -- STEP: related
  -- ===================================================================================
  step('related')

  require('chatora.related').toggle()

  local related_buf = nil
  if not wait_for(10000, function()
    local b = vim.fn.bufnr('chatora://related')
    if b == -1 then
      return false
    end
    for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      -- Item lines carry a 2-space indent under their bold section header.
      if l == '  メモ' then
        related_buf = b
        return true
      end
    end
    return false
  end) then
    local b = vim.fn.bufnr('chatora://related')
    local lines = (b ~= -1) and vim.api.nvim_buf_get_lines(b, 0, -1, false) or nil
    fail('timed out waiting for related panel to show メモ; lines=' .. vim.inspect(lines))
  end
  -- The winbar carries the subject page's own incoming-link count.
  if require('chatora.related').winbar_count() ~= '  被リンク 6' then
    fail('related winbar count is wrong: ' .. vim.inspect(require('chatora.related').winbar_count()))
  end
  log('related winbar count OK (被リンク 6)')

  log('related panel OK (buf ' .. related_buf .. ' contains メモ)')

  -- ===================================================================================
  -- STEP: save
  -- ===================================================================================
  step('save')

  vim.api.nvim_buf_set_lines(page_buf, -1, -1, false, { 'あたらしい行' })

  local page_win = vim.fn.bufwinid(page_buf)
  if page_win == -1 then
    fail('page buffer has no window; cannot :write it')
  end
  vim.api.nvim_win_call(page_win, function()
    vim.cmd('write')
  end)

  if not wait_for(10000, function()
    return vim.bo[page_buf].modified == false
  end) then
    fail('timed out waiting for modified=false after :write')
  end

  local saved_lines = vim.api.nvim_buf_get_lines(page_buf, 0, -1, false)
  if #saved_lines ~= 6 or saved_lines[6] ~= 'あたらしい行' then
    fail('unexpected buffer content after save: ' .. vim.inspect(saved_lines))
  end
  log('save OK (modified=false, buffer has the new line)')

  -- ===================================================================================
  -- STEP: sidebar
  -- ===================================================================================
  step('sidebar')

  require('chatora.sidebar').open('testproj')

  --- Strip the sidebar's leading border column, leaving the page title. The
  --- save-state icon is virtual text, not buffer text (see sidebar_mark).
  local function sidebar_title(line)
    return line:match('^▍(.*)$') or line:match('^%s(.*)$') or line
  end

  --- The save-state icon rendered for `title`, or nil. It lives in a
  --- right-aligned extmark so it never shifts the titles around.
  local function sidebar_mark(title)
    local b = vim.fn.bufnr('chatora://sidebar')
    if b == -1 then
      return nil
    end
    local ns = vim.api.nvim_get_namespaces()['chatora_sidebar']
    for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if sidebar_title(l) == title then
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, { i - 1, 0 }, { i - 1, -1 }, { details = true })) do
          local vt = m[4].virt_text
          if vt and vt[1] then
            return vim.trim(vt[1][1])
          end
        end
        return nil
      end
    end
    return nil
  end

  local sidebar_buf = nil
  if not wait_for(10000, function()
    local b = vim.fn.bufnr('chatora://sidebar')
    if b == -1 then
      return false
    end
    -- Column 0 is the unread border ('▍' or a space); the title follows.
    local has_home, has_memo = false, false
    for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      local title = sidebar_title(l)
      if title == 'ホーム' then
        has_home = true
      end
      if title == 'メモ' then
        has_memo = true
      end
    end
    if has_home and has_memo then
      sidebar_buf = b
      return true
    end
    return false
  end) then
    local b = vim.fn.bufnr('chatora://sidebar')
    local lines = (b ~= -1) and vim.api.nvim_buf_get_lines(b, 0, -1, false) or nil
    fail('timed out waiting for sidebar to list both pages; lines=' .. vim.inspect(lines))
  end
  -- Closing and reopening must show the cached list, not refetch it: run.ts asserts the
  -- request count below, and here we only check the list survived the round trip.
  require('chatora.sidebar').close()
  require('chatora.sidebar').open('testproj')
  local reopened = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
  local still_listed = false
  for _, l in ipairs(reopened) do
    if l:find('ホーム', 1, true) then
      still_listed = true
    end
  end
  if not still_listed then
    fail('sidebar lost its list on reopen: ' .. vim.inspect(reopened))
  end
  log('sidebar reopen OK (list served from cache)')

  log('sidebar OK (buf ' .. sidebar_buf .. ' lists ホーム and メモ)')

  -- ===================================================================================
  -- STEP: sidebar unsaved (●) mark appears while the page buffer is modified, and clears
  -- ===================================================================================
  step('sidebar-mark')

  -- Type into the page buffer the way a user would (focused window + feedkeys),
  -- so the TextChanged/BufModifiedSet autocmds fire for real.
  local page_win = vim.fn.bufwinid(page_buf)
  if page_win == -1 then
    fail('page buffer has no window for the mark step')
  end
  vim.api.nvim_set_current_win(page_win)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('Goマークテスト<Esc>', true, false, true), 'x', false)
  if not wait_for(10000, function()
    return sidebar_mark('ホーム') == '●'
  end) then
    fail('timed out waiting for the ● unsaved mark on ホーム, got ' .. tostring(sidebar_mark('ホーム')))
  end

  -- Clearing modified via the API fires no autocmd; the plugin's save path
  -- reports the new state through chatora.status, which is what we emulate.
  vim.bo[page_buf].modified = false
  require('chatora.status').sync(page_buf)
  if not wait_for(10000, function()
    return sidebar_mark('ホーム') == '✓'
  end) then
    fail('timed out waiting for the unsaved mark to turn back into ✓, got ' .. tostring(sidebar_mark('ホーム')))
  end
  log('sidebar unsaved mark OK (appears and clears)')

  -- ===================================================================================
  -- STEP: incremental search picker — recent pages on empty query, live search
  -- results while typing, <CR>-equivalent accept opens the page
  -- ===================================================================================
  step('picker')

  local picker = require('chatora.picker')
  picker.open('testproj')
  log('picker opened')

  local function items_contain(title)
    for _, item in ipairs(picker.get_items() or {}) do
      if item.title == title then
        return true
      end
    end
    return false
  end

  if not wait_for(10000, function()
    return items_contain('ホーム')
  end) then
    fail(
      'picker: timed out waiting for recent pages on empty query; items='
        .. vim.inspect(picker.get_items())
    )
  end
  log('picker recent list OK')

  picker.set_query('検索テスト')
  if not wait_for(10000, function()
    return items_contain('メモ')
  end) then
    fail('picker: timed out waiting for search results; items=' .. vim.inspect(picker.get_items()))
  end
  log('picker live query OK')

  -- The preview pane loads the selected page's own text, not the search snippet.
  if not wait_for(10000, function()
    local preview = picker.get_preview() or {}
    return vim.tbl_contains(preview, '検索ヒット行')
  end) then
    fail('picker: preview never loaded メモ; preview=' .. vim.inspect(picker.get_preview()))
  end
  -- The preview is painted from the decorations previewPage ships with the text, so
  -- it reads like a page rather than a plain dump. メモ's first line is its title.
  if not wait_for(10000, function()
    for _, mark in ipairs(picker.get_preview_marks() or {}) do
      if mark[4].hl_group == '@lsp.type.title.cosense' then
        return true
      end
    end
    return false
  end) then
    fail('picker: preview has no semantic highlighting; marks=' .. vim.inspect(picker.get_preview_marks()))
  end
  log('picker preview OK')

  -- Move the selection onto メモ (bounded — the item list is fixed here).
  local items = picker.get_items() or {}
  local target_idx = nil
  for i, item in ipairs(items) do
    if item.title == 'メモ' then
      target_idx = i
      break
    end
  end
  assert(target_idx, 'メモ not in picker items')
  for _ = 1, target_idx - 1 do
    picker.move(1)
  end
  picker.accept()
  log('picker accepted')
  assert(not picker.is_open(), 'picker should close on accept')

  local memo_uri = uri_mod.format('testproj', 'メモ')
  if not wait_for(10000, function()
    local b = vim.fn.bufnr(memo_uri)
    if b == -1 then
      return false
    end
    local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
    return first == 'メモ'
  end) then
    fail('picker: timed out waiting for メモ to open after accept')
  end
  log('picker OK (recent list, live query, accept opens page)')

  -- ===================================================================================
  -- STEP: final-checks
  -- ===================================================================================
  step('final-checks')

  local error_notifications = {}
  for _, n in ipairs(notify_log) do
    if n.level == vim.log.levels.ERROR then
      error_notifications[#error_notifications + 1] = n.msg
    end
  end
  if #error_notifications > 0 then
    fail('unexpected ERROR-level vim.notify() during scenario: ' .. vim.inspect(error_notifications))
  end
  log('no ERROR-level notifications across the whole scenario (' .. #notify_log .. ' total)')
end)

if ok then
  print('SCENARIO OK')
  io.stdout:flush()
  vim.cmd('qa!')
else
  -- fail() already printed 'SCENARIO FAIL: ...' and requested cquit! before erroring (or
  -- this is an unexpected Lua error outside any explicit fail() call) -- either way, make
  -- sure something informative lands and we exit nonzero.
  print('SCENARIO FAIL: ' .. current_step .. ' (uncaught): ' .. tostring(err))
  io.stdout:flush()
  vim.cmd('cquit!')
end
