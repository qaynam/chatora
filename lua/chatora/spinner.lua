-- The one animation clock chatora has. Neovim has no repaint loop, so anything that
-- spins is a libuv timer advancing a frame and asking for a redraw; sharing a single
-- timer keeps every spinner on screen in phase and means the timer exists only while
-- something is actually pending.
local M = {}

-- Braille: the whole cycle lives in one cell, so it fits the same slot a settled icon
-- takes in the statusline and the sidebar's mark column.
M.FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

local INTERVAL_MS = 90

local uv = vim.uv or vim.loop
local subscribers = {}
local timer, frame = nil, 1

--- The frame every spinner should be drawing right now.
function M.frame()
  return M.FRAMES[frame]
end

local function stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function tick()
  frame = (frame % #M.FRAMES) + 1
  local any = false
  for _, on_tick in pairs(subscribers) do
    any = true
    on_tick()
  end
  if not any then
    stop()
  end
end

--- Run `on_tick` on every frame until `name` is released. Re-subscribing under the same
--- name replaces the callback rather than adding a second one, so a caller can subscribe
--- from wherever it notices work started without tracking whether it already had.
function M.subscribe(name, on_tick)
  subscribers[name] = on_tick
  if timer then
    return
  end
  timer = uv.new_timer()
  timer:start(INTERVAL_MS, INTERVAL_MS, vim.schedule_wrap(tick))
end

function M.release(name)
  subscribers[name] = nil
  if next(subscribers) == nil then
    stop()
  end
end

return M
