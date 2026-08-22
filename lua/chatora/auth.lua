-- Cosense PAT auth flow: gates plugin actions behind an authenticated check,
-- prompting for and submitting a PAT via the LSP when not yet logged in.
local M = {}

local lsp = require('chatora.lsp')

--- Ensure the user is authenticated, prompting for a PAT if needed, then
--- calls cb() once authenticated.
function M.ensure_auth(cb)
  lsp.request_ok('chatora/authStatus', {}, function(status)
    if status.authenticated then
      cb()
      return
    end

    local pat = vim.fn.inputsecret('Cosense PAT: ')
    if not pat or pat == '' then
      vim.notify('[chatora] login cancelled', vim.log.levels.WARN)
      return
    end

    lsp.request_ok('chatora/login', { pat = pat }, function(result)
      if not result.authenticated then
        vim.notify('[chatora] login failed', vim.log.levels.ERROR)
        return
      end
      local user = result.user or {}
      local name = user.displayName or user.name or ''
      local greeting = name ~= '' and (', ' .. name) or ''
      vim.notify('[chatora] welcome' .. greeting .. '!', vim.log.levels.INFO)
      cb()
    end)
  end)
end

function M.logout()
  lsp.request_ok('chatora/logout', {}, function(_)
    vim.notify('[chatora] logged out', vim.log.levels.INFO)
  end)
end

return M
