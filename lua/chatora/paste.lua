-- Pasting into a page: text gets the web editor's adjustments (transformText in its
-- bundle: adjustIndent, quoteMultiLines), an image is uploaded and replaced by its notation.
local M = {}

local lsp = require('chatora.lsp')
local spinner = require('chatora.spinner')
local uri = require('chatora.uri')
local indent = require('chatora.indent')

M.ns = vim.api.nvim_create_namespace('chatora_paste')

-- ---------------------------------------------------------------------------
-- text
-- ---------------------------------------------------------------------------

--- Inside a `code:` or `table:` block: the nearest shallower line above is its marker.
local function in_block(lines, row)
  local depth = indent.level(lines[row])
  for r = row - 1, 1, -1 do
    if indent.level(lines[r]) < depth then
      return lines[r]:match('^%s*code:') ~= nil or lines[r]:match('^%s*table:') ~= nil
    end
  end
  return false
end

--- What every pasted line after the first gets in front of it, and whether that is a quote
--- marker; nil when the paste goes in as it is. On a blank line it is the whitespace up to
--- `insert_at` (a byte offset); on any line of a code or table block it is the line's own
--- indent, since one line indented less than the marker ends the block.
function M.line_prefix(line, insert_at, in_block)
  local before = line:sub(1, insert_at)
  if not in_block then
    local quote_indent = before:match('^(%s*)>')
    if quote_indent then
      return quote_indent .. '> ', true
    end
  end
  if line:match('^%s*$') then
    return before, false
  end
  if in_block then
    return line:match('^%s*'), false
  end
  return nil
end

--- `lines` with `prefix` in front of every line but the first, which continues the line
--- the cursor (or the previous chunk) is on.
function M.prefixed(lines, prefix, quote)
  if quote then
    -- One blank line per `\n\n`, exactly as the web's replace does it.
    lines = vim.split(table.concat(lines, '\n'):gsub('\n\n', '\n'), '\n', { plain = true })
  end
  local out = { lines[1] }
  for i = 2, #lines do
    out[i] = prefix .. lines[i]
  end
  return out
end

--- Byte offset the paste goes in at: before the cursor in insert mode, after the character
--- under it otherwise (how vim.paste puts it).
local function insert_offset(mode, line, col)
  if mode:find('^i') or #line == 0 then
    return col
  end
  -- str_utf_end takes a 1-based index; the cursor column is 0-based.
  return col + vim.str_utf_end(line, col + 1) + 1
end

--- `p` / `P` with a register of several lines, given the same room a bracketed paste gets.
--- A linewise register inside a block takes the block's indent on every line; anything
--- Vim's own put would do differently (one line, blockwise) is left to it.
function M.put(after, register)
  register = (register == nil or register == '') and '"' or register
  local count = vim.v.count1
  local function vims_own()
    vim.cmd(('normal! %d"%s%s'):format(count, register, after and 'p' or 'P'))
  end
  local info = vim.fn.getreginfo(register)
  local lines = info.regcontents or {}
  local regtype = (info.regtype or 'v'):sub(1, 1)
  if #lines < 2 or regtype == '\22' then
    return vims_own()
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local line = buf_lines[row] or ''
  local block = in_block(buf_lines, row)
  if regtype == 'V' then
    if not block then
      return vims_own()
    end
    local indent = line:match('^%s*')
    local out = {}
    for i, l in ipairs(lines) do
      out[i] = indent .. l
    end
    vim.api.nvim_put(out, 'l', after, true)
    return
  end
  local insert_at = after and insert_offset('n', line, col) or col
  local prefix, quote = M.line_prefix(line, insert_at, block)
  if not prefix then
    return vims_own()
  end
  vim.api.nvim_put(M.prefixed(lines, prefix, quote), 'c', after, true)
end

--- Map `p` and `P` in a page buffer to M.put, unless `edit.paste_indent` is off. A
--- read-only page keeps the mapping that explains why it cannot be edited.
function M.attach(bufnr)
  if vim.b[bufnr].chatora_read_only or not require('chatora.config').options.edit.paste_indent then
    return
  end
  for key, after in pairs({ p = true, P = false }) do
    vim.keymap.set('n', key, function()
      M.put(after, vim.v.register)
    end, { buffer = bufnr, silent = true, desc = 'chatora: 貼り付け（ブロックの中では字下げを揃える）' })
  end
end

-- Kept out of a local so that :Chatora reload wraps the original again, not our own wrapper.
local FALLBACK_KEY = 'chatora_paste_fallback'

