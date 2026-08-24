-- Headless smoke test: `nvim --headless --clean -u NORC -c "luafile tests/smoke.lua"`
-- Does NOT require the LSP server to be running.
local ok, err = pcall(function()
  local this_file = debug.getinfo(1, 'S').source:sub(2)
  local tests_dir = vim.fn.fnamemodify(this_file, ':p:h')
  local repo_root = vim.fn.fnamemodify(tests_dir, ':h')

  vim.opt.rtp:prepend(repo_root)

  -- plugin/*.lua is normally auto-sourced at startup; since we add the repo
  -- root to rtp only after startup, source it manually here.
  dofile(repo_root .. '/plugin/chatora.lua')

  local chatora = require('chatora')
  chatora.setup({})

  assert(vim.fn.exists(':Chatora') == 2, 'expected :Chatora user command to exist')

  -- Japanese titles stay raw in the URI (readable buffer names); only
  -- structure-breaking chars are percent-encoded. Must round-trip.
  local uri = require('chatora.uri')
  local japanese_title = '日本語のタイトル'

  local encoded = uri.encode_title(japanese_title)
  assert(encoded == japanese_title, 'expected japanese title to stay raw, got: ' .. encoded)
  assert(uri.decode_title(encoded) == japanese_title, 'title did not round-trip through encode/decode')

  local tricky_title = 'a/b?c#d%e 日本語'
  local tricky_encoded = uri.encode_title(tricky_title)
  assert(tricky_encoded == 'a%2Fb%3Fc%23d%25e 日本語', 'unexpected encoding: ' .. tricky_encoded)
  assert(uri.decode_title(tricky_encoded) == tricky_title, 'tricky title did not round-trip')

  local formatted = uri.format('myproject', tricky_title)
  assert(formatted == ('cosense://myproject/' .. tricky_encoded), 'format() did not match encode_title()')

  local project, title = uri.parse(formatted)
  assert(project == 'myproject', 'parse() project mismatch: ' .. tostring(project))
  assert(title == tricky_title, 'parse() title mismatch: ' .. tostring(title))

  -- Subcommand entry points must exist.
  local entry_points = {
    'open', 'new', 'search', 'related', 'switch_project', 'switch_account', 'logout', 'help',
  }
  for _, fn in ipairs(entry_points) do
    assert(type(chatora[fn]) == 'function', 'expected chatora.' .. fn .. ' to be a function')
  end

  -- The help float must open and render.
  require('chatora.help').open()
  local help_buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[help_buf].filetype == 'chatora_help', 'expected help float to be focused')
  assert(vim.api.nvim_buf_get_lines(help_buf, 0, 1, false)[1]:find('chatora'), 'help content missing')
  vim.api.nvim_win_close(0, true)

  -- Highlight groups from the semantic token legend must be defined.
  local legend = {
    'title', 'link', 'projectLink', 'externalLink', 'hashtag', 'code',
    'codeBlock', 'formula', 'icon', 'quote', 'bold', 'italic', 'strike',
    'underline', 'image', 'table', 'bold2', 'bold3',
  }
  for _, token in ipairs(legend) do
    local name = '@lsp.type.' .. token .. '.cosense'
    local hl = vim.api.nvim_get_hl(0, { name = name })
    assert(next(hl) ~= nil, 'expected highlight group to be defined: ' .. name)
  end

  -- codeblock.find_blocks: pure Cosense code-block detection.
  local codeblock = require('chatora.codeblock')

  do
    local lines = {
      'code:example.ts',
      ' const x = 1',
      ' console.log(x)',
      'next normal line',
    }
    local blocks = codeblock.find_blocks(lines)
    assert(#blocks == 1, 'expected exactly one block, got ' .. #blocks)
    local b = blocks[1]
    assert(b.marker_line == 0, 'marker_line mismatch: ' .. b.marker_line)
    assert(b.start_line == 1, 'start_line mismatch: ' .. b.start_line)
    assert(b.end_line == 3, 'end_line mismatch: ' .. b.end_line)
    assert(b.name == 'example.ts', 'name mismatch: ' .. b.name)
  end

  do
    -- Blank lines inside a block belong to it; block ends at EOF if nothing
    -- dedents; a second block with no extension falls back to name-as-lang.
    local lines = {
      'code:a.lua',
      '  local x = 1',
      '',
      '  local y = 2',
      'code:bash',
      '  echo hi',
    }
    local blocks = codeblock.find_blocks(lines)
    assert(#blocks == 2, 'expected two blocks, got ' .. #blocks)
    assert(blocks[1].start_line == 1 and blocks[1].end_line == 4, 'first block range mismatch')
    assert(blocks[1].name == 'a.lua', 'first block name mismatch: ' .. blocks[1].name)
    assert(blocks[2].marker_line == 4, 'second marker_line mismatch: ' .. blocks[2].marker_line)
    assert(blocks[2].start_line == 5 and blocks[2].end_line == 6, 'second block range mismatch')
    assert(blocks[2].name == 'bash', 'second block name mismatch: ' .. blocks[2].name)
  end

  do
    -- A marker with no indented content following it is still detected,
    -- just with an empty interior.
    local lines = { 'code:empty.txt', 'not indented' }
    local blocks = codeblock.find_blocks(lines)
    assert(#blocks == 1, 'expected one block for an empty marker')
    assert(blocks[1].start_line == blocks[1].end_line, 'expected empty interior')
  end

  -- codeblock.attach + a forced refresh: if the bundled lua parser is
  -- available headless, at least one extmark must land in the namespace.
  do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'some text',
      'code:test.lua',
      ' local x = 1',
      ' print(x)',
      'trailing text',
    })
    vim.bo[buf].filetype = 'cosense'

    codeblock.attach(buf)
    assert(vim.b[buf].chatora_codeblock_attached == true, 'expected attach guard to be set')
    codeblock.refresh(buf) -- bypass the debounce timer for a synchronous assertion

    local has_lua_parser = pcall(vim.treesitter.language.add, 'lua')
    if has_lua_parser then
      local marks = vim.api.nvim_buf_get_extmarks(buf, codeblock.ns, 0, -1, {})
      assert(#marks > 0, 'expected at least one codeblock extmark when the lua parser is available')
    end

    -- Re-attaching must not double-attach (guard flag) or error.
    codeblock.attach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- codeblock.refresh must be a no-op (never error) on a buffer with no
  -- code blocks at all -- this is the shape of buffers the e2e test uses.
  do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'just a normal cosense page', 'no code blocks here' })
    codeblock.attach(buf)
    codeblock.refresh(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, codeblock.ns, 0, -1, {})
    assert(#marks == 0, 'expected no extmarks without code blocks')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- pads: indented non-blank lines get guide/bullet extmarks; title line,
  -- unindented lines, and whitespace-only lines get none.
  do
    local pads = require('chatora.pads')
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'タイトル',
      '本文',
      ' レベル1',
      '  レベル2',
      '   ',
      ' code:y.lua',
      '  print(1)',
    })
    pads.render(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, pads.ns, 0, -1, {})
    -- Spacing widens guide levels only; the bullet hugs its text (gap = 0 by
    -- default). ' レベル1' -> bullet (1), '  レベル2' -> guide + spacing +
    -- bullet (3), '   ' indent-only -> 2×(guide + spacing) + bullet (5,
    -- Cosense shows the bullet on empty list items too), ' code:y.lua'
    -- marker keeps its bullet (1), code interior and title/plain lines -> none.
    assert(#marks == 10, 'expected 10 pad extmarks, got ' .. #marks)

    require('chatora.config').options.pads = false
    pads.render(buf)
    marks = vim.api.nvim_buf_get_extmarks(buf, pads.ns, 0, -1, {})
    assert(#marks == 0, 'expected no pad extmarks when pads=false')
    require('chatora.config').options.pads = true
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- picker: module loads and exposes its API (opening it would spawn the LSP
  -- server, which the smoke test must not do).
  do
    local picker = require('chatora.picker')
    for _, fn in ipairs({ 'open', 'accept', 'move', 'close', 'is_open' }) do
      assert(type(picker[fn]) == 'function', 'expected picker.' .. fn)
    end
    assert(picker.is_open() == false, 'picker should start closed')
  end

  -- images.lua: snacks.nvim isn't installed in this headless environment,
  -- so attach()/refresh() must behave as documented no-ops without erroring.
  do
    local images = require('chatora.images')
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '[example.icon]', '[https://example.com/pic.png]' })
    images.attach(buf, 'myproject')
    images.refresh(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- table.find_blocks: pure Cosense table-block detection.
  local ctable = require('chatora.table')

  do
    local lines = {
      'table:サンプル',
      ' 見出しA\t見出しB',
      ' あ\tい',
      'next normal line',
    }
    local blocks = ctable.find_blocks(lines)
    assert(#blocks == 1, 'expected exactly one table block, got ' .. #blocks)
    local b = blocks[1]
    assert(b.marker_line == 0, 'marker_line mismatch: ' .. b.marker_line)
    assert(b.start_line == 1, 'start_line mismatch: ' .. b.start_line)
    assert(b.end_line == 3, 'end_line mismatch: ' .. b.end_line)
    assert(b.name == 'サンプル', 'name mismatch: ' .. b.name)
    assert(#b.rows == 2, 'expected 2 rows, got ' .. #b.rows)
    assert(b.rows[1].indent == 1, 'row1 indent mismatch: ' .. b.rows[1].indent)
    assert(#b.rows[1].cells == 2 and b.rows[1].cells[1] == '見出しA' and b.rows[1].cells[2] == '見出しB', 'row1 cells mismatch')
    assert(#b.rows[2].cells == 2 and b.rows[2].cells[1] == 'あ' and b.rows[2].cells[2] == 'い', 'row2 cells mismatch')
  end

  do
    -- Blank lines inside a block belong to it; block ends at EOF if nothing
    -- dedents; rows may have differing cell counts; a second marker with no
    -- deeper-indented content following it still yields an empty-rows block.
    local lines = {
      'table:t1',
      ' a\tb\tc',
      '',
      ' d\te',
      'table:empty',
      'not indented',
    }
    local blocks = ctable.find_blocks(lines)
    assert(#blocks == 2, 'expected two blocks, got ' .. #blocks)
    assert(blocks[1].start_line == 1 and blocks[1].end_line == 4, 'first block range mismatch')
    assert(#blocks[1].rows == 3, 'expected 3 rows including the blank line, got ' .. #blocks[1].rows)
    assert(#blocks[1].rows[1].cells == 3, 'row1 expected 3 cells')
    assert(#blocks[1].rows[2].cells == 1 and blocks[1].rows[2].cells[1] == '', 'blank row expected a single empty cell')
    assert(#blocks[1].rows[3].cells == 2, 'row3 expected 2 cells')
    assert(blocks[2].marker_line == 4, 'second marker_line mismatch: ' .. blocks[2].marker_line)
    assert(blocks[2].start_line == 5 and blocks[2].end_line == 5, 'second block expected an empty interior')
    assert(#blocks[2].rows == 0, 'expected 0 rows for the empty marker')
  end

  do
    -- Trailing blank lines never end a block, but they hold no cells either:
    -- they are trimmed so the bottom border hugs the last real row.
    local blocks = ctable.find_blocks({ 'table:t', ' a\tb', '', '  ', 'after' })
    assert(#blocks == 1, 'expected one block')
    assert(blocks[1].end_line == 2, 'trailing blanks must be trimmed, end_line = ' .. blocks[1].end_line)
    assert(#blocks[1].rows == 1, 'expected the single real row')
  end

  -- table.render: extmark shape for a 3-column, 2-row (header + 1 body)
  -- table with mixed column widths, so both padding and no-padding cells
  -- are exercised on every column position (first/middle/last).
  do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'table:t1',
      ' a\tbb\tccc',
      ' dddd\te\tf',
      'not a table line',
    })
    ctable.render(buf)

    local marks = vim.api.nvim_buf_get_extmarks(buf, ctable.ns, 0, -1, { details = true })
    local conceal_n, virt_lines_n, header_n = 0, 0, 0
    for _, m in ipairs(marks) do
      local d = m[4]
      if d.conceal ~= nil then
        conceal_n = conceal_n + 1
      end
      if d.virt_lines ~= nil then
        virt_lines_n = virt_lines_n + 1
      end
      if d.hl_group == 'ChatoraTableHeader' then
        header_n = header_n + 1
      end
    end
    -- Column widths: col1 max(1,4)=4, col2 max(2,1)=2, col3 max(3,1)=3.
    -- Row1 ('a','bb','ccc'): cell1 padded+sep, cell2 sep only (no pad),
    -- cell3 is last with 0 padding -> no extmark.
    -- Row2 ('dddd','e','f'): cell1 sep only (no pad), cell2 padded+sep,
    -- cell3 is last with padding -> padding-only extmark (no conceal).
    assert(conceal_n == 4, 'expected 4 concealed tabs, got ' .. conceal_n)
    assert(virt_lines_n == 3, 'expected 3 border lines (top/mid/bottom), got ' .. virt_lines_n)
    assert(header_n == 1, 'expected exactly one header highlight, got ' .. header_n)
    assert(#marks == 9, 'expected 9 total table extmarks, got ' .. #marks)

    require('chatora.config').options.tables = false
    ctable.render(buf)
    marks = vim.api.nvim_buf_get_extmarks(buf, ctable.ns, 0, -1, {})
    assert(#marks == 0, 'expected no table extmarks when tables=false')
    require('chatora.config').options.tables = true

    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- table.render: column width must be strdisplaywidth-based so fullwidth
  -- (double-cell) characters pad correctly, not byte- or char-length-based.
  do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'table:t2',
      ' a\t日本語',
      ' bb\tx',
    })
    ctable.render(buf)

    -- col1 width = max(strdisplaywidth('a')=1, strdisplaywidth('bb')=2) = 2.
    -- col2 width = max(strdisplaywidth('日本語')=6, strdisplaywidth('x')=1) = 6.
    -- Row1 cell1 'a': indent 1 + 1 byte -> tab conceal at col 2, padded by 1.
    local row1_cell1 = vim.api.nvim_buf_get_extmarks(buf, ctable.ns, { 1, 2 }, { 1, 2 }, { details = true })
    assert(#row1_cell1 == 1, 'expected the row1/cell1 extmark at its exact position')
    assert(row1_cell1[1][4].conceal == '', 'expected row1/cell1 tab to be concealed')
    assert(row1_cell1[1][4].virt_text[1][1] == ' ', 'expected 1-space padding for a (width 1) vs bb (width 2)')

    -- Row2 cell2 'x' is the last cell, at byte col 5 (' bb\t' = 4 bytes + 'x').
    -- It needs 5 spaces of padding: strdisplaywidth('x')=1 vs col width 6.
    local row2_cell2 = vim.api.nvim_buf_get_extmarks(buf, ctable.ns, { 2, 5 }, { 2, 5 }, { details = true })
    assert(#row2_cell2 == 1, 'expected the row2/cell2 padding extmark at its exact position')
    assert(row2_cell2[1][4].conceal == nil, 'last cell has no trailing tab to conceal')
    assert(
      row2_cell2[1][4].virt_text[1][1] == '     ',
      'expected 5-space padding for x (width 1) vs 日本語 (width 6), got: ' .. vim.inspect(row2_cell2[1][4].virt_text)
    )

    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- links.url_at: pure URL-under-cursor detection (byte columns, 0-based).
  do
    local links = require('chatora.links')
    local line = 'see [https://example.com/a] and [text https://b.io] end'
    assert(links.url_at(line, 0) == nil, 'col 0 is not inside a URL')
    assert(links.url_at(line, 5) == 'https://example.com/a', 'cursor at URL start')
    assert(links.url_at(line, 26) == 'https://example.com/a', 'cursor on the closing bracket still counts')
    assert(links.url_at(line, 38) == 'https://b.io', 'second URL, label-first form')
    assert(links.url_at('no urls here', 3) == nil, 'plain text has no URL')
  end

  -- status: state transitions drive the icon; 'saving' shields against the
  -- modified-flag churn that writing the server's normalized text causes.
  do
    local status = require('chatora.status')
    local buf = vim.api.nvim_create_buf(false, true)
    assert(status.icon(buf) == nil, 'untracked buffer has no icon')
    status.set(buf, 'clean')
    local icon, hl = status.icon(buf)
    assert(icon == '✓' and hl == 'ChatoraStatusOk', 'clean icon mismatch')
    status.set(buf, 'saving')
    status.sync(buf)
    assert(status.get(buf) == 'saving', 'sync must not override an in-flight save')
    status.set(buf, 'clean')
    status.sync(buf)
    assert(status.get(buf) == 'clean', 'sync follows the modified flag once idle')
    assert(status.component() == '', 'component is empty for untracked current buffer')
    status.forget(buf)
    assert(status.icon(buf) == nil, 'forget clears tracking')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- keymaps: attach installs the insert-mode maps on the buffer.
  do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    require('chatora.keymaps').attach(buf)
    local found_date, found_bracket = false, false
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'i')) do
      if map.lhs == '<C-T>' then
        found_date = true
      end
      if map.lhs == '[' then
        found_bracket = true
      end
    end
    assert(found_date, 'expected <C-t> insert-mode map')
    assert(found_bracket, 'expected [ autopair map')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- spacing: off by default (line=0, code=0); enabling adds virt_lines
  -- between body lines but not after the last line.
  do
    local spacing = require('chatora.spacing')
    local config = require('chatora.config')
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'タイトル', 'a', 'b', 'c' })
    spacing.render(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, spacing.ns, 0, -1, {})
    assert(#marks == 0, 'spacing disabled by default')
    config.options.spacing = { line = 1, code = 0 }
    spacing.render(buf)
    marks = vim.api.nvim_buf_get_extmarks(buf, spacing.ns, 0, -1, {})
    -- Gaps below 'a' and 'b' only: the title has title_margin, the last line
    -- has nothing after it.
    assert(#marks == 2, 'expected 2 spacing extmarks, got ' .. #marks)
    config.options.spacing = { line = 0, code = 0 }
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- account: module loads and exposes its API (calls would need the LSP).
  do
    local account = require('chatora.account')
    for _, fn in ipairs({ 'list', 'add', 'switch', 'remove' }) do
      assert(type(account[fn]) == 'function', 'expected account.' .. fn)
    end
  end
end)

if ok then
  print('SMOKE OK')
  vim.cmd('qa!')
else
  print('SMOKE FAIL')
  print(tostring(err))
  print(debug.traceback())
  vim.cmd('cquit!')
end
