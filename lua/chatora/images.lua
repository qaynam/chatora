-- Best-effort inline image rendering for Cosense icon notation and image
-- links. Two interchangeable render backends (Kitty graphics protocol
-- terminals): 3rd/image.nvim (preferred when installed) and
-- folke/snacks.nvim's image module. A no-op whenever no backend is usable
-- or config.images == false -- every backend call is pcall-guarded.
--
-- The rendered src is always a *local* file path, never a remote URL: every
-- target is resolved through the `chatora/fetchAsset` LSP request first,
-- which the server fetches with session credential headers when (and only
-- when) the URL is same-origin, so private-project icons work instead of
-- 404ing the way an unauthenticated curl would. See docs/ARCHITECTURE.md's
-- chatora/* request list and packages/server/src/assets.ts.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

local DEBOUNCE_MS = 300
local uv = vim.uv or vim.loop
local timers_by_bufnr = {}
local placements_by_bufnr = {} -- values are lists of { close = fn } wrappers
local project_by_bufnr = {}
local epoch_by_bufnr = {} -- bumped on every refresh(); guards stale async fetchAsset replies
local path_by_key = {} -- fetch key -> local file path, resolved once via fetchAsset and reused
local signature_by_bufnr = {} -- target multiset of the last applied refresh (flicker guard)

--- Border params for chatora/fetchAsset, or nil. The frame is composited into
--- the image file itself server-side (ImageMagick) — the only way to hug the
--- image's actual pixel edges; cell-grid extmarks can't. Standalone images
--- only: icons are 1 cell tall.
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

local IMAGE_EXTENSIONS = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

--- Cells available for text in the window showing bufnr (window width minus
--- the number/sign/fold gutter), or a conservative default when it isn't
--- displayed. Bounds how wide an inline image may render.
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

-- Backend contract: place(bufnr, path, row, col, opts) -> { close = fn } | nil
-- with row 1-based, col 0-based (byte), opts.height / opts.max_height in cells.

--- 3rd/image.nvim: from_file API verified against its README/init.lua —
--- geometry x/y are 0-based, window+buffer binding required for inline
--- extmark-following placements, img:render()/img:clear().
local function image_nvim_backend()
  local ok, img = pcall(require, 'image')
  if not ok or type(img) ~= 'table' or type(img.from_file) ~= 'function' then
    return nil
  end
  return {
    place = function(bufnr, path, row, col, opts)
      local win = vim.fn.bufwinid(bufnr)
      if win == -1 then
        return nil
      end
      local ok_new, o = pcall(img.from_file, path, {
        window = win,
        buffer = bufnr,
        inline = true,
        with_virtual_padding = true,
        x = col,
        y = row - 1,
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
    place = function(bufnr, path, row, col, opts)
      local placement_opts =
        vim.tbl_extend('force', { pos = { row, col }, inline = true }, opts or {})
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

--- Percent-encode a page title for an HTTP path segment: same rule as the
--- server's encodeTitleForUrl (space -> `_`, percent-encode `% / ? #`), plus
--- control characters defensively since this becomes a URL path
--- (encodeTitleForUrl itself does not escape them). Unicode left raw.
--- See docs/ARCHITECTURE.md.
local function encode_path_segment(name)
  name = name:gsub(' ', '_')
  return (name:gsub('[%%/%?#%c]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

-- [name.icon] or [name.icon*3] (the repeat count is a Cosense display hint
-- only; the icon src doesn't change, so it's parsed but ignored).
local ICON_PATTERN = '%[([^%[%]]-)%.icon%*?%d*%]'

--- Every icon notation occurrence on a line: { col (0-based byte), name }.
local function icon_targets(line)
  local out = {}
  local from = 1
  while true do
    local s, e, name = line:find(ICON_PATTERN, from)
    if not s then
      break
    end
    if name ~= '' then
      out[#out + 1] = { col = s - 1, name = name }
    end
    from = e + 1
  end
  return out
end

local function has_image_extension(url)
  local ext = url:match('%.(%a+)$')
  return ext ~= nil and IMAGE_EXTENSIONS[ext:lower()] == true
end

--- Resolve a standalone image line (the whole trimmed line matches) to a
--- src url, or nil.
local function standalone_image_src(line)
  local trimmed = vim.trim(line)

  local double_bracket_url = trimmed:match('^%[%[(https?://[^%[%]%s]+)%]%]$')
  if double_bracket_url then
    return double_bracket_url
  end

  local single_bracket_url = trimmed:match('^%[(https?://[^%[%]%s]+)%]$')
  if not single_bracket_url then
    return nil
  end

  local gyazo_hash = single_bracket_url:match('^https?://[%w.]*gyazo%.com/(%x+)/?$')
  if gyazo_hash then
    return 'https://i.gyazo.com/' .. gyazo_hash .. '.png'
  end

  if has_image_extension(single_bracket_url) then
    return single_bracket_url
  end

  return nil
end

local function clear_placements(bufnr)
  local list = placements_by_bufnr[bufnr]
  if not list then
    return
  end
  for _, p in ipairs(list) do
    p.close()
  end
  placements_by_bufnr[bufnr] = nil
end

--- Clear and re-render every image placement in bufnr. Placement itself is
--- asynchronous (each target's local file path comes back from a
--- `chatora/fetchAsset` request), so this kicks off requests and returns
--- immediately; placements land as replies arrive.
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local active = backend()
  if not active then
    return
  end
  local project = project_by_bufnr[bufnr]
  if not project then
    return
  end

  -- Collect targets first and compare against the last applied set:
  -- placements are extmark-bound and follow ordinary edits by themselves, so
  -- when the target multiset is unchanged, tearing everything down and
  -- re-placing it would only make the images flash. Rows are deliberately
  -- NOT part of the signature (they shift on every line inserted above).
  local origin = config.options.origin
  local border = border_params()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local targets = {}
  local counts = {}
  for i, line in ipairs(lines) do
    for _, target in ipairs(icon_targets(line)) do
      local url = origin
        .. '/api/pages/'
        .. project
        .. '/'
        .. encode_path_segment(target.name)
        .. '/icon'
      targets[#targets + 1] = { url = url, row = i, col = target.col, opts = { height = 1 } }
      counts[url] = (counts[url] or 0) + 1
    end
    local standalone_src = standalone_image_src(line)
    if standalone_src then
      -- The image sits where the text sits: at the line's indent, shifted by
      -- however many cells the pads' inline spacing added before it.
      local indent = #(line:match('^[ \t]*'))
      local col = indent + require('chatora.pads').extra_cells(indent)
      targets[#targets + 1] = {
        url = standalone_src,
        row = i,
        col = col,
        -- Capped at the room left of the right edge, so a wide image scales
        -- down instead of being clipped.
        opts = { max_height = 20, max_width = math.max(1, text_width(bufnr) - col) },
        border = border,
      }
      -- Placements pin their x at creation, so a changed indent must defeat
      -- the flicker guard and re-place (icons stay col-free: mid-line text
      -- edits shift their col constantly and re-placing would flash).
      local key = standalone_src .. '\0' .. col
      counts[key] = (counts[key] or 0) + 1
    end
  end

  local parts = {}
  for url, n in pairs(counts) do
    parts[#parts + 1] = url .. '\0' .. n
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

  -- Bumped so a fetchAsset reply for a target this refresh no longer has
  -- (buffer edited again, or detached, before the reply arrived) is
  -- dropped instead of placing an extmark against a stale position --
  -- the next debounced refresh already supersedes it.
  local epoch = (epoch_by_bufnr[bufnr] or 0) + 1
  epoch_by_bufnr[bufnr] = epoch

  local new_placements = {}
  placements_by_bufnr[bufnr] = new_placements

  local function place(path, row, col, opts)
    if epoch_by_bufnr[bufnr] ~= epoch or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local p = active.place(bufnr, path, row, col, opts)
    if p then
      new_placements[#new_placements + 1] = p
    end
  end

  --- Resolve url to a local path (via the fetchAsset cache, or a fresh LSP
  --- request) and place it. Fetch failures are silent -- this is a
  --- cosmetic feature, matching the previous curl-based behavior.
  local function place_url(url, row, col, opts, target_border)
    -- Bordered and plain variants of the same url are different files.
    local key = url .. (target_border and '\0border' or '')
    local cached_path = path_by_key[key]
    if cached_path then
      place(cached_path, row, col, opts)
      return
    end
    lsp.request(
      'chatora/fetchAsset',
      { project = project, url = url, border = target_border },
      function(err, result)
        if err or not result or result.ok == false then
          return
        end
        path_by_key[key] = result.path
        place(result.path, row, col, opts)
      end
    )
  end

  for _, target in ipairs(targets) do
    place_url(target.url, target.row, target.col, target.opts, target.border)
  end
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
  -- An explicit attach follows a full buffer (re)load, which invalidates the
  -- extmarks existing placements ride on — force the next refresh to re-place.
  signature_by_bufnr[bufnr] = nil

  if vim.b[bufnr].chatora_images_attached then
    schedule_refresh(bufnr)
    return
  end
  vim.b[bufnr].chatora_images_attached = true

  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = vim.api.nvim_create_augroup('ChatoraImages' .. bufnr, { clear = true }),
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