--- Hook bracketed paste, which reaches Neovim through vim.paste and no keymap.
function M.install()
  local fallback = _G[FALLBACK_KEY] or vim.paste
  _G[FALLBACK_KEY] = fallback
  -- Decided on the first chunk, the only one that sees the cursor line as it was.
  local prefix, quote
  vim.paste = function(lines, phase)
    local first_chunk = phase < 2
    if first_chunk then
      prefix, quote = nil, false
      local mode = vim.api.nvim_get_mode().mode
      local lands_on_cursor_line = mode:find('^i') or mode:find('^n')
      if vim.bo.filetype == 'cosense' and #lines > 1 and lands_on_cursor_line then
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local line = buf_lines[row] or ''
        prefix, quote = M.line_prefix(line, insert_offset(mode, line, col), in_block(buf_lines, row))
      end
    end
    if prefix then
      lines = M.prefixed(lines, prefix, quote)
    end
    return fallback(lines, phase)
  end
end

-- ---------------------------------------------------------------------------
-- image
-- ---------------------------------------------------------------------------

-- Neovim's registers only hold text, so getting at the clipboard's *bytes* means asking
-- the platform's own tool. Each entry writes the image to `%s` and exits non-zero when the
-- clipboard holds none, which is also how "is there an image?" is answered — probing
-- separately would mean running the tool twice.
local EXTRACTORS = {
  { cmd = 'pngpaste', args = { '%s' } },
  { cmd = 'wl-paste', args = { '--type', 'image/png', '--output', '%s' } },
  { cmd = 'xclip', args = { '-selection', 'clipboard', '-t', 'image/png', '-o' }, stdout = true },
  -- Last: always present on macOS, but shells out through AppleScript, so it is the
  -- fallback rather than the first choice.
  {
    cmd = 'osascript',
    args = {
      '-e',
      'set p to POSIX file "%s"\n'
        .. 'set f to open for access p with write permission\n'
        .. 'set eof f to 0\n'
        .. 'write (the clipboard as «class PNGf») to f\n'
        .. 'close access f',
    },
  },
}

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraPasteProgress', { link = 'DiagnosticWarn', default = true })
end

--- Write the clipboard's image to `path`. False both when no tool is installed and when
--- the clipboard holds no image: the caller cannot act differently on those.
local function extract_clipboard_image(path)
  for _, extractor in ipairs(EXTRACTORS) do
    if vim.fn.executable(extractor.cmd) == 1 then
      local args = vim.tbl_map(function(arg)
        return arg:gsub('%%s', (path:gsub('%%', '%%%%')))
      end, extractor.args)
      local result = vim.system(vim.list_extend({ extractor.cmd }, args), { text = false }):wait()
      if result.code == 0 then
        if extractor.stdout then
          if not result.stdout or #result.stdout == 0 then
            return false
          end
          local file = io.open(path, 'wb')
          if not file then
            return false
          end
          file:write(result.stdout)
          file:close()
        end
        -- The osascript path opens the file before it reads the clipboard, so a clipboard
        -- holding no image leaves an empty file behind rather than none at all.
        local stat = (vim.uv or vim.loop).fs_stat(path)
        return stat ~= nil and stat.size > 0
      end
    end
  end
  return false
end

--- The line the upload will land on, tracked by extmark so edits above it do not send the
--- result to the wrong place.
local function reserve_line(bufnr, row)
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { '' })
  return vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {})
end

local function show_progress(bufnr, mark_id)
  ensure_hl()
  spinner.subscribe('paste:' .. bufnr .. ':' .. mark_id, function()
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, mark_id, {})
    if not pos[1] then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, pos[1], pos[1] + 1)
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, pos[1], 0, {
      id = mark_id,
      virt_text = { { spinner.frame() .. ' アップロード中…', 'ChatoraPasteProgress' } },
      virt_text_pos = 'overlay',
    })
  end)
end

local function finish(bufnr, mark_id, text)
  spinner.release('paste:' .. bufnr .. ':' .. mark_id)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, mark_id, {})
  vim.api.nvim_buf_del_extmark(bufnr, M.ns, mark_id)
  if not pos[1] then
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, pos[1], pos[1] + 1, false, text and { text } or {})
end

--- Upload the clipboard image and write its notation on a new line below the cursor.
--- A no-op (with a message) when the clipboard holds no image.
function M.image()
  local bufnr = vim.api.nvim_get_current_buf()
  local project, title = uri.parse(vim.api.nvim_buf_get_name(bufnr))
  if not project then
    vim.notify('[chatora] Cosense のページではありません', vim.log.levels.WARN)
    return
  end

  local path = vim.fn.tempname() .. '.png'
  if not extract_clipboard_image(path) then
    vim.notify(
      '[chatora] クリップボードに画像がありません（または pngpaste / wl-paste / xclip が必要です）',
      vim.log.levels.WARN
    )
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local mark_id = reserve_line(bufnr, row)
  show_progress(bufnr, mark_id)

  lsp.request('chatora/uploadImage', { project = project, title = title, path = path }, function(err, result)
    os.remove(path)
    if err or not result or result.ok == false then
      finish(bufnr, mark_id, nil)
      vim.notify('[chatora] ' .. ((result and result.message) or 'アップロードに失敗しました'), vim.log.levels.ERROR)
      return
    end
    finish(bufnr, mark_id, result.notation)
  end)
end

return M
