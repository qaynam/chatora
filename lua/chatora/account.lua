-- Multi-account switching: list/add/switch/remove chatora accounts (one
-- Cosense PAT each) via the LSP's chatora/*Account* requests, presented
-- through vim.ui.select / vim.fn.inputsecret.
local M = {}

local lsp = require('chatora.lsp')

local ADD_SENTINEL = { id = '__chatora_add_account__' }

local function host_of(origin)
  return (origin or ''):match('^%a+://([^/]+)') or origin or ''
end

--- How an account is named to the user: display name plus the host it belongs to.
function M.label(account)
  local name = account.displayName
  if not name or name == '' then
    name = account.name or ''
  end
  return name .. ' (' .. host_of(account.origin) .. ')'
end

local account_label = M.label

--- cb({ active = <id or nil>, accounts = { Account, ... } })
function M.list(cb)
  lsp.request_ok('chatora/accounts', {}, function(result)
    cb({ active = result.active, accounts = result.accounts or {} })
  end)
end

--- Prompt for a PAT, verify + register it as a new account, and make it
--- active. Calls cb(account) on success.
function M.add(cb)
  local pat = vim.fn.inputsecret('Cosense PAT: ')
  if not pat or pat == '' then
    vim.notify('[chatora] アカウント追加をキャンセルしました', vim.log.levels.WARN)
    return
  end

  lsp.request_ok('chatora/addAccount', { pat = pat }, function(result)
    vim.notify(
      '[chatora] アカウントを追加しました: ' .. account_label(result.account),
      vim.log.levels.INFO
    )
    if cb then
      cb(result.account)
    end
  end)
end

--- Pick an account to remove via vim.ui.select and remove it.
--- Calls cb({ active = <id or nil>, accounts = { Account, ... } }) on success.
function M.remove(cb)
  M.list(function(state)
    if #state.accounts == 0 then
      vim.notify('[chatora] 削除できるアカウントがありません', vim.log.levels.WARN)
      return
    end

    vim.ui.select(state.accounts, {
      prompt = 'chatora アカウントを削除',
      format_item = account_label,
    }, function(choice)
      if not choice then
        return
      end
      lsp.request_ok('chatora/removeAccount', { id = choice.id }, function(result)
        vim.notify(
          '[chatora] アカウントを削除しました: ' .. account_label(choice),
          vim.log.levels.INFO
        )
        if cb then
          cb({ active = result.active, accounts = result.accounts })
        end
      end)
    end)
  end)
end

--- Pick an account to switch to via vim.ui.select, with a trailing
--- '+ 新しいアカウントを追加…' entry that delegates to M.add. Calls cb(account)
--- on success; the caller is responsible for reloading anything account-scoped
--- (sidebar, open pages, ...).
function M.switch(cb)
  M.list(function(state)
    local items = {}
    for _, account in ipairs(state.accounts) do
      items[#items + 1] = account
    end
    items[#items + 1] = ADD_SENTINEL

    vim.ui.select(items, {
      prompt = 'chatora アカウントを切り替え',
      format_item = function(item)
        if item == ADD_SENTINEL then
          return '+ 新しいアカウントを追加…'
        end
        return account_label(item)
      end,
    }, function(choice)
      if not choice then
        return
      end
      if choice == ADD_SENTINEL then
        M.add(cb)
        return
      end

      lsp.request_ok('chatora/useAccount', { id = choice.id }, function(result)
        vim.notify(
          '[chatora] アカウントを切り替えました: ' .. account_label(result.account),
          vim.log.levels.INFO
        )
        if cb then
          cb(result.account)
        end
      end)
    end)
  end)
end

return M
