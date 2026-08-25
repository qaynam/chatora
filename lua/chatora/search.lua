-- Search entry point, plus the result shaping both pickers need: chatora's own
-- (lua/chatora/picker.lua) and the telescope extension.
local M = {}

--- Open the incremental search picker for project; query (optional) pre-fills
--- the prompt (e.g. `:Chatora search foo`).
function M.run(project, query)
  require('chatora.picker').open(project, query)
end

--- One line of context for a search hit. `lines[1]` is the page title, which the
--- label already shows, so the interesting hit is whatever follows it.
function M.snippet(page)
  return (page.lines and (page.lines[2] or page.lines[1])) or ''
end

--- Terms to look for when previewing a hit. `/search/query` only reports `words`
--- on some backends, so the query itself stands in — the preview still needs
--- somewhere to jump.
function M.match_words(page, query)
  if page.words and #page.words > 0 then
    return page.words
  end
  return { query }
end

--- First line of `lines` containing any of `words`, as (lnum, from, to) with
--- 1-based lnum and a 0-based byte span. nil when nothing matches, which is the
--- caller's cue to leave the preview at the top.
function M.find_match(lines, words)
  for lnum, line in ipairs(lines) do
    local lowered = line:lower()
    for _, word in ipairs(words or {}) do
      if word ~= '' then
        local from, to = lowered:find(word:lower(), 1, true)
        if from then
          return lnum, from - 1, to
        end
      end
    end
  end
  return nil
end

return M
