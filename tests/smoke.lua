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

  -- A URI with no title names no page; letting it through reaches the API as a path with
  -- an empty segment.
  do
    local p, t = uri.parse('cosense://myproject/')
    assert(p == nil and t == nil, 'a titleless URI must not parse as a page')
  end

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

  -- notations: a user-defined marker gets its own @lsp.type.<name>.cosense group,
  -- an invalid entry (2-char marker) is dropped with a warning instead of erroring,
  -- a valid single-character icon is kept, a multi-character icon is dropped while
  -- its name/hl survive, and lsp.lua's wire list is marker-ascending.
  do
    chatora.setup({
      notations = {
        ['|'] = { name = 'highlight', icon = '📌', hl = { bg = '#3a3a00', bold = true } },
        ['='] = { name = 'boxed', hl = { link = 'WarningMsg' } },
        ['@'] = { name = 'bad_icon', icon = 'ab', hl = {} },
        ['??'] = { name = 'bad', hl = {} },
      },
    })

    local notations = require('chatora.config').options.notations
    assert(notations['??'] == nil, 'expected the 2-char marker entry to be dropped')
    assert(notations['|'].icon == '📌', 'expected the 1-char icon to be kept')
    assert(notations['@'] ~= nil, 'expected the bad-icon entry to survive')
    assert(notations['@'].icon == nil, 'expected the multi-char icon to be dropped')
    assert(notations['@'].name == 'bad_icon', 'expected name to survive a dropped icon')

    local highlight_hl = vim.api.nvim_get_hl(0, { name = '@lsp.type.highlight.cosense' })
    assert(next(highlight_hl) ~= nil, 'expected @lsp.type.highlight.cosense to be defined')
    local boxed_hl = vim.api.nvim_get_hl(0, { name = '@lsp.type.boxed.cosense' })
    assert(next(boxed_hl) ~= nil, 'expected @lsp.type.boxed.cosense to be defined')

    assert(
      require('chatora.config').notation_icon('highlight') == '📌',
      'expected notation_icon to resolve name -> icon'
    )
    assert(
      require('chatora.config').notation_icon('boxed') == nil,
      'expected notation_icon to return nil when no icon is configured'
    )

    -- An `hl` Neovim rejects (a misspelled key, say) must say so: the group is left
    -- undefined either way, and silence reads as "chatora ignored my notation".
    do
      local warned = nil
      local orig = vim.notify
      vim.notify = function(msg, level)
        if type(msg) == 'string' and msg:find('ハイライトを適用できません', 1, true) then
          warned = msg
        end
        return orig(msg, level)
      end
      chatora.setup({
        notations = { ['!'] = { name = 'bad_hl', hl = { bg = '#ff0000', textColor = '#fff' } } },
      })
      vim.notify = orig
      assert(warned ~= nil, 'expected a warning for a highlight spec Neovim rejects')
      assert(warned:find('textColor', 1, true), 'the warning must name the offending key')
      chatora.setup({
        notations = {
          ['|'] = { name = 'highlight', icon = '📌', hl = { bg = '#3a3a00', bold = true } },
          ['='] = { name = 'boxed', hl = { link = 'WarningMsg' } },
          ['@'] = { name = 'bad_icon', icon = 'ab', hl = {} },
          ['??'] = { name = 'bad', hl = {} },
        },
      })
    end

    local list = require('chatora.config').notation_list()
    assert(#list == 3, 'expected 3 valid notations in the wire list, got ' .. #list)
    assert(list[1].marker == '=' and list[1].name == 'boxed', 'expected marker-ascending order')
    assert(list[2].marker == '@' and list[2].name == 'bad_icon', 'expected marker-ascending order')
    assert(list[3].marker == '|' and list[3].name == 'highlight', 'expected marker-ascending order')

    chatora.setup({})
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
    -- An *empty* line has indent 0, so it ends the block exactly like any other line at
    -- or below the marker's indent — this is what Cosense itself does. A block runs to
    -- EOF if nothing dedents; a name with no extension falls back to name-as-lang.
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
    assert(blocks[1].start_line == 1 and blocks[1].end_line == 2, 'first block range mismatch')
    assert(blocks[1].name == 'a.lua', 'first block name mismatch: ' .. blocks[1].name)
    assert(blocks[2].marker_line == 4, 'second marker_line mismatch: ' .. blocks[2].marker_line)
    assert(blocks[2].start_line == 5 and blocks[2].end_line == 6, 'second block range mismatch')
    assert(blocks[2].name == 'bash', 'second block name mismatch: ' .. blocks[2].name)
  end

  do
    -- A whitespace-only line keeps its indent, so it stays inside: that is how a blank
    -- line survives in the middle of a code block.
    local blocks = codeblock.find_blocks({ 'code:a.lua', '  local x = 1', '  ', '  local y = 2' })
    assert(#blocks == 1, 'expected one block, got ' .. #blocks)
    assert(blocks[1].start_line == 1 and blocks[1].end_line == 4, 'whitespace-only line ended the block')
    assert(blocks[1].indent == 0, 'marker indent mismatch: ' .. tostring(blocks[1].indent))
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

    -- The marker reads as a bare filename label, and the interior is tinted.
    local details = vim.api.nvim_buf_get_extmarks(buf, codeblock.ns, 0, -1, { details = true })
    local conceal_n, label_n, tinted = 0, 0, 0
    for _, m in ipairs(details) do
      local d = m[4]
      if d.conceal ~= nil then
        conceal_n = conceal_n + 1
      end
      if d.hl_group == 'ChatoraCodeLabel' then
        label_n = label_n + 1
      end
      if d.line_hl_group == 'ChatoraCodeBlock' then
        tinted = tinted + 1
      end
    end
    assert(conceal_n == 1, 'expected the code: prefix to be concealed, got ' .. conceal_n)
    assert(label_n == 1, 'expected the filename to be highlighted as a label')
    assert(tinted == 2, 'expected both interior lines tinted, got ' .. tinted)

    -- Numbering restarts per block, right-aligned to the block's own widest number.
    local numbers = {}
    for _, m in ipairs(details) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        if m[4].virt_text_pos == 'inline' then
          numbers[#numbers + 1] = chunk[1]
        end
      end
    end
    assert(vim.deep_equal(numbers, { '1 ', '2 ' }), 'unexpected line numbers: ' .. vim.inspect(numbers))

    require('chatora.config').options.codeblock_numbers = false
    codeblock.refresh(buf)
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, codeblock.ns, 0, -1, { details = true })) do
      assert(m[4].virt_text_pos ~= 'inline', 'expected no numbers when codeblock_numbers = false')
    end
    require('chatora.config').options.codeblock_numbers = true
    codeblock.refresh(buf)

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

  -- code blocks: the interior keeps the editor's own line tint, while the marker line
  -- shares the inline-code badge. The codeBlock token spans both and carries the badge
  -- background, so the interior's own tint has to outrank it.
  do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'T', 'code:a.lua', '  local x = 1' })
    codeblock.refresh(buf)

    local function bg_of(name)
      return vim.api.nvim_get_hl(0, { name = name, link = false }).bg
    end
    local cursorline = bg_of('CursorLine')
    if cursorline then
      assert(bg_of('ChatoraCodeBlock') == cursorline, 'the interior keeps the line tint')
      assert(bg_of('ChatoraCodeLabel') ~= cursorline, 'the label wears the badge instead')
    end

    local interior = nil
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, codeblock.ns, 0, -1, { details = true })) do
      if mark[4].line_hl_group == 'ChatoraCodeBlock' then
        interior = mark[4]
      end
    end
    assert(interior ~= nil, 'expected the interior to be tinted')
    assert(interior.priority ~= nil and interior.priority > 125, 'the tint must outrank semantic tokens')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- pads: one bullet per indented line, and nothing drawn on the text itself.
  do
    local pads = require('chatora.pads')
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {
      'タイトル',
      '本文',
      ' レベル1',
      '  レベル2',
      '   ',
      ' code:y.lua',
      '  print(1)',
    }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    pads.render(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, pads.ns, 0, -1, { details = true })

    local bullet_rows = {}
    for _, mark in ipairs(marks) do
      local row, col, details = mark[2], mark[3], mark[4]
      -- Read the glyph from the module rather than naming it, so changing the shipped
      -- bullet does not turn this into a test of what it used to be.
      local carries_bullet = false
      for _, chunk in ipairs(details.virt_text or {}) do
        carries_bullet = carries_bullet or chunk[1]:find(pads.default_bullet(), 1, true) ~= nil
      end
      if carries_bullet then
        -- An overlay is replaced *by* the glyph, so a bullet the font draws two cells wide
        -- would paint over the line's first real character. Inline text pushes instead.
        assert(details.virt_text_pos == 'inline', 'the bullet must be inline, not an overlay')
        bullet_rows[row] = (bullet_rows[row] or 0) + 1
      end
      -- Anything at or past the first text byte moves an empty list item's end-of-line
      -- cursor off the column its siblings' text starts at.
      local indent = #(lines[row + 1]:match('^[ \t]*') or '')
      assert(col < indent, 'pads must not draw at or past the first text byte')
    end

    -- Every indented line outside a code block gets exactly one bullet, the empty list
    -- item included (Cosense shows one there too); the code interior gets none.
    for _, row in ipairs({ 2, 3, 4, 5 }) do
      assert(bullet_rows[row] == 1, 'expected one bullet on row ' .. row)
    end
    for _, row in ipairs({ 0, 1, 6 }) do
      assert(bullet_rows[row] == nil, 'expected no bullet on row ' .. row)
    end

    require('chatora.config').options.pads = false
    pads.render(buf)
    marks = vim.api.nvim_buf_get_extmarks(buf, pads.ns, 0, -1, {})
    assert(#marks == 0, 'expected no pad extmarks when pads=false')
    require('chatora.config').options.pads = true
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- completion: the pieces the icon key needs to turn a highlighted suggestion into
  -- [title.icon]. The engines themselves are not installed here, so only the parts that
  -- do not need one are exercised.
  do
    local completion = require('chatora.completion')

    -- link_range: the bracket pair the cursor is inside, as 1-based byte positions.
    local open, close = completion.link_range('a [foo] b', 5)
    assert(open == 3 and close == 7, 'link_range mismatch: ' .. tostring(open) .. ',' .. tostring(close))
    assert(completion.link_range('a [[foo]] b', 6) == nil, '[[ ]] is an image, not a link')
    assert(completion.link_range('no brackets', 5) == nil, 'expected nil outside a pair')
    assert(completion.link_range('a [unclosed', 5) == nil, 'an unclosed pair is not a link context')

    -- title_of: whatever shape the engine hands an entry over in.
    assert(completion.title_of({ label = 'ページ' }) == 'ページ', 'label should win')
    assert(completion.title_of({ word = '[ページ]' }) == 'ページ', 'the inserted form is bracketed')
    assert(completion.title_of({ abbr = '#タグ' }) == 'タグ', 'a hashtag entry names the same page')
    assert(completion.title_of({}) == nil, 'an entry with no text names nothing')
    assert(completion.title_of(nil) == nil, 'nil is not an entry')

    -- With no menu open there is nothing selected, so the key falls back to the own icon.
    assert(completion.selected_title() == nil, 'expected no selection without a menu')
  end

  -- surround: the visual-mode decoration keys, including pressing one twice.
  do
    local surround = require('chatora.surround')
    local buf = vim.api.nvim_create_buf(false, true)
    local prev = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(0, buf)

    --- Select bytes [from, to] of `text` (1-based, inclusive) and press each marker.
    --- Returns the resulting line and the mode the last press left behind.
    local function press(text, from, to, markers)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
      vim.api.nvim_win_set_cursor(0, { 1, from - 1 })
      vim.cmd('normal! v')
      vim.api.nvim_win_set_cursor(0, { 1, to - 1 })
      for _, marker in ipairs(markers) do
        surround.wrap(marker)
      end
      local mode = vim.fn.mode()
      vim.cmd('normal! \27')
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], mode
    end

    local cases = {
      { 'hello world', 1, 5, { '*' }, '[* hello] world' },
      -- Repeating the marker grows the run rather than nesting: this is how [***] is typed.
      { 'hello world', 1, 5, { '*', '*', '*' }, '[*** hello] world' },
      { 'hello', 1, 5, { '*', '*', '*', '*', '*', '*' }, '[***** hello]' },
      { 'hello world', 1, 5, { '[' }, '[hello] world' },
      { 'hello', 1, 5, { '_', '_' }, 'hello' },
      { 'hello', 1, 5, { '*', '/' }, '[*/ hello]' },
      -- Multibyte: the selection must cover whole characters, not bytes.
      { 'あいうえお', 1, 9, { '*' }, '[* あいう]えお' },
      { 'a bold b', 3, 6, { '*' }, 'a [* bold] b' },
    }
    for _, case in ipairs(cases) do
      local got = press(case[1], case[2], case[3], case[4])
      assert(
        got == case[5],
        ('surround %s: expected %q, got %q'):format(vim.inspect(case[4]), case[5], got)
      )
    end

    -- A decoration key stays in visual mode so it can be pressed again; `[` has nothing to
    -- build on, so it hands back normal mode.
    local _, after_star = press('hello', 1, 5, { '*' })
    assert(after_star:find('v'), 'expected * to stay in visual mode, got ' .. after_star)
    local _, after_bracket = press('hello', 1, 5, { '[' })
    assert(after_bracket == 'n', 'expected [ to return to normal mode, got ' .. after_bracket)

    vim.api.nvim_win_set_buf(0, prev)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- page info: tiers separated by rules, relative times, and a gutter every value shares
  -- so the icon a terminal may not draw cannot shift the column.
  do
    local actions = require('chatora.actions')
    local now = os.time()
    assert(actions.relative_time(now - 30) == '30秒前', 'seconds')
    assert(actions.relative_time(now - 60 * 12) == '12分前', 'minutes')
    assert(actions.relative_time(now - 3600 * 5) == '5時間前', 'hours')
    assert(actions.relative_time(now - 86400 * 3) == '3日前', 'days')
    assert(actions.relative_time(nil) == nil, 'a page with no such timestamp has no age')
    assert(actions.relative_time(0) == nil, 'epoch 0 means never, not 1970')

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, 'cosense://proj/' .. vim.uri_encode('情報テスト'))
    vim.bo[buf].buftype = 'acwrite'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '情報テスト' })
    local prev = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(0, buf)
    vim.b[buf].chatora_meta = {
      created = now - 86400 * 3,
      updated = now - 60 * 12,
      accessed = now - 3600 * 5,
      views = 128,
      linked = 6,
      linesCount = 42,
      charsCount = 1980,
      pin = 0,
      pageRank = 1.2345,
      snapshotCount = 12,
      createdBy = { id = 'u1', name = 'taro', displayName = 'taro' },
      updatedBy = { id = 'u2', name = 'hanako', displayName = 'はなこ' },
      collaborators = { { id = 'u3', name = 'ken', displayName = 'ken' } },
    }

    actions.info()
    local info_buf = vim.api.nvim_get_current_buf()
    assert(info_buf ~= buf, 'expected the info float to be focused')
    local lines = vim.api.nvim_buf_get_lines(info_buf, 0, -1, false)
    local text = table.concat(lines, '\n')

    assert(text:find('taro', 1, true), 'the author must be named')
    assert(text:find('はなこ', 1, true), 'the last editor must be named, by display name')
    assert(text:find('3日前', 1, true), 'times are relative, not stamps')
    assert(not text:find('%d%d%d%d%-%d%d%-%d%d'), 'no absolute dates in the panel')

    -- Two rules, drawn as empty lines wearing a highlight rather than as box characters
    -- the cursor could land inside.
    local rules = 0
    for _, line in ipairs(lines) do
      if line == '' then
        rules = rules + 1
      end
    end
    assert(rules == 2, 'expected two separators, got ' .. rules)

    -- The two single-author rows share a value column, gutter included. The collaborators
    -- row reserves one gutter per person, so it deliberately starts further right.
    local ns = vim.api.nvim_create_namespace('chatora_page_info')
    local name_cols = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(info_buf, ns, 0, -1, { details = true })) do
      if mark[4].hl_group == 'ChatoraInfoName' then
        name_cols[#name_cols + 1] = mark[3]
      end
    end
    assert(#name_cols == 3, 'expected 作成 / 更新 / 共同編集者 to be marked, got ' .. #name_cols)
    assert(name_cols[1] == name_cols[2], 'the two author rows must share one column')
    assert(name_cols[3] > name_cols[2], 'a second icon has to widen the collaborators gutter')
    assert(text:find('共同編集者', 1, true), 'collaborators are listed when there are any')

    vim.api.nvim_win_close(0, true)

    -- A page nobody else has touched has no collaborators row at all, the way the web
    -- popup omits it.
    local solo = vim.deepcopy(vim.b[buf].chatora_meta)
    solo.collaborators = nil
    vim.b[buf].chatora_meta = solo
    actions.info()
    local solo_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    assert(not solo_text:find('共同編集者', 1, true), 'no collaborators means no row')

    vim.api.nvim_win_close(0, true)
    vim.api.nvim_win_set_buf(0, prev)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- read-only pages: locked against editing, and the lock explains itself. 'modifiable'
  -- alone answers every edit with E21, which never mentions whose project it is.
  do
    local page = require('chatora.page')
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, 'cosense://other-project/' .. vim.uri_encode('ページ'))
    vim.bo[buf].buftype = 'acwrite'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'ページ', '本文' })
    local prev = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(0, buf)

    page.mark_read_only(buf, 'other-project')
    assert(vim.bo[buf].modifiable == false, 'a read-only page takes no edits')
    assert(vim.b[buf].chatora_read_only == true, 'and says so to the rest of the plugin')

    local said = nil
    local orig = vim.notify
    vim.notify = function(msg)
      said = msg
    end
    for _, key in ipairs({ 'i', 'a', 'x', 'p' }) do
      said = nil
      local map = vim.fn.maparg(key, 'n', false, true)
      assert(map.callback ~= nil, key .. ' must be answered, not left to E21')
      map.callback()
      assert(said ~= nil and said:find('other-project', 1, true), 'the reason names the project')
    end
    vim.notify = orig

    vim.api.nvim_win_set_buf(0, prev)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- related panel: one window however often it is opened, and it can change edge.
  do
    local related = require('chatora.related')
    local page = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(page, 'cosense://proj/' .. vim.uri_encode('関連テスト'))
    vim.bo[page].buftype = 'acwrite'
    local prev = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(0, page)

    local function panel_wins()
      local found = {}
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
        if name:match('^chatora://related') then
          found[#found + 1] = w
        end
      end
      return found
    end

    -- Auto-open and an explicit toggle both fire for one page, so opening twice must not
    -- leave a second panel that nothing tracks.
    related.open()
    related.open()
    assert(#panel_wins() == 1, 'expected one panel window, got ' .. #panel_wins())
    assert(related.side() == 'bottom', 'the shipped default is a bottom strip')

    related.flip()
    assert(related.side() == 'right', 'flip must change edge')
    local wins = panel_wins()
    assert(#wins == 1, 'flipping must not leave the old panel behind, got ' .. #wins)
    local opts = require('chatora.config').options
    assert(
      vim.api.nvim_win_get_width(wins[1]) == opts.related_width,
      'a right-hand panel takes related_width'
    )
    assert(
      vim.api.nvim_win_get_height(wins[1]) > opts.related_height,
      'a right-hand panel is a column, not the bottom strip'
    )

    related.flip()
    assert(related.side() == 'bottom', 'flip must go back')
    related.close()
    assert(#panel_wins() == 0, 'close must leave nothing behind')

    vim.api.nvim_win_set_buf(0, prev)
    vim.api.nvim_buf_delete(page, { force = true })
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
    assert(type(images.invalidate) == 'function', 'expected images.invalidate')
    images.invalidate(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- pads.extra_cells: the shift image placement applies to every column past a
  -- line's indent. Placements are positioned in display cells, so getting this
  -- wrong (or measuring the prefix in bytes) drags images off their notation.
  do
    local pads = require('chatora.pads')
    local config = require('chatora.config')
    assert(pads.extra_cells('本文', 1) == 0, 'an unindented line gains nothing')
    -- Level 1 is bullet + gap; each further level adds guide + spacing.
    -- What the reader sees is the indent's own cells plus what the pads add, and the whole
    -- point is that it comes to the same thing at the same depth however the indent was
    -- written — spaces, tabs and full-width spaces are all one level but not one width.
    local function text_column(line, tabstop)
      local cells = 0
      for _, entry in ipairs(require('chatora.indent').scan(line)) do
        cells = cells + require('chatora.indent').cells(entry.char, tabstop)
      end
      return cells + pads.extra_cells(line, tabstop)
    end

    -- tabstop 1 is what a page buffer uses: one tab is one level, so it is one cell.
    local TS = 1
    local one = text_column(' a', TS)
    assert(text_column('　a', TS) == one, 'a full-width space is one level, like a space')
    assert(text_column('\ta', TS) == one, 'so is a tab')
    assert(text_column('　 a', TS) == text_column('  a', TS), 'and a mixed indent matches too')
    assert(text_column('\t　a', TS) == text_column('  a', TS), 'in any combination')
    -- The bullet is drawn once whatever the depth, so a level is worth the step alone.
    assert(
      text_column('  a', TS) - one == text_column('   a', TS) - text_column('  a', TS),
      'every level is worth the same'
    )

    -- A numbered item draws no bullet, so it gains only the widening.
    assert(
      pads.extra_cells('  1. foo', 1) == pads.extra_cells('  foo', 1) - 1,
      'a numbered item gains everything but the bullet'
    )
    config.options.pads = false
    assert(pads.extra_cells('   a', 1) == 0, 'no shift when pads are disabled')
    config.options.pads = true
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
    -- A blank line ends a table (unlike a code block), so the indented line
    -- after it is a plain line, not another row. Rows may have differing cell
    -- counts; a marker with no deeper-indented content still yields a block
    -- with an empty interior.
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
    assert(blocks[1].start_line == 1 and blocks[1].end_line == 2, 'first block must end at the blank line')
    assert(#blocks[1].rows == 1, 'expected 1 row before the blank line, got ' .. #blocks[1].rows)
    assert(#blocks[1].rows[1].cells == 3, 'row1 expected 3 cells')
    assert(blocks[2].marker_line == 4, 'second marker_line mismatch: ' .. blocks[2].marker_line)
    assert(blocks[2].start_line == 5 and blocks[2].end_line == 5, 'second block expected an empty interior')
    assert(#blocks[2].rows == 0, 'expected 0 rows for the empty marker')
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
    local marker_conceal, tab_conceal, virt_lines_n, header_n, label_n = 0, 0, 0, 0, 0
    for _, m in ipairs(marks) do
      local row, d = m[2], m[4]
      if d.conceal ~= nil then
        if row == 0 then
          marker_conceal = marker_conceal + 1
        else
          tab_conceal = tab_conceal + 1
        end
      end
      if d.virt_lines ~= nil then
        virt_lines_n = virt_lines_n + 1
      end
      if d.hl_group == 'ChatoraTableHeader' then
        header_n = header_n + 1
      end
      if d.hl_group == 'ChatoraTableLabel' then
        label_n = label_n + 1
      end
    end
    -- Column widths: col1 max(1,4)=4, col2 max(2,1)=2, col3 max(3,1)=3.
    -- Row1 ('a','bb','ccc'): cell1 padded+sep, cell2 sep only (no pad),
    -- cell3 is last with 0 padding -> no extmark.
    -- Row2 ('dddd','e','f'): cell1 sep only (no pad), cell2 padded+sep,
    -- cell3 is last with padding -> padding-only extmark (no conceal).
    assert(tab_conceal == 4, 'expected 4 concealed tabs, got ' .. tab_conceal)
    assert(marker_conceal == 1, 'expected the table: prefix to be concealed')
    assert(label_n == 1, 'expected the block name to be highlighted as a label')
    assert(virt_lines_n == 3, 'expected 3 border lines (top/mid/bottom), got ' .. virt_lines_n)
    assert(header_n == 1, 'expected exactly one header highlight, got ' .. header_n)

    require('chatora.config').options.tables = false
    ctable.render(buf)
    marks = vim.api.nvim_buf_get_extmarks(buf, ctable.ns, 0, -1, {})
    assert(#marks == 0, 'expected no table extmarks when tables=false')
    require('chatora.config').options.tables = true

    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- table.render: a row's drawn width must equal the border's, or the frame
  -- doesn't close around the content. Checked as an invariant over the emitted
  -- extmarks rather than by re-simulating the renderer.
  do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'table:t',
      ' 指標\tX（7日間）\tMeta（2日目時点）',
      ' インプレッション\t125,035\t1,099',
      ' 欠けた行\tひとつだけ',
    })
    ctable.render(buf)

    -- Cells are measured individually: strdisplaywidth on the raw line would
    -- expand the separator tabs by 'tabstop', which the render conceals away.
    local blocks = ctable.find_blocks(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local rows_by_line = {}
    for i, r in ipairs(blocks[1].rows) do
      rows_by_line[blocks[1].start_line + i - 1] = r
    end

    local function drawn_width(row)
      local width = rows_by_line[row].indent
      for _, cell in ipairs(rows_by_line[row].cells) do
        width = width + vim.fn.strdisplaywidth(cell)
      end
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ctable.ns, { row, 0 }, { row, -1 }, { details = true })) do
        for _, chunk in ipairs(m[4].virt_text or {}) do
          width = width + vim.fn.strdisplaywidth(chunk[1])
        end
      end
      return width
    end

    local border = nil
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ctable.ns, 0, -1, { details = true })) do
      local lines_spec = m[4].virt_lines
      if lines_spec and not border then
        border = vim.fn.strdisplaywidth(lines_spec[1][1][1])
      end
    end
    assert(border, 'expected a border line')

    for row = 1, 3 do
      assert(
        drawn_width(row) == border,
        ('row %d is %d cells wide but the border is %d'):format(row, drawn_width(row), border)
      )
    end

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
    -- Pending states animate rather than showing a fixed glyph.
    local spin = status.icon(buf)
    assert(spin and spin ~= '✓' and spin ~= '●', 'expected a spinner frame while saving, got ' .. tostring(spin))
    status.set(buf, 'loading')
    status.sync(buf)
    assert(status.get(buf) == 'loading', 'sync must not override an in-flight load')
    status.set(buf, 'clean')
    status.sync(buf)
    assert(status.get(buf) == 'clean', 'sync follows the modified flag once idle')
    -- The component follows the last tracked page even when the cursor sits
    -- elsewhere (the sidebar), which is what the sidebar winbar relies on.
    assert(status.component(buf):find('✓'), 'component reports the page it is asked about')
    assert(status.component():find('✓'), 'component falls back to the last active page')
    status.forget(buf)
    assert(status.component() == '', 'component is empty once nothing is tracked')
    assert(status.icon(buf) == nil, 'forget clears tracking')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- keymaps: attach installs the insert-mode maps on the buffer.
  do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    require('chatora.keymaps').attach(buf)
    local lhs = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'i')) do
      lhs[map.lhs] = true
    end
    assert(lhs['<C-T>'], 'expected <C-t> insert-mode map')
    assert(lhs['['], 'expected [ autopair map')
    -- <C-i> and <Tab> are the same byte on most terminals, so both have to be
    -- registered: whichever one nvim resolves must still do something useful.
    assert(lhs['<C-I>'], 'expected <C-i> icon map')
    assert(lhs['<Tab>'], 'expected the shared <Tab> handler')

    local global = {}
    for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
      if map.desc and map.desc:find('chatora') then
        global[map.lhs] = true
      end
    end
    assert(global['\\ct'], 'expected the sidebar toggle to be mapped globally')
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

  -- sidebar polling: a refetched first batch replaces the head and pulls an
  -- edited page up out of the tail, without duplicating it or dropping the
  -- rest of what infinite scroll already loaded.
  do
    local sidebar = require('chatora.sidebar')
    local lsp = require('chatora.lsp')
    local orig_start, orig_ok, orig_request = lsp.ensure_start, lsp.request_ok, lsp.request

    local listed = {}
    for i = 1, 5 do
      listed[i] = { id = 'id' .. i, title = 'ページ' .. i, updated = 100 - i }
    end
    lsp.ensure_start = function() end
    lsp.request_ok = function(method, _, cb)
      if method == 'chatora/listPages' then
        cb({ ok = true, count = #listed, scanned = #listed, pages = listed })
      end
    end

    sidebar.open('proj')
    local buf = vim.fn.bufnr('chatora://sidebar')
    local function titles()
      local out = {}
      for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        out[i] = l:sub(2)
      end
      return out
    end
    assert(vim.deep_equal(titles(), { 'ページ1', 'ページ2', 'ページ3', 'ページ4', 'ページ5' }), 'initial list')

    -- ページ4 was just edited, so the server now lists it first.
    lsp.request = function(method, _, cb)
      if method ~= 'chatora/listPages' then
        return
      end
      cb(nil, {
        ok = true,
        count = 5,
        scanned = 2,
        pages = {
          { id = 'id4', title = 'ページ4', updated = 200 },
          { id = 'id1', title = 'ページ1', updated = 99 },
        },
      })
    end
    sidebar.poll()
    assert(
      vim.deep_equal(titles(), { 'ページ4', 'ページ1', 'ページ2', 'ページ3', 'ページ5' }),
      'poll must move the edited page to the top exactly once, got ' .. vim.inspect(titles())
    )

    -- An unchanged batch must leave the list (and its extmarks) untouched.
    local before = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()['chatora_sidebar'], 0, -1, {})
    lsp.request = function(method, _, cb)
      if method == 'chatora/listPages' then
        cb(nil, { ok = true, count = 5, scanned = 2, pages = {
          { id = 'id4', title = 'ページ4', updated = 200 },
          { id = 'id1', title = 'ページ1', updated = 99 },
        } })
      end
    end
    sidebar.poll()
    assert(vim.deep_equal(titles(), { 'ページ4', 'ページ1', 'ページ2', 'ページ3', 'ページ5' }), 'idle poll changed the list')
    assert(#before == #vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()['chatora_sidebar'], 0, -1, {}), 'idle poll redrew')

    -- toggle closes and reopens without re-running the auth/project flow.
    sidebar.toggle()
    assert(vim.fn.bufwinid(buf) == -1, 'toggle should close the sidebar')
    sidebar.toggle()
    assert(vim.fn.bufwinid(buf) ~= -1, 'toggle should reopen the sidebar')
    sidebar.close()

    lsp.ensure_start, lsp.request_ok, lsp.request = orig_start, orig_ok, orig_request
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
