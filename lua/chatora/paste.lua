-- Paste an image straight from the system clipboard into a page: write the clipboard's
-- image to a temp file, upload it (chatora/uploadImage), and replace the placeholder line
-- with the notation for the result.
local M = {}

local lsp = require('chatora.lsp')
local spinner = require('chatora.spinner')
local uri = require('chatora.uri')

M.ns = vim.api.nvim_create_namespace('chatora_paste')

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
