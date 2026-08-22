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
  for _, fn in ipairs({ 'open', 'new', 'search', 'related', 'logout', 'help' }) do
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
    -- ' レベル1' -> bullet + spacing (2), '  レベル2' -> guide + bullet + 2
    -- spacings (4), ' code:y.lua' marker keeps pads (2), code interior and
    -- title/plain/whitespace-only lines -> none.
    assert(#marks == 8, 'expected 8 pad extmarks, got ' .. #marks)

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
