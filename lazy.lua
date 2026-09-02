-- lazy.nvim reads this file from the plugin's own directory and merges it into whatever spec
-- the reader wrote. The one part of that spec which is not a matter of taste lives here: the
-- LSP server is not in the repository, so something has to put it there. Merged as optional,
-- so it never installs chatora on its own.
return {
  'qaynam/chatora',
  build = 'sh scripts/install-server.sh',
}
