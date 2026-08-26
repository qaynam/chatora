-- Inline image rendering, over 3rd/image.nvim or snacks.nvim (both need a
-- Kitty-graphics terminal). A no-op when neither is usable.
--
-- What to draw comes from `chatora/images`; where the bytes come from is
-- `chatora/fetchAsset`, which attaches session credentials for same-origin
-- URLs so private-project icons resolve. Placements are therefore always a
-- local file path, never a remote URL.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

M.ns = vim.api.nvim_create_namespace('chatora_images')

local DEBOUNCE_MS = 200
local uv = vim.uv or vim.loop
local timers_by_bufnr = {}
local placements_by_bufnr = {} -- values are lists of { close = fn } wrappers
local project_by_bufnr = {}
local epoch_by_bufnr = {} -- bumped on every refresh(); guards stale async replies (chatora/images and chatora/fetchAsset alike)
local path_by_key = {} -- fetch key -> local file path, resolved once via fetchAsset and reused
local signature_by_bufnr = {} -- target multiset of the last applied refresh (flicker guard)
local reported = {} -- fetch failures already surfaced, so a page of them notifies once each

--- Fetch failures are normally silent (a missing image is cosmetic), but some
--- are actionable — a missing SVG rasterizer, say — and the user can only act
--- on what they are told.
local function report_once(message)
  if not message or reported[message] then
    return
  end
  reported[message] = true
  vim.notify('[chatora] ' .. message, vim.log.levels.WARN)
end

--- Border params for chatora/fetchAsset, or nil. The frame is composited into
--- the image's own pixels server-side, since a cell grid cannot hug its edges.
local function border_params()
  local opt = config.options.image_border
  if opt == false or opt == nil then
    return nil
  end
  if type(opt) ~= 'table' then
    opt = {}
  end
  return {
    width = opt.width or 1,
    color = opt.color or '#8888',
    padding = opt.padding or 12,
  }
end

--- Row cap for a standalone image. Cosense's `[[url]]` form asks for a bigger
--- rendering than `[url]`; unset, `image_height_large` follows image_height so
--- one setting still scales both.
local function standalone_height(large)
  if not large then
    return config.options.image_height
  end
  return config.options.image_height_large or config.options.image_height * 2
end

--- Row cap for an image on a line that holds nothing but pictures, or nil to leave such
--- images in the text line at one row tall. A backend draws either inline virtual *text*
--- (one row, side by side) or virtual *lines* below (any height, stacked) — there is no
--- third mode, so such a line is either small and side by side, or readable and stacked.
local function gallery_rows()
  local opt = config.options.image_gallery
  if opt == false then
    return nil
  end
  return type(opt) == 'number' and opt or config.options.image_height
end

