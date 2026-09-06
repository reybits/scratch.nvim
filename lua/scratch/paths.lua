-------------------------------------------------------------------------------
-- scratch.nvim - Floating scratch notes and lightweight issue tracking.
--
-- Author: Andrey Ugolnik
-- License: MIT
-- GitHub: https://github.com/reybits/scratch.nvim
--
-- Where things live. A scope keeps its note and its issues in one directory,
-- so both paths come from scope_dir() and differ only by suffix. The project
-- root is cached and dropped when the working directory changes.
-------------------------------------------------------------------------------

local M = {}

--- Cached project root; dropped when the working directory changes
---@type string|nil
local cached_root = nil

--- Find the project root (git root or cwd)
---@return string
function M.root()
    if cached_root then
        return cached_root
    end
    local result = vim.fn.systemlist("git rev-parse --show-toplevel 2>/dev/null")
    if vim.v.shell_error == 0 and result[1] then
        cached_root = result[1]
    else
        cached_root = vim.fn.getcwd()
    end
    return cached_root
end

--- Drop the cached root so the next lookup resolves again
function M.reset()
    cached_root = nil
end

--- Directory holding the plugin's own data
---@return string
local function data_dir()
    return vim.fn.stdpath("data") .. "/scratch.nvim"
end

--- Name of the per-project directory; set from the config during setup
local local_dir = ".scratch"

---@param cfg scratch.Config
function M.setup(cfg)
    local_dir = cfg.local_dir
end

--- Directory holding everything of one scope: its note and its issues
---@param scope string: "local" or "global"
---@return string
function M.scope_dir(scope)
    if scope == "global" then
        return data_dir()
    end
    return M.root() .. "/" .. local_dir
end

return M
