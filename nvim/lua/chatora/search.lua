local M = {}

--- Open the incremental search picker for project; query (optional) pre-fills
--- the prompt (e.g. `:Chatora search foo`).
function M.run(project, query)
  require('chatora.picker').open(project, query)
end

return M
