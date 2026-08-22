-- Headless smoke test: `nvim --headless --clean -u NORC -c "luafile nvim/tests/smoke.lua"`
-- Does NOT require the LSP server to be running.
local ok, err = pcall(function()
  local this_file = debug.getinfo(1, 'S').source:sub(2)
  local tests_dir = vim.fn.fnamemodify(this_file, ':p:h')
  local nvim_root = vim.fn.fnamemodify(tests_dir, ':h')

  vim.opt.rtp:prepend(nvim_root)

  -- plugin/*.lua is normally auto-sourced at startup; since we add nvim_root
  -- to rtp only after startup, source it manually here.
  dofile(nvim_root .. '/plugin/chatora.lua')

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

  -- Highlight groups from the semantic token legend must be defined.
  local legend = {
    'title', 'link', 'projectLink', 'externalLink', 'hashtag', 'code',
    'codeBlock', 'formula', 'icon', 'quote', 'bold', 'italic', 'strike',
    'underline', 'image', 'table',
  }
  for _, token in ipairs(legend) do
    local name = '@lsp.type.' .. token .. '.cosense'
    local hl = vim.api.nvim_get_hl(0, { name = name })
    assert(next(hl) ~= nil, 'expected highlight group to be defined: ' .. name)
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