--- Cells available for text in the window showing bufnr, or a conservative
--- default when it isn't displayed.
local function text_width(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return 80
  end
  local info = vim.fn.getwininfo(win)[1]
  return math.max(1, vim.api.nvim_win_get_width(win) - ((info and info.textoff) or 0))
end

--- Return require('snacks').image if snacks is installed and the current
--- terminal can actually render images, else nil.
local function snacks_image()
  local ok, snacks = pcall(require, 'snacks')
  if not ok or not snacks or not snacks.image then
    return nil
  end
  local ok_supports, supported = pcall(snacks.image.supports_terminal)
  if not ok_supports or not supported then
    return nil
  end
  return snacks.image
end

-- Backend contract: place(bufnr, path, geom, opts) -> { close = fn } | nil.
-- `geom` carries the notation's position in both coordinate systems the two
-- backends disagree about: `row` (1-based), `byte_col`/`byte_end` (0-based byte
-- offsets into the line) and `screen_col` (display cells, which is what the
-- indent actually looks like once pads' virtual text is counted).
--
-- `indent_col`/`indent_screen_col` are the same two numbers for the line's indent, which
-- `align_indent` asks for instead: stacked pictures placed under their own notation would
-- step across the screen.

--- 3rd/image.nvim. Geometry x/y are 0-based, and an inline placement only
--- follows the buffer when bound to both a window and a buffer.
local function image_nvim_backend()
  local ok, img = pcall(require, 'image')
  if not ok or type(img) ~= 'table' or type(img.from_file) ~= 'function' then
    return nil
  end
  return {
    place = function(bufnr, path, geom, opts)
      local win = vim.fn.bufwinid(bufnr)
      if win == -1 then
        return nil
      end
      local ok_new, o = pcall(img.from_file, path, {
        window = win,
        buffer = bufnr,
        inline = true,
        with_virtual_padding = true,
        x = geom.align_indent and geom.indent_screen_col or geom.screen_col,
        y = geom.row - 1,
        height = opts and opts.height or nil,
        max_height = opts and opts.max_height or nil,
        max_width = opts and opts.max_width or nil,
      })
      if not ok_new or not o then
        return nil
      end
      pcall(o.render, o)
      return {
        close = function()
          pcall(o.clear, o)
        end,
      }
    end,
  }
end

local function snacks_backend()
  local image = snacks_image()
  if not image then
    return nil
  end
  return {
    place = function(bufnr, path, geom, opts)
      -- snacks slices the line with these numbers as well as using them as screen columns,
      -- so they have to be byte offsets. Without `range` it treats the rest of the
      -- notation as text sitting after the image, which costs the padded layout and adds
      -- an inline anchor glyph. range[2] drives both the overlay column and the virt_lines
      -- padding (snacks.image.placement), so it is also what lines a gallery up.
      local col = geom.align_indent and geom.indent_col or geom.byte_col
      local placement_opts = vim.tbl_extend('force', {
        pos = { geom.row, col },
        range = { geom.row, col, geom.row, geom.byte_end },
        inline = true,
      }, opts or {})
      local ok, p = pcall(image.placement.new, bufnr, path, placement_opts)
      if not ok or not p then
        return nil
      end
      return {
        close = function()
          pcall(p.close, p)
        end,
      }
    end,
  }
end

--- The active render backend per config.image_backend
--- ('auto' prefers image.nvim), or nil when none is usable.
local function backend()
  local pref = config.options.image_backend
  if pref == 'snacks' then
    return snacks_backend()
  end
  if pref == 'image_nvim' then
    return image_nvim_backend()
  end
  return image_nvim_backend() or snacks_backend()
end

local function images_enabled()
  local opt = config.options.images
  if opt == false then
    return false
  end
  return backend() ~= nil
end

--- The server's encodeTitleForUrl rule (space -> `_`, percent-encode
--- `% / ? #`), plus control characters, which it does not escape.
local function encode_path_segment(name)
  name = name:gsub(' ', '_')
  return (name:gsub('[%%/%?#%c]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

--- Icon endpoint URL for a `chatora/images` icon target's `iconUser`. A
--- leading `/` means a cross-project icon (`/project/title`, from
--- `[/project/name.icon]`); every path segment is encoded independently.
--- A Cosense user's picture is the icon of their own page, so this is also how a page's
--- author is drawn.
function M.icon_url(origin, project, icon_user)
  if icon_user:sub(1, 1) == '/' then
    local segments = {}
    for segment in icon_user:gmatch('[^/]+') do
      segments[#segments + 1] = encode_path_segment(segment)
    end
    return origin .. '/api/pages/' .. table.concat(segments, '/') .. '/icon'
  end
  return origin .. '/api/pages/' .. project .. '/' .. encode_path_segment(icon_user) .. '/icon'
end

local function clear_placements(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
  local list = placements_by_bufnr[bufnr]
  if not list then
    return
  end
  for _, p in ipairs(list) do
    p.close()
  end
  placements_by_bufnr[bufnr] = nil
end

--- Hide the notation behind a picture that is actually on screen. Applied per
--- placement rather than from `chatora/decorations`, because the server cannot know
--- whether this terminal drew anything: hiding a link that never became an image
--- would leave the line blank.
local function conceal_notation(bufnr, geom)
  if config.options.conceal == false then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, geom.row - 1, geom.byte_col, {
    end_col = geom.byte_end,
    conceal = '',
  })
end

--- Screen column of the notation starting at byte column `byte_col`. Backends
--- place by display cell, so the preceding text has to be *measured*, not
--- counted in bytes — anything multibyte before it would otherwise push the
--- image right. pads only decorates the indent, so its own additions shift
--- every later column by the same fixed amount.
local function screen_col(bufnr, line, byte_col)
  return vim.fn.strdisplaywidth(line:sub(1, byte_col))
    + require('chatora.pads').extra_cells(line, vim.bo[bufnr].tabstop)
end

--- Placement targets from a `chatora/images` reply. Skips a target whose line
--- went missing between request and reply, or whose column no longer lands on
--- a character boundary.
local function build_targets(bufnr, project, origin, border, images)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local targets = {}
  for _, img in ipairs(images) do
    local line = lines[img.line + 1]
    if line then
      local ok_start, byte_col = pcall(vim.str_byteindex, line, 'utf-16', img.startChar, false)
      local ok_end, byte_end = pcall(vim.str_byteindex, line, 'utf-16', img.endChar, false)
      if ok_start and ok_end then
        local indent = require('chatora.indent').text_at(line)
        local geom = {
          row = img.line + 1,
          byte_col = byte_col,
          byte_end = byte_end,
          screen_col = screen_col(bufnr, line, byte_col),
          indent_col = indent,
          indent_screen_col = screen_col(bufnr, line, indent),
        }

        if img.kind == 'icon' then
          -- An icon stands in for a face in running text, so it is one row — except in
          -- Cosense's large form on a line of its own, which is a picture to look at and
          -- is sized like one. Inline it stays one row whatever the form: a taller glyph
          -- has nowhere to go in a line of text.
          local rows = (img.large and img.standalone) and standalone_height(true) or 1
          targets[#targets + 1] = {
            url = M.icon_url(origin, project, img.iconUser),
            geom = geom,
            opts = rows > 1 and { max_height = rows } or { height = 1 },
            border = rows > 1 and border or nil,
            standalone = img.standalone,
          }
        elseif img.standalone or (img.gallery and gallery_rows() ~= nil) then
          -- Several pictures share the line, so they stack; aligning them to the line's
          -- indent keeps that stack a column rather than a staircase.
          geom.align_indent = not img.standalone
          targets[#targets + 1] = {
            url = img.src,
            geom = geom,
            -- Capped at the room left of the right edge, so a wide image
            -- scales down instead of being clipped.
            opts = {
              max_height = img.standalone and standalone_height(img.large) or gallery_rows(),
              max_width = math.max(1, text_width(bufnr) - geom.screen_col),
            },
            border = border,
            standalone = img.standalone,
          }
        else
          targets[#targets + 1] = {
            url = img.src,
            geom = geom,
            opts = { height = 1 },
            standalone = false,
          }
        end
      end
    end
  end
  return targets
end

--- Apply a `chatora/images` reply for `epoch`: build targets, skip the
--- teardown/re-place cycle when the target multiset hasn't actually changed
--- (placements are extmark-bound and follow ordinary edits on their own, so
--- redoing it would only flash), then kick off fetchAsset + placement.
local function apply_images(bufnr, project, origin, border, epoch, images)
  if epoch_by_bufnr[bufnr] ~= epoch or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local active = backend()
  if not active then
    return
  end

  local targets = build_targets(bufnr, project, origin, border, images)

  -- Rows are deliberately NOT part of the signature (they shift on every
  -- line inserted above). Standalone targets keep their column: their
  -- position only changes when the line itself is rewritten, which should
  -- re-place. Non-standalone targets (icons, inline images) drop their
  -- column: ordinary text edits elsewhere on the same line shift it
  -- constantly, and re-placing on every such edit would just flash.
  local counts = {}
  for _, target in ipairs(targets) do
    local key = target.url .. (target.standalone and ('\0' .. target.geom.screen_col) or '')
    counts[key] = (counts[key] or 0) + 1
  end
  local parts = {}
  for key, n in pairs(counts) do
    parts[#parts + 1] = key .. '\0' .. n
  end
  table.sort(parts)
  -- Width is part of the signature: placements bake in their scale, so a
  -- window resize has to re-place even when the target set is unchanged.
  local signature = table.concat(parts, '\1') .. '\2' .. text_width(bufnr)

  if signature_by_bufnr[bufnr] == signature and placements_by_bufnr[bufnr] then
    return
  end
  signature_by_bufnr[bufnr] = signature

  clear_placements(bufnr)

  local new_placements = {}
  placements_by_bufnr[bufnr] = new_placements

  local function place(path, geom, opts)
    if epoch_by_bufnr[bufnr] ~= epoch or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local p = active.place(bufnr, path, geom, opts)
    if p then
      new_placements[#new_placements + 1] = p
      conceal_notation(bufnr, geom)
    end
  end

  --- Resolve url to a local path (via the fetchAsset cache, or a fresh LSP
  --- request) and place it. Fetch failures are silent -- this is a
  --- cosmetic feature, matching the previous curl-based behavior.
  local function place_url(url, geom, opts, target_border)
    -- Bordered and plain variants of the same url are different files.
    local key = url .. (target_border and '\0border' or '')
    local cached_path = path_by_key[key]
    if cached_path then
      place(cached_path, geom, opts)
      return
    end
    lsp.request(
      'chatora/fetchAsset',
      { project = project, url = url, border = target_border },
      function(err, result)
        if err or not result or result.ok == false then
          report_once(result and result.message)
          return
        end
        path_by_key[key] = result.path
        place(result.path, geom, opts)
      end
    )
  end

  for _, target in ipairs(targets) do
    place_url(target.url, target.geom, target.opts, target.border)
  end
end

--- Draw one picture, one text row tall, at a 0-based (row, col) of `bufnr`.
---
--- For chrome that is not a page buffer, where none of the bookkeeping above applies:
--- there is no notation to conceal, no signature to compare and no epoch to invalidate,
--- because the caller owns the buffer and throws it away wholesale. The returned closer is
--- theirs to call; nil means nothing was drawn, which callers treat as cosmetic and ignore.
--- `on_placed` runs after the asset resolves, since that takes a round trip.
function M.place_one(bufnr, project, url, row, col, on_placed)
  local active = images_enabled() and backend() or nil
  if not active then
    return
  end
  local geom = { row = row + 1, byte_col = col, byte_end = col, screen_col = col }
  local function draw(path)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local placement = active.place(bufnr, path, geom, { height = 1 })
    if placement and on_placed then
      on_placed(placement)
    end
  end

  local cached = path_by_key[url]
  if cached then
    draw(cached)
    return
  end
  lsp.request('chatora/fetchAsset', { project = project, url = url }, function(err, result)
    if err or not result or result.ok == false then
      return
    end
    path_by_key[url] = result.path
    draw(result.path)
  end)
end

--- Forget that the current placements were applied, so the next refresh
--- re-places them. Needed whenever something outside this module destroys what
--- placements ride on — the buffer's extmarks, or the window they were bound
--- to — since the target set alone then still looks unchanged.
function M.invalidate(bufnr)
  signature_by_bufnr[bufnr] = nil
end

--- Clear and re-render every image placement in bufnr. Both the target scan
--- (`chatora/images`) and each target's local file path (`chatora/fetchAsset`)
--- are asynchronous, so this kicks off requests and returns immediately;
--- placements land as replies arrive.
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not images_enabled() then
    return
  end
  local project = project_by_bufnr[bufnr]
  if not project then
    return
  end

  local origin = config.options.origin
  local border = border_params()
  local uri = vim.api.nvim_buf_get_name(bufnr)

  -- Bumped so a reply for a refresh the buffer has since moved past (edited
  -- again, or detached, before the reply arrived) is dropped instead of
  -- acting on stale positions -- the next debounced refresh already
  -- supersedes it.
  local epoch = (epoch_by_bufnr[bufnr] or 0) + 1
  epoch_by_bufnr[bufnr] = epoch

  lsp.request('chatora/images', { uri = uri }, function(err, result)
    if err or not result or result.ok == false then
      return
    end
    apply_images(bufnr, project, origin, border, epoch, result.images or {})
  end)
end

local function schedule_refresh(bufnr)
  local timer = timers_by_bufnr[bufnr]
  if not timer then
    timer = uv.new_timer()
    timers_by_bufnr[bufnr] = timer
  end
  pcall(function()
    timer:stop()
    timer:start(
      DEBOUNCE_MS,
      0,
      vim.schedule_wrap(function()
        M.refresh(bufnr)
      end)
    )
  end)
end

local function cleanup_timer(bufnr)
  local timer = timers_by_bufnr[bufnr]
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    timers_by_bufnr[bufnr] = nil
  end
end

--- Attach to bufnr for project: render now, and keep re-rendering
--- (debounced) on every buffer change. No-op if images are disabled or
--- unusable. Safe to call more than once per buffer.
function M.attach(bufnr, project)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not images_enabled() then
    return
  end
  project_by_bufnr[bufnr] = project
  M.invalidate(bufnr)

  if vim.b[bufnr].chatora_images_attached then
    schedule_refresh(bufnr)
    return
  end
  vim.b[bufnr].chatora_images_attached = true

  local group = vim.api.nvim_create_augroup('ChatoraImages' .. bufnr, { clear = true })

  -- Backends bind a placement to the window it was created in, so showing the
  -- buffer in a different window leaves every image pointing at a stale one.
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = bufnr,
    callback = function()
      M.invalidate(bufnr)
      schedule_refresh(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = group,
    callback = function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        schedule_refresh(bufnr)
      end
    end,
  })

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      schedule_refresh(bufnr)
    end,
    on_detach = function()
      cleanup_timer(bufnr)
      vim.schedule(function()
        pcall(vim.api.nvim_buf_set_var, bufnr, 'chatora_images_attached', false)
        clear_placements(bufnr)
        project_by_bufnr[bufnr] = nil
        signature_by_bufnr[bufnr] = nil
        epoch_by_bufnr[bufnr] = nil
      end)
    end,
  })

  schedule_refresh(bufnr)
end

return M
