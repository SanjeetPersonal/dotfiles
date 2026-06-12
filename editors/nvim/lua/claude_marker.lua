-- Claude "currently editing" marker for nvim-tree.
--
-- A Claude Code PostToolUse hook (ai/claude/hooks/claude-nvim-marker.mjs) writes
-- the path of the file it just edited to /tmp/claude-nvim/<encoded-cwd>.json. We
-- watch that directory and, when the file for THIS nvim's cwd changes, show a ✳
-- after that node in nvim-tree via a custom Decorator. The marker auto-clears
-- ~10s after the last edit.

local M = {}

local STATE_DIR = '/tmp/claude-nvim'
local IDLE_MS = 10000

--- Currently marked file (absolute path) or nil. Read by the Decorator.
M.active_file = nil

local idle_timer = nil
local fs_event = nil

-- Encode every non-alphanumeric byte as %XX. MUST stay byte-identical to the JS
-- encoder in claude-nvim-marker.mjs so both sides resolve the same filename.
local function encode(s)
  return (s:gsub('[^%w]', function(c) return string.format('%%%02X', c:byte()) end))
end

local function statefile()
  return STATE_DIR .. '/' .. encode(vim.fn.getcwd()) .. '.json'
end

local function reload_tree()
  local ok, api = pcall(require, 'nvim-tree.api')
  if ok then pcall(api.tree.reload) end
end

-- Stop tracking and redraw without the marker.
local function clear()
  if M.active_file == nil then return end
  M.active_file = nil
  reload_tree()
end

-- Read the state file for this cwd and update the marker. Runs on the main loop
-- (always invoked via vim.schedule from the fs_event callback).
local function refresh()
  local path = statefile()
  local fd = io.open(path, 'r')
  if not fd then return end
  local raw = fd:read('*a')
  fd:close()

  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= 'table' or not data.file then return end

  -- Stale entry: hook hasn't fired within the idle window, treat as cleared.
  local age = data.ts and (os.time() * 1000 - data.ts) or 0
  if age > IDLE_MS then
    clear()
    return
  end

  M.active_file = data.file
  reload_tree()

  -- (Re)arm the idle timer so the marker disappears after IDLE_MS of no edits.
  if idle_timer then idle_timer:stop() end
  idle_timer = vim.defer_fn(function() clear() end, IDLE_MS)
end

function M.setup()
  vim.fn.mkdir(STATE_DIR, 'p')

  -- Claude accent colour; `default` lets the colorscheme override it.
  vim.api.nvim_set_hl(0, 'NvimTreeClaudeMarker', { fg = '#D97757', default = true })

  fs_event = vim.uv.new_fs_event()
  if fs_event then
    fs_event:start(STATE_DIR, {}, function(err)
      if err then return end
      vim.schedule(refresh)
    end)
  end

  -- Pick up a marker written before nvim opened.
  vim.schedule(refresh)
end

-- Custom nvim-tree decorator: appends the Claude glyph after the active file.
local ok, nvt = pcall(require, 'nvim-tree.api')
if ok and nvt.Decorator then
  M.Decorator = nvt.Decorator:extend()

  function M.Decorator:new()
    self.enabled = true
    self.highlight_range = 'icon'
    self.icon_placement = 'after'
  end

  function M.Decorator:icons(node)
    if node.type == 'file' and M.active_file and node.absolute_path == M.active_file then
      return { { str = require('ui.icons').claude, hl = { 'NvimTreeClaudeMarker' } } }
    end
    return nil
  end
end

return M
