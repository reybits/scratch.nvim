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
function M.data_dir()
    return vim.fn.stdpath("data") .. "/scratch.nvim"
end

return M
