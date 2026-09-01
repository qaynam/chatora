-- Writing a page's new text into the buffer it is already in.
--
-- `nvim_buf_set_lines(0, -1, …)` is the obvious way and the wrong one: replacing every line
-- takes every extmark in the buffer with it, and those are what the images, the telomere,
-- the bullets and the concealed markup all hang from. A merge or a save normally differs
-- from what is on screen by a line or two, so only that run is written and everything
-- around it — decorations included — stays exactly where it was.
local M = {}

--- Make `bufnr` hold `lines`, writing only the run that differs. Returns true when
--- something was written.
function M.set(bufnr, lines)
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- An empty buffer is not a document to patch. Its single empty line would pair up with
  -- the trailing one the page text ends in, and the whole page would be written *above* it
  -- — leaving the cursor on the blank line the load pushed to the bottom.
  if #current == 1 and current[1] == '' then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return #lines > 1 or lines[1] ~= ''
  end
  local first = 1
  while first <= #current and first <= #lines and current[first] == lines[first] do
    first = first + 1
  end
  if first > #current and first > #lines then
    return false
  end
  -- How many lines at the end match, without letting the two ends meet in the middle: a
  -- line counted in the common prefix cannot also be part of the common suffix.
  local tail = 0
  local limit = math.min(#current, #lines) - first + 1
  while tail < limit and current[#current - tail] == lines[#lines - tail] do
    tail = tail + 1
  end

  local replacement = {}
  for i = first, #lines - tail do
    replacement[#replacement + 1] = lines[i]
  end
  vim.api.nvim_buf_set_lines(bufnr, first - 1, #current - tail, false, replacement)
  return true
end

return M
