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

  -- A page named `next.js` is a page, not JavaScript: whatever asks about the buffer's
  -- name — `:filetype detect`, or a plugin calling vim.filetype.match — has to say so, or
  -- another language server attaches to the page and starts linting it.
  do
    local page = vim.filetype.match({ filename = 'cosense://proj/next.js' })
    assert(page == 'cosense', 'a page whose title ends in .js is still cosense, got ' .. tostring(page))
    assert(vim.filetype.match({ filename = 'next.js' }) == 'javascript', 'ordinary files still detect as themselves')

    vim.cmd('new')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, 'cosense://proj/next.js')
    vim.cmd('filetype detect')
    assert(vim.bo[buf].filetype == 'cosense', 'detection must not take the page for JavaScript')
    vim.cmd('close')
    vim.api.nvim_buf_delete(buf, { force = true })
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
        -- One glyph, two codepoints: U+25B6 and a variation selector. Counting codepoints
        -- rejects it, and Neovim conceals it perfectly well.
        ['>'] = { name = 'point', icon = '▶️' },
      },
    })

    local notations = require('chatora.config').options.notations
    assert(notations['??'] == nil, 'expected the 2-char marker entry to be dropped')
    assert(notations['|'].icon == '📌', 'expected the 1-char icon to be kept')
    assert(notations['>'].icon == '▶️', 'an emoji with a variation selector is one character')
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

  -- A block chatora cannot colour says so once, and only for a language `:TSInstall` can
  -- actually fetch — a code block named for a file, not for a language, is the common case.
  do
    local orig_parsers = package.loaded['nvim-treesitter.parsers']
    local orig_notify = vim.notify
    package.loaded['nvim-treesitter.parsers'] = {
      get_parser_configs = function()
        return { php = {}, php_only = {}, python = {} }
      end,
    }
    local said = {}
    vim.notify = function(msg)
      said[#said + 1] = msg
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'コード',
      -- No `<?` anywhere: only php_only would colour this one, so php is not the fix.
      'code:index.php', ' echo 1;',
      'code:page.php', ' <?php echo 2;',
      -- Already spoken for, and never a language anyone wrote a parser for.
      'code:another.php', ' echo 3;',
      'code:メモ', ' 買い物',
    })
    codeblock.refresh(buf)
    codeblock.refresh(buf)

    assert(#said == 2, 'one message per language: ' .. vim.inspect(said))
    assert(said[1]:find(':TSInstall php_only', 1, true), 'tagless PHP asks for php_only, got ' .. said[1])
    assert(said[2]:find(':TSInstall php）', 1, true), 'a tagged block asks for php, got ' .. said[2])

    vim.notify, package.loaded['nvim-treesitter.parsers'] = orig_notify, orig_parsers
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

  -- normalize_indent: levels are preserved, the characters are not.
  do
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, 'cosense://proj/' .. vim.uri_encode('整形'))
    vim.bo[buf].buftype = 'acwrite'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      '整形', '　全角1', '\tタブ1', '  半角2', '　\t混在2', '素の行', '  1. 番号',
    })
    local prev = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(0, buf)

    local before = {}
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      before[i] = require('chatora.indent').level(line)
    end

    local orig = vim.notify
    vim.notify = function() end
    require('chatora.actions').normalize_indent()
    vim.notify = orig

    local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(after) do
      local levels = require('chatora.indent').scan(line)
      assert(#levels == before[i], 'level ' .. i .. ' changed')
      -- Checked per character, not with a pattern: a Lua character class matches bytes,
      -- and a full-width space shares its first byte with most CJK characters.
      for _, entry in ipairs(levels) do
        assert(entry.char == ' ', 'line ' .. i .. ' still has a non-space indent')
      end
    end
    assert(after[6] == '素の行', 'an unindented line is left alone')
    assert(after[7] == '  1. 番号', 'text past the indent is untouched')

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

  -- gd on a Gyazo capture that moves: the playable URL goes to whatever `video` names, and
  -- only falls back to the browser when nothing took it.
  do
    local links = require('chatora.links')
    local config = require('chatora.config')
    local lsp = require('chatora.lsp')
    local orig_request, orig_system = lsp.request, vim.system
    local orig_video, orig_external = config.options.video, config.options.external_link

    local url = 'https://gyazo.com/0204f06d4ed4af1554dc3c2a87a806b2'
    local mp4 = 'https://i.gyazo.com/0204f06d4ed4af1554dc3c2a87a806b2.mp4'
    -- Its own window: an earlier test leaves the sidebar pinning the current one.
    vim.cmd('new')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, 'cosense://proj/動画')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '動画', '[' .. url .. ']' })
    vim.api.nvim_win_set_cursor(0, { 2, 5 })
    lsp.request = function(method, _, cb)
      if method == 'chatora/urlAt' then
        cb(nil, { ok = true, url = url, play = mp4 })
      end
    end

    local played = nil
    config.options.video = function(given)
      played = given
      return true
    end
    links.goto_definition()
    assert(played == mp4, 'a function is handed the playable URL, got ' .. tostring(played))

    local ran = nil
    vim.system = function(cmd)
      ran = table.concat(cmd, ' ')
      return { wait = function() end }
    end
    config.options.video = { 'mpv', '--loop', '{url}' }
    links.goto_definition()
    assert(ran == 'mpv --loop ' .. mp4, 'a command gets {url} filled in, got ' .. tostring(ran))

    ran = nil
    config.options.video = 'open'
    links.goto_definition()
    assert(ran == 'open ' .. mp4, 'a bare command name takes the URL as its argument')

    -- Nothing configured: the browser path decides, and `external_link = 'ignore'` means
    -- nothing happens at all.
    ran, played = nil, nil
    config.options.video = false
    config.options.external_link = 'ignore'
    links.goto_definition()
    assert(ran == nil and played == nil, 'video = false leaves the link to the browser')

    lsp.request, vim.system = orig_request, orig_system
    config.options.video, config.options.external_link = orig_video, orig_external
    vim.cmd('close')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- A JSON null arrives as vim.NIL, which is truthy: without dropping it, every optional
  -- field in the protocol reads as present and the first concatenation blows up.
  do
    local lsp = require('chatora.lsp')
    local cleaned = lsp.without_nulls({
      ok = true,
      url = vim.NIL,
      meta = { title = 'ページ', photo = vim.NIL, links = { vim.NIL, 'a' } },
    })
    assert(cleaned.url == nil, 'a null field must read as absent')
    assert(cleaned.meta.photo == nil, 'nested too')
    assert(cleaned.meta.links[2] == 'a', 'and the rest of the table survives')
    assert(cleaned.meta.title == 'ページ', 'as do the fields that were there')
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

  -- A link to a file in the project wears an icon where its bracket was; an ordinary link
  -- keeps its bracket hidden and nothing more.
  do
    local render = require('chatora.render')
    local config = require('chatora.config')
    local lsp = require('chatora.lsp')
    local orig_request = lsp.request

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'ファイル',
      '[report.html https://scrapbox.io/files/6a8812d6df81a13e54b76439.html]',
      '[ラベル https://example.com/page]',
    })
    lsp.request = function(method, _, cb)
      if method ~= 'chatora/decorations' then
        return
      end
      cb(nil, {
        ok = true,
        quotes = {},
        conceal = {
          { line = 1, startChar = 0, endChar = 1, kind = 'file' },
          { line = 2, startChar = 0, endChar = 1 },
        },
      })
    end
    render.refresh(buf)

    local function conceal_at(row)
      local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, { row, 0 }, { row, -1 }, { details = true })
      return marks[1] and marks[1][4].conceal
    end
    assert(conceal_at(1) == config.options.file_icon, 'a file link is badged, got ' .. tostring(conceal_at(1)))
    assert(conceal_at(2) == '', 'an ordinary link is not, got ' .. tostring(conceal_at(2)))

    config.options.file_icon = false
    render.refresh(buf)
    assert(conceal_at(1) == '', 'file_icon = false leaves the bracket simply hidden')
    config.options.file_icon = '󰈔'

    lsp.request = orig_request
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- Indent guides land in every column of Cosense's one-space-per-level indent, on top of
  -- the bullets. The plugins that can be told per buffer are told, including one that only
  -- exists after the reader opens some other file.
  do
    local render = require('chatora.render')
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'インデント', ' 子', '  孫' })
    render.attach(buf)
    assert(vim.b[buf].snacks_indent == false, 'snacks.indent must be told to skip the page')
    assert(vim.b[buf].miniindentscope_disable == true, 'so must mini.indentscope')

    -- indent-blankline arrives late: it loads on the first real file, long after the page
    -- was opened, so being told once at startup would not have been enough.
    local told = nil
    package.loaded.ibl = {
      setup_buffer = function(bufnr, opts)
        told = { bufnr = bufnr, enabled = opts.enabled }
      end,
    }
    render.attach(buf)
    package.loaded.ibl = nil
    assert(told and told.bufnr == buf and told.enabled == false, 'ibl must be told once it exists')

    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- 'linebreak' moves a run of Japanese to the next row whole, so a page window has it off
  -- whatever the reader's global setting says.
  do
    local render = require('chatora.render')
    vim.cmd('new')
    local buf = vim.api.nvim_get_current_buf()
    vim.wo.linebreak = true
    render.attach(buf)
    assert(vim.wo.linebreak == false, 'a page window must not use linebreak')
    vim.cmd('close')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- Reopening a page paints what it said last time, synchronously. Neovim restores the
  -- cursor the moment BufReadCmd returns, so a buffer that comes back empty answers a
  -- jumplist entry past line 1 with E19 before the fetch has landed.
  do
    local lsp = require('chatora.lsp')
    local config = require('chatora.config')
    local orig_start, orig_ok, orig_request = lsp.ensure_start, lsp.request_ok, lsp.request
    -- Opening a page opens the related panel; this test is about the buffer, and the extra
    -- window outlives it otherwise.
    local orig_auto = config.options.related_auto_open
    config.options.related_auto_open = false
    local lines = {}
    for i = 1, 40 do
      lines[i] = ('%02d 行目'):format(i)
    end
    lsp.ensure_start = function() end
    lsp.request = function() end
    lsp.request_ok = function(method, _, cb)
      if method ~= 'chatora/openPage' then
        return
      end
      -- Deferred, like the real one: the point is what the buffer holds before it answers.
      vim.defer_fn(function()
        cb({
          ok = true,
          uri = 'cosense://proj/ジャンプ',
          text = table.concat(lines, '\n'),
          exists = true,
          meta = { linked = 0, views = 0, linesCount = 40, charsCount = 200, pageRank = 0, snapshotCount = 0, updated = 0, created = 0, pin = 0 },
        })
      end, 10)
    end

    -- Its own window: an earlier test leaves the sidebar pinning the current one.
    local before = vim.api.nvim_get_current_win()
    vim.cmd('new')
    local win = vim.api.nvim_get_current_win()
    vim.cmd('edit cosense://proj/ジャンプ')
    vim.wait(500, function() return vim.api.nvim_buf_line_count(0) > 5 end)
    assert(vim.api.nvim_buf_line_count(0) == 40, 'the page loads')

    local page = vim.api.nvim_get_current_buf()
    vim.cmd('enew')
    vim.api.nvim_buf_delete(page, { force = true })
    vim.cmd('edit cosense://proj/ジャンプ')
    assert(
      vim.api.nvim_buf_line_count(0) == 40,
      'a reopened page must have its lines before the fetch returns, got '
        .. vim.api.nvim_buf_line_count(0)
    )
    assert(not vim.bo.modified, 'and must not look edited')
    assert(pcall(vim.api.nvim_win_set_cursor, 0, { 20, 0 }), 'so the cursor can go back where it was')

    vim.wait(500)
    assert(vim.api.nvim_win_get_cursor(0)[1] == 20, 'and the fetch must not move it')

    lsp.ensure_start, lsp.request_ok, lsp.request = orig_start, orig_ok, orig_request
    config.options.related_auto_open = orig_auto
    vim.api.nvim_buf_delete(vim.api.nvim_get_current_buf(), { force = true })
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(before) then
      vim.api.nvim_set_current_win(before)
    end
  end

  -- buftext: only the run that differs is written, so the extmarks around it survive.
  do
    local buftext = require('chatora.buftext')
    local buf = vim.api.nvim_create_buf(false, true)
    local ns = vim.api.nvim_create_namespace('smoke_buftext')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'タイトル', '一行目', '二行目', '三行目' })
    local top = vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {})
    local bottom = vim.api.nvim_buf_set_extmark(buf, ns, 3, 0, {})

    assert(buftext.set(buf, { 'タイトル', '一行目', '書き換え', '三行目' }), 'a changed line is written')
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'タイトル', '一行目', '書き換え', '三行目' }),
      'buftext.set must leave the buffer holding exactly what it was given'
    )
    assert(#vim.api.nvim_buf_get_extmark_by_id(buf, ns, top, {}) > 0, 'the mark above survives')
    assert(
      vim.api.nvim_buf_get_extmark_by_id(buf, ns, bottom, {})[1] == 3,
      'the mark below stays on its own line'
    )

    assert(not buftext.set(buf, vim.api.nvim_buf_get_lines(buf, 0, -1, false)), 'identical text writes nothing')

    -- Loading a page into the buffer it was opened in: the text arrives whole and the
    -- cursor stays at the top, rather than riding a blank line to the bottom.
    vim.cmd('new')
    local fresh = vim.api.nvim_get_current_buf()
    buftext.set(fresh, { 'タイトル', '一行目', '二行目', '' })
    assert(vim.api.nvim_win_get_cursor(0)[1] == 1, 'a load must leave the cursor on line 1')
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(fresh, 0, -1, false), { 'タイトル', '一行目', '二行目', '' }),
      'and the buffer holding exactly the page'
    )
    vim.cmd('close')
    vim.api.nvim_buf_delete(fresh, { force = true })
    assert(buftext.set(buf, { 'タイトル' }), 'a shorter document is written')
    assert(#vim.api.nvim_buf_get_lines(buf, 0, -1, false) == 1, 'and ends up short')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- image_backend: a backend of the reader's own is what draws, in table or function form,
  -- and a broken one says so instead of leaving the page blank.
  do
    local images = require('chatora.images')
    local config = require('chatora.config')
    local orig_backend = config.options.image_backend

    local mine = { place = function() end }
    config.options.image_backend = mine
    assert(images.backend() == mine, 'a table with place() is the backend')

    config.options.image_backend = function()
      return mine
    end
    assert(images.backend() == mine, 'a function is asked for one')

    -- A function may answer with a name instead, which is how a reader picks per terminal:
    -- the protocol a terminal takes is not chatora's to know.
    config.options.image_backend = function()
      return 'snacks'
    end
    local named = images.backend()
    config.options.image_backend = 'snacks'
    assert(
      (named == nil) == (images.backend() == nil),
      'a name from a function must resolve like the name itself'
    )

    -- No place() to call: chatora says so once and carries on with what it can find, which
    -- in a headless test is nothing at all.
    config.options.image_backend = { close = function() end }
    local fell_back = images.backend()
    assert(fell_back ~= mine, 'a table without place() is not used')

    config.options.image_backend = orig_backend
  end

  -- images: a page that changes one line keeps the pictures that did not move, redraws the
  -- one that did, and tries again when the backend accepted a placement that never arrived.
  do
    local images = require('chatora.images')
    local buftext = require('chatora.buftext')
    local lsp = require('chatora.lsp')
    local orig_backend, orig_request = images.backend, lsp.request

    local placed, closed = {}, {}
    local healthy = true
    images.backend = function()
      return {
        place = function(_, path, geom)
          local id = #placed + 1
          placed[id] = { path = path, row = geom.row }
          return {
            close = function()
              closed[#closed + 1] = id
            end,
            ok = function()
              return healthy
            end,
          }
        end,
      }
    end

    -- Its own window: the placements are looked up per window, and the sidebar above pins
    -- the one it left behind.
    vim.cmd('new')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, 'cosense://proj/画像')
    local function lines_of(second)
      return { '画像', second, '[https://gyazo.com/b]', '[https://gyazo.com/c]' }
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines_of('[https://gyazo.com/a]'))

    lsp.request = function(method, _, cb)
      if method == 'chatora/images' then
        local found = {}
        for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
          local url = line:match('^%[(https://gyazo%.com/%a)%]$')
          if url then
            found[#found + 1] = { line = row - 1, startChar = 0, endChar = #line, src = url, standalone = true }
          end
        end
        cb(nil, { ok = true, images = found })
      elseif method == 'chatora/fetchAsset' then
        cb(nil, { ok = true, path = '/dev/null' })
      end
    end

    images.attach(buf, 'proj')
    images.refresh(buf)
    assert(#placed == 3, 'expected a placement per image, got ' .. #placed)
    assert(#closed == 0, 'nothing to close on a first draw')

    -- Nothing changed at all: no teardown, no redraw.
    images.refresh(buf)
    assert(#placed == 3 and #closed == 0, 'an untouched page must not redraw anything')

    -- A line is added between the pictures, which is what a merge looks like. The two
    -- below it move down with the text and are left alone.
    buftext.set(buf, {
      '画像',
      '[https://gyazo.com/a]',
      '書き足した行',
      '[https://gyazo.com/b]',
      '[https://gyazo.com/c]',
    })
    images.refresh(buf)
    assert(
      #placed == 3 and #closed == 0,
      'pictures that only moved with the text must be left alone, got '
        .. #placed
        .. ' placements / '
        .. #closed
        .. ' closed'
    )

    -- One picture's line is rewritten: only that one is closed and drawn again.
    buftext.set(buf, {
      '画像',
      '[https://gyazo.com/d]',
      '書き足した行',
      '[https://gyazo.com/b]',
      '[https://gyazo.com/c]',
    })
    images.refresh(buf)
    assert(#placed == 4, 'the rewritten picture is drawn again, got ' .. #placed .. ' placements')
    assert(vim.deep_equal(closed, { 1 }), 'only the rewritten one is closed, got ' .. vim.inspect(closed))

    -- A placement the backend accepts but never draws is tried again.
    healthy = false
    buftext.set(buf, { '画像', '[https://gyazo.com/e]' })
    images.refresh(buf)
    local before = #placed
    assert(
      vim.wait(3000, function()
        return #placed > before
      end),
      'a placement that never arrived must be drawn again'
    )
    healthy = true

    images.backend, lsp.request = orig_backend, orig_request
    vim.cmd('close')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- A line of several pictures is one strip: the server composes it, it stands for every
  -- notation in the line, and without a composer the pictures still come, one under another.
  do
    local images = require('chatora.images')
    local config = require('chatora.config')
    local lsp = require('chatora.lsp')
    local orig_backend, orig_request = images.backend, lsp.request
    local orig_gallery = config.options.image_gallery

    local placed = {}
    images.backend = function()
      return {
        place = function(_, path, geom, opts)
          placed[#placed + 1] = {
            path = path,
            members = geom.members and #geom.members or nil,
            rows = opts.max_height,
          }
          return { close = function() end }
        end,
      }
    end

    vim.cmd('new')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, 'cosense://proj/並ぶ画像')
    local function show(urls)
      local parts = {}
      for i, url in ipairs(urls) do
        parts[i] = '[' .. url .. ']'
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '並ぶ画像', ' ' .. table.concat(parts, ' ') })
    end

    local composed = {}
    local compose_ok = true
    lsp.request = function(method, params, cb)
      if method == 'chatora/images' then
        local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
        local found = {}
        for url in line:gmatch('%[(https://[^%]]+)%]') do
          local at = line:find('[' .. url .. ']', 1, true)
          found[#found + 1] = {
            line = 1,
            startChar = at - 1,
            endChar = at + #url + 1,
            src = url,
            kind = 'image',
            standalone = false,
            gallery = true,
            large = false,
          }
        end
        cb(nil, { ok = true, images = found })
      elseif method == 'chatora/composeAssets' then
        composed[#composed + 1] = params
        if compose_ok then
          cb(nil, { ok = true, path = '/tmp/strip.png', members = { 0, 1, 2 } })
        else
          cb(nil, { ok = false, code = 'error', message = 'no composer' })
        end
      elseif method == 'chatora/fetchAsset' then
        cb(nil, { ok = true, path = '/dev/null' })
      end
    end

    local three = { 'https://example.com/1.png', 'https://example.com/2.png', 'https://example.com/3.png' }
    show(three)
    -- A tile 8 cells wide: three fit in any window.
    config.options.image_gallery = { rows = 4, aspect = 1 }
    images.attach(buf, 'proj')
    images.refresh(buf)
    assert(#composed == 1, 'one strip for the line, got ' .. #composed)
    assert(vim.deep_equal(composed[1].urls, three), 'the strip holds the pictures in order')
    assert(
      vim.deep_equal(composed[1].tile, { width = 720, height = 720 }),
      'the tile follows the aspect, got ' .. vim.inspect(composed[1].tile)
    )
    assert(
      #placed == 1 and placed[1].members == 3 and placed[1].rows == 4,
      'one placement standing for three, four rows tall: ' .. vim.inspect(placed)
    )
    local concealed = 0
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, images.ns, 0, -1, { details = true })) do
      if mark[4].conceal == '' then
        concealed = concealed + 1
      end
    end
    assert(concealed == 3, 'every notation hides behind the strip, got ' .. concealed)

    -- A tile as wide as the window: one per strip, so the line wraps into three strips.
    config.options.image_gallery = { rows = 40, aspect = 1 }
    images.invalidate(buf)
    placed, composed = {}, {}
    images.refresh(buf)
    assert(#composed == 3 and #placed == 3, 'one strip per picture when only one fits, got ' .. #composed)

    -- No composer: each picture is placed on its own.
    compose_ok = false
    config.options.image_gallery = { rows = 4, aspect = 1 }
    show({ 'https://example.com/4.png', 'https://example.com/5.png', 'https://example.com/6.png' })
    images.invalidate(buf)
    placed, composed = {}, {}
    images.refresh(buf)
    assert(#composed == 1, 'the strip was asked for once, got ' .. #composed)
    assert(#placed == 3, 'without a strip the pictures are placed one by one, got ' .. #placed)

    config.options.image_gallery = orig_gallery
    images.backend, lsp.request = orig_backend, orig_request
    vim.cmd('close')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- A quote is a box under its text, not dimmed text: the default group carries a
  -- background and leaves the foreground alone, and `dim = true` brings the old look back.
  do
    local config = require('chatora.config')
    local quote = require('chatora.quote')
    local orig = config.options.quote

    -- `default = true` only fills an undefined group, so each variant starts from a cleared one.
    config.options.quote = true
    vim.cmd('highlight clear ChatoraQuoteText')
    quote.ensure_hl()
    local hl = vim.api.nvim_get_hl(0, { name = 'ChatoraQuoteText', link = false })
    assert(hl.bg ~= nil and hl.fg == nil, 'the quote box is a background only, got ' .. vim.inspect(hl))
    local bar = vim.api.nvim_get_hl(0, { name = 'ChatoraQuoteBar', link = false })
    assert(bar.bg == hl.bg, 'the bar stands on the same box, got ' .. vim.inspect(bar))

    -- In a list the bar takes the last indent character's cell and `> ` disappears, so the
    -- text starts one cell after the indent, like a plain item's and like every wrapped row.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ' > 引用', '> 上の段' })
    quote.render(buf, { { line = 0, startChar = 1, endChar = 3 }, { line = 1, startChar = 0, endChar = 2 } })
    local bars, hidden, boxes = {}, {}, {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, quote.ns, 0, -1, { details = true })) do
      local row, col, details = mark[2], mark[3], mark[4]
      if details.virt_text then
        bars[row] = col
      elseif details.conceal == '' then
        hidden[row] = { col, details.end_col }
      elseif details.hl_group == 'ChatoraQuoteText' then
        boxes[row] = { col, details.end_row, details.hl_eol }
      end
    end
    assert(bars[0] == 0 and vim.deep_equal(hidden[0], { 1, 3 }), 'list quote: bar on the indent, `> ` hidden')
    assert(bars[1] == 0 and vim.deep_equal(hidden[1], { 1, 2 }), 'top-level quote: bar on `>`, space hidden')
    assert(vim.deep_equal(boxes[0], { 0, 1, true }) and vim.deep_equal(boxes[1], { 0, 2, true }), 'the box runs from the bar to the row end, got ' .. vim.inspect(boxes))
    vim.api.nvim_buf_delete(buf, { force = true })

    config.options.quote = { dim = true }
    vim.cmd('highlight clear ChatoraQuoteText')
    quote.ensure_hl()
    hl = vim.api.nvim_get_hl(0, { name = 'ChatoraQuoteText' })
    assert(hl.link == 'Comment', 'dim = true links the text to Comment, got ' .. vim.inspect(hl))

    config.options.quote = orig
    vim.cmd('highlight clear ChatoraQuoteText')
    quote.ensure_hl()
  end

  -- With the URL handler installed the system default browser is chatora itself, so a URL
  -- sent to "the browser" would come straight back; the browser the handler recorded gets it.
  do
    local browser = require('chatora.browser')
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local orig_dir, orig_system, orig_open = vim.env.CHATORA_URL_HANDLER_DIR, vim.system, vim.ui.open
    vim.env.CHATORA_URL_HANDLER_DIR = dir
    local spawned, opened, code = nil, nil, 0
    vim.system = function(cmd)
      spawned = cmd
      return {
        wait = function()
          return { code = code }
        end,
      }
    end
    vim.ui.open = function(url)
      opened = url
    end

    browser.open('https://scrapbox.io/p/t')
    assert(spawned == nil and opened == 'https://scrapbox.io/p/t', 'without the handler, the default is asked')

    vim.fn.writefile({ 'com.example.Browser' }, dir .. '/fallback')
    spawned, opened = nil, nil
    browser.open('https://scrapbox.io/p/t')
    assert(
      vim.deep_equal(spawned, { 'open', '-b', 'com.example.Browser', 'https://scrapbox.io/p/t' }) and opened == nil,
      'with the handler, the recorded browser gets it, got ' .. vim.inspect(spawned)
    )

    code = 1
    spawned, opened = nil, nil
    browser.open('https://example.com')
    assert(opened == 'https://example.com', 'a recorded browser that cannot open falls back to the default')

    vim.env.CHATORA_URL_HANDLER_DIR, vim.system, vim.ui.open = orig_dir, orig_system, orig_open
    vim.fn.delete(dir, 'rf')
  end

  -- snacks deletes an image from the terminal with its last placement and leaves it marked
  -- sent, and past its own budget unmarks the oldest while their placements stay. Both
  -- have to read as "nothing on screen", and the first has to send again when placed.
  do
    local images = require('chatora.images')
    local config = require('chatora.config')
    local orig_backend_opt, orig_snacks = config.options.image_backend, package.loaded.snacks
    local img = {
      sent = true,
      placements = {},
      failed = function()
        return false
      end,
      ready = function()
        return true
      end,
    }
    local made = 0
    package.loaded.snacks = {
      image = {
        supports_terminal = function()
          return true
        end,
        placement = {
          new = function()
            made = made + 1
            local id = made
            local p = { img = img, closed = false }
            img.placements[id] = p
            function p:ready()
              return true
            end
            function p:close()
              self.closed = true
              img.placements[id] = nil
            end
            return p
          end,
        },
      },
    }
    config.options.image_backend = 'snacks'
    local backend = images.backend()
    assert(backend, 'the fake snacks is taken as the backend')
    local buf = vim.api.nvim_create_buf(false, true)
    local geom = { row = 1, byte_col = 0, byte_end = 5, screen_col = 0 }
    local handle = backend.place(buf, '/tmp/x.png', geom, { height = 1 })
    assert(handle and handle.ok() == true, 'a sent, ready image is on screen')
    img.sent = false
    assert(handle.ok() == false, 'an image snacks unmarked has nothing on screen')
    img.sent = true
    handle.close()
    assert(img.sent == false, 'closing the last placement unmarks the image, so the next one sends again')
    package.loaded.snacks = orig_snacks
    config.options.image_backend = orig_backend_opt
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- A new page starts as an empty buffer, as on the web: the first line becomes the title on
  -- the first save, which is when the page comes to exist. An empty title, or one a page
  -- already has, leaves the buffer as it is.
  do
    local page = require('chatora.page')
    local lsp = require('chatora.lsp')
    local orig_request, orig_ok, orig_start = lsp.request, lsp.request_ok, lsp.ensure_start
    local asked, exists = {}, false
    lsp.ensure_start = function()
      return true
    end
    lsp.request_ok = function(method, params, cb)
      if method == 'chatora/openPage' then
        cb({ ok = true, exists = exists, text = params.title .. '\n' })
      end
    end
    lsp.request = function(method, params, cb)
      if method == 'chatora/openPage' then
        asked[#asked + 1] = 'open ' .. params.title
        cb(nil, { ok = true, exists = exists, text = params.title .. '\n' })
      elseif method == 'chatora/savePage' then
        asked[#asked + 1] = 'save ' .. params.uri
        cb(nil, { ok = true })
      end
    end
    local orig_notify = vim.notify
    vim.notify = function() end
    -- Opening a page can open the related panel beside it, a window later tests would
    -- land in; this test is about the page alone.
    local config = require('chatora.config')
    local orig_related = config.options.related_auto_open
    config.options.related_auto_open = false

    vim.cmd('new')
    vim.wo.winfixbuf = false
    page.open_untitled('proj', vim.api.nvim_get_current_win())
    local buf = vim.api.nvim_get_current_buf()
    vim.cmd('stopinsert')
    assert(
      vim.api.nvim_buf_get_name(buf) == 'cosense://proj/無題' and vim.b[buf].chatora_untitled,
      'an untitled page wears a stand-in name'
    )
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '' }), 'and starts empty')

    vim.cmd('write')
    assert(vim.b[buf].chatora_untitled and #asked == 0, 'an empty title is refused before anything is asked')

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '新しいページ', '本文' })
    exists = true
    vim.cmd('write')
    assert(vim.b[buf].chatora_untitled, 'a title a page already has is refused')
    assert(vim.deep_equal(asked, { 'open 新しいページ' }), 'and nothing is saved: ' .. vim.inspect(asked))

    exists = false
    asked = {}
    vim.cmd('write')
    assert(
      vim.api.nvim_buf_get_name(buf) == 'cosense://proj/新しいページ' and not vim.b[buf].chatora_untitled,
      'the first line names the page, got ' .. vim.api.nvim_buf_get_name(buf)
    )
    assert(
      vim.deep_equal(asked, { 'open 新しいページ', 'save cosense://proj/新しいページ' }),
      'the page is opened under its name and then saved: ' .. vim.inspect(asked)
    )

    vim.notify = orig_notify
    config.options.related_auto_open = orig_related
    lsp.request, lsp.request_ok, lsp.ensure_start = orig_request, orig_ok, orig_start
    vim.cmd('close!')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- The sidebar follows the page the reader moves to, and a project it has listed before
  -- comes back without asking the server again.
  do
    local sidebar = require('chatora.sidebar')
    local lsp = require('chatora.lsp')
    local orig_start, orig_ok = lsp.ensure_start, lsp.request_ok

    local listed = {}
    lsp.ensure_start = function() end
    lsp.request_ok = function(method, params, cb)
      if method == 'chatora/listPages' then
        listed[#listed + 1] = params.project
        cb({
          ok = true,
          count = 1,
          scanned = 1,
          pages = { { id = params.project, title = params.project .. ' のページ', updated = 1 } },
        })
      elseif method == 'chatora/authStatus' then
        cb({ ok = true, authenticated = true, user = { id = 'u1', name = 'me', displayName = 'Me' } })
      end
    end

    local function listing()
      return vim.api.nvim_buf_get_lines(vim.fn.bufnr('chatora://sidebar'), 0, -1, false)[1]:sub(2)
    end

    sidebar.open('alpha')
    assert(listing() == 'alpha のページ', 'sidebar opened on alpha, got ' .. listing())

    vim.cmd('wincmd l')
    local editor = vim.api.nvim_get_current_win()
    local function enter(name)
      local b = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(b, name)
      vim.api.nvim_win_set_buf(editor, b)
      vim.api.nvim_exec_autocmds('BufEnter', { buffer = b })
      return b
    end

    enter('cosense://beta/ページ')
    assert(listing() == 'beta のページ', 'the sidebar must follow the page, got ' .. listing())
    assert(vim.api.nvim_get_current_win() == editor, 'following must not take the cursor along')
    assert(require('chatora').session.project == 'beta', 'a new page belongs to the project in front')

    enter('cosense://alpha/戻る')
    assert(listing() == 'alpha のページ', 'going back must restore alpha, got ' .. listing())
    assert(
      vim.deep_equal(listed, { 'alpha', 'beta' }),
      'a project listed once must not be listed again: ' .. vim.inspect(listed)
    )

    sidebar.close()
    lsp.ensure_start, lsp.request_ok = orig_start, orig_ok
  end

  -- telomere scrollbar: a minimap of the whole page down the right edge — the changes
  -- wherever they are, a handle sized like a scrollbar's, and ]u / [u stepping through them.
  do
    local telomere = require('chatora.telomere')
    local scrollbar = require('chatora.scrollbar')
    local lsp = require('chatora.lsp')
    local orig_ok = lsp.request_ok
    local now = os.time()
    local TOTAL = 200
    local changed = { [3] = true, [70] = true, [140] = true, [199] = true }
    lsp.request_ok = function(method, _, cb)
      if method ~= 'chatora/telomere' then
        return
      end
      local lines = {}
      for i = 1, TOTAL do
        lines[i] = { updated = changed[i] and now - 60 or now - 400 * 86400, userId = 'u1' }
      end
      cb({ ok = true, accessed = now - 3600, lines = lines })
    end

    vim.cmd('new')
    local buf = vim.api.nvim_get_current_buf()
    local text = {}
    for i = 1, TOTAL do
      text[i] = ('%03d 行'):format(i)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
    telomere.attach(buf)
    scrollbar.attach(buf)
    lsp.request_ok = orig_ok

    local rows = {}
    for _, mark in ipairs(telomere.rows(buf)) do
      rows[#rows + 1] = mark.row
    end
    assert(vim.deep_equal(rows, { 3, 70, 140, 199 }), 'changed rows: ' .. vim.inspect(rows))

    --- The bar's own window, and what it has drawn: `handle` rows and `mark` rows.
    local function bar()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative ~= '' then
          local fbuf = vim.api.nvim_win_get_buf(win)
          local handle, marks = {}, {}
          for _, m in ipairs(vim.api.nvim_buf_get_extmarks(fbuf, scrollbar.ns, 0, -1, { details = true })) do
            table.insert(m[4].line_hl_group and handle or marks, m[2])
          end
          table.sort(handle)
          table.sort(marks)
          return { win = win, handle = handle, marks = marks }
        end
      end
      return nil
    end

    local function scroll_to(line)
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      vim.cmd('normal! zt')
      scrollbar.refresh(buf)
      return bar()
    end

    local height = vim.api.nvim_win_get_height(0)
    local top = scroll_to(1)
    assert(top, 'a page taller than the window gets a bar')
    -- Every change is on the bar wherever it is in the page: this is the whole point, and
    -- line 199 is nowhere near the screen at the top of a 200-line page.
    local expected = {}
    for _, line in ipairs({ 3, 70, 140, 199 }) do
      local row = math.floor((line - 1) / TOTAL * height)
      if not vim.tbl_contains(expected, row) then
        expected[#expected + 1] = row
      end
    end
    table.sort(expected)
    assert(vim.deep_equal(top.marks, expected), 'marks: ' .. vim.inspect(top.marks) .. ' want ' .. vim.inspect(expected))

    -- The handle is sized by the share of the page on screen and keeps that size wherever
    -- it slides to, the way a browser's does.
    local size = #top.handle
    assert(size >= 1, 'the handle is at least a row')
    local bottom = scroll_to(TOTAL)
    assert(#bottom.handle == size, 'the handle must not change size while scrolling')
    assert(vim.deep_equal(bottom.marks, expected), 'the marks must not move while scrolling')
    assert(bottom.handle[1] > top.handle[1], 'the handle slides down as the page does')
    assert(bottom.handle[#bottom.handle] == height - 1, 'the end of the page puts it at the bottom')

    -- Following the bar: the row a mark sits on leads back to the line it stands for.
    assert(scrollbar.line_at(expected[1], TOTAL, height) <= 3, 'the first mark leads to the top')
    local last_line = scrollbar.line_at(expected[#expected], TOTAL, height)
    assert(last_line > TOTAL - TOTAL / height - 1, 'the last mark leads near the end, got ' .. last_line)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    telomere.jump(1)
    assert(vim.api.nvim_win_get_cursor(0)[1] == 3, ']u must land on the first changed line')
    telomere.jump(1)
    assert(vim.api.nvim_win_get_cursor(0)[1] == 70, ']u must step to the next one')
    telomere.jump(-1)
    assert(vim.api.nvim_win_get_cursor(0)[1] == 3, '[u must step back')
    telomere.jump(-1)
    -- Nothing changed above line 3, so stepping back again wraps to the last one.
    assert(vim.api.nvim_win_get_cursor(0)[1] == 199, '[u must wrap at the top')

    -- A page that fits on screen has nothing to scroll to: no bar at all, and the gutter
    -- speaks for every line it has.
    vim.api.nvim_buf_set_lines(buf, 5, -1, false, {})
    scrollbar.refresh(buf)
    assert(bar() == nil, 'a page that fits needs no scrollbar')

    vim.cmd('close')
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- `:Chatora project <name>` switches straight to that project (and to the account the
  -- server says holds it) instead of prompting.
  do
    local chatora = require('chatora')
    local lsp = require('chatora.lsp')
    local sidebar = require('chatora.sidebar')
    local orig_ok, orig_start, orig_open = lsp.request_ok, lsp.ensure_start, sidebar.open

    local asked, opened = nil, nil
    lsp.ensure_start = function() end
    lsp.request_ok = function(method, params, cb)
      if method == 'chatora/authStatus' then
        cb({ ok = true, authenticated = true, user = { id = 'u1', name = 'tester' } })
      elseif method == 'chatora/useProject' then
        asked = params.project
        cb({ ok = true, project = params.project, foreign = false })
      end
    end
    sidebar.open = function(name)
      opened = name
    end

    chatora.dispatch('project', 'ほかのプロジェクト')
    assert(asked == 'ほかのプロジェクト', 'expected chatora/useProject for the named project, got ' .. tostring(asked))
    assert(opened == 'ほかのプロジェクト', 'expected the sidebar to open on it, got ' .. tostring(opened))
    assert(
      chatora.session.project == 'ほかのプロジェクト',
      'expected the session to remember it, got ' .. tostring(chatora.session.project)
    )

    chatora.session.project = nil
    lsp.request_ok, lsp.ensure_start, sidebar.open = orig_ok, orig_start, orig_open
  end

  -- telomere: a bar per line, thicker the more recently the line was written, blue while
  -- it is newer than the reader's last visit, and the reader's own colour once they edit it.
  do
    local telomere = require('chatora.telomere')
    local lsp = require('chatora.lsp')
    local orig_ok = lsp.request_ok
    local now = os.time()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'タイトル', '去年の行', '先週の行', 'さっきの行' })
    lsp.request_ok = function(method, _, cb)
      if method ~= 'chatora/telomere' then
        return
      end
      cb({
        ok = true,
        accessed = now - 3600,
        lines = {
          { updated = now - 400 * 86400, userId = 'u1' },
          { updated = now - 365 * 86400, userId = 'u1' },
          { updated = now - 7 * 86400, userId = 'u1' },
          { updated = now - 60, userId = 'u2' },
        },
      })
    end
    telomere.attach(buf)
    lsp.request_ok = orig_ok

    local function bars()
      local out = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, telomere.ns, 0, -1, { details = true })) do
        out[mark[2] + 1] = { text = vim.trim(mark[4].sign_text or ''), hl = mark[4].sign_hl_group }
      end
      return out
    end

    local drawn = bars()
    assert(#drawn == 4, 'expected a bar on every line, got ' .. #drawn)
    assert(drawn[3].text ~= drawn[4].text, 'a week-old line must not look like a minute-old one')
    assert(drawn[4].text == '█', 'the newest line takes the full block, got ' .. drawn[4].text)
    assert(drawn[1].text == '▏', 'a year-old line thins to a rule, got ' .. drawn[1].text)
    assert(drawn[1].hl == 'ChatoraTelomere', 'a line older than the last visit is read')
    assert(drawn[4].hl == 'ChatoraTelomereUnread', 'a line newer than the last visit is unread')

    -- Editing a line takes it away from the server's history: it is the reader's own text
    -- until it is saved.
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '書き換えた行' })
    assert(
      vim.wait(500, function()
        return (bars()[2] or {}).hl == 'ChatoraTelomereLocal'
      end),
      'expected an edited line to be drawn as the reader\'s own, got '
        .. vim.inspect(bars()[2])
    )
    assert(bars()[4].hl == 'ChatoraTelomereUnread', 'an untouched line keeps its history')
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

    -- Switching project or account is a keystroke away from the list itself.
    local keys = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      keys[map.lhs] = true
    end
    assert(keys['P'] and keys['A'], 'expected P / A in the sidebar, got ' .. vim.inspect(vim.tbl_keys(keys)))

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
