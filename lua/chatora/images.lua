-- Best-effort inline image rendering for Cosense icon notation and image
-- links, via folke/snacks.nvim's image module (Kitty graphics protocol).
-- A no-op whenever snacks isn't installed, config.images == false, or the
-- terminal can't render images -- every snacks call here is pcall-guarded.
--
-- API coded against (verified from github.com/folke/snacks.nvim, main
-- branch: lua/snacks/image/{init,placement,image,convert}.lua -- snacks is
-- not installed on this machine, so there is no local lazy-installed copy
-- to read):
--   Snacks.image.supports_terminal() -> boolean
--   Snacks.image.placement.new(bufnr, src, opts) -> Placement
--     opts.pos    = { row, col }  -- (1,0)-indexed
--     opts.inline = true          -- rendered as virtual text (extmarks
--                                  -- only; never edits buffer text, so
--                                  -- it's safe on our acwrite buffers)
--     opts.height = <cells>
--   placement:close()             -- removes its extmarks + augroup
-- `src` is always a *local* file path here, never a remote URL: every
-- target is resolved through the `chatora/fetchAsset` LSP request first
-- (see lua/chatora/lsp.lua), which the server fetches with session
-- credential headers when (and only when) the URL is same-origin, so
-- private-project icons work instead of 404ing the way a bare unauthenticated
-- `curl` would. See docs/ARCHITECTURE.md's chatora/* request list and
-- packages/server/src/assets.ts.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

local DEBOUNCE_MS = 150
local uv = vim.uv or vim.loop
local timers_by_bufnr = {}
local placements_by_bufnr = {} -- values are lists of snacks placement objects
local project_by_bufnr = {}
local epoch_by_bufnr = {} -- bumped on every refresh(); guards stale async fetchAsset replies
local path_by_url = {} -- url -> local file path, resolved once via fetchAsset and reused

local IMAGE_EXTENSIONS = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

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

local function images_enabled()
  local opt = config.options.images
  if opt == false then
    return false
  end
  return snacks_image() ~= nil
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
    pcall(function()
      p:close()
    end)
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
  local image = snacks_image()
  if not image then
    return
  end
  local project = project_by_bufnr[bufnr]
  if not project then
    return
  end

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
    local placement_opts = vim.tbl_extend('force', { pos = { row, col }, inline = true }, opts or {})
    local ok, p = pcall(image.placement.new, bufnr, path, placement_opts)
    if ok and p then
      new_placements[#new_placements + 1] = p
    end
  end

  --- Resolve url to a local path (via the fetchAsset cache, or a fresh LSP
  --- request) and place it. Fetch failures are silent -- this is a
  --- cosmetic feature, matching the previous curl-based behavior.
  local function place_url(url, row, col, opts)
    local cached_path = path_by_url[url]
    if cached_path then
      place(cached_path, row, col, opts)
      return
    end
    lsp.request('chatora/fetchAsset', { project = project, url = url }, function(err, result)
      if err or not result or result.ok == false then
        return
      end
      path_by_url[url] = result.path
      place(result.path, row, col, opts)
    end)
  end

  local origin = config.options.origin
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    for _, target in ipairs(icon_targets(line)) do
      local url = origin .. '/api/pages/' .. project .. '/' .. encode_path_segment(target.name) .. '/icon'
      place_url(url, i, target.col, { height = 1 })
    end

    local standalone_src = standalone_image_src(line)
    if standalone_src then
      place_url(standalone_src, i, 0, { max_height = 20 })
    end
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

  if vim.b[bufnr].chatora_images_attached then
    schedule_refresh(bufnr)
    return
  end
  vim.b[bufnr].chatora_images_attached = true

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
        epoch_by_bufnr[bufnr] = nil
      end)
    end,
  })

  schedule_refresh(bufnr)
end

return M
