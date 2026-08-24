-- Thin wrapper around vim.lsp for the chatora language server: lazily
-- starts/attaches the client, and unwraps its chatora/* request envelope.
local M = {}

local config = require('chatora.config')

local function err_message(err)
  if type(err) == 'table' then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

local function get_client()
  local clients = vim.lsp.get_clients({ name = 'chatora' })
  return clients[1]
end

--- Ensure the single chatora LSP client is running and attached to bufnr.
--- Returns the client, or nil (and notifies) on failure.
function M.ensure_start(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local client = get_client()
  if client then
    if not vim.lsp.buf_is_attached(bufnr, client.id) then
      vim.lsp.buf_attach_client(bufnr, client.id)
    end
    return client
  end

  local cmd = config.get_server_cmd()
  if not cmd then
    vim.notify(
      '[chatora] server command not found; run `bun run build` in packages/server or set opts.server_cmd',
      vim.log.levels.ERROR
    )
    return nil
  end

  local id = vim.lsp.start({
    name = 'chatora',
    cmd = cmd,
    root_dir = config.get_repo_root(),
    init_options = { origin = config.options.origin, notations = config.notation_list() },
  }, { bufnr = bufnr })

  if not id then
    vim.notify('[chatora] failed to start chatora LSP client', vim.log.levels.ERROR)
    return nil
  end

  return vim.lsp.get_client_by_id(id)
end

--- Send a chatora/* custom request against the (lazily started) client.
--- cb(err, result) is always invoked on the main loop.
function M.request(method, params, cb)
  local bufnr = vim.api.nvim_get_current_buf()
  local client = M.ensure_start(bufnr)
  if not client then
    cb('no chatora LSP client available', nil)
    return
  end

  local sent = client:request(method, params, function(err, result)
    vim.schedule(function()
      cb(err, result)
    end)
  end, bufnr)

  if not sent then
    vim.schedule(function()
      cb('failed to send request: ' .. method, nil)
    end)
  end
end

--- Like request(), but unwraps the {ok=true,...}/{ok=false,code,message}
--- envelope used by every chatora/* response: notifies on transport error
--- or ok=false, and only calls cb(result) on success.
function M.request_ok(method, params, cb)
  M.request(method, params, function(err, result)
    if err then
      vim.notify('[chatora] ' .. err_message(err), vim.log.levels.ERROR)
      return
    end
    if not result or result.ok == false then
      local message = (result and result.message) or ('request failed: ' .. method)
      vim.notify('[chatora] ' .. message, vim.log.levels.ERROR)
      return
    end
    cb(result)
  end)
end

return M
