-------------------------------------------------------------------------------
-- scratch.nvim - Floating scratch notes and lightweight issue tracking.
--
-- Author: Andrey Ugolnik
-- License: MIT
-- GitHub: https://github.com/reybits/scratch.nvim
--
-- What the plugin knows about its own buffers, and the only place that knows
-- it. A buffer is registered when it is created or opened, and from then on
-- the buffer answers every question about itself: which kind it is, which
-- note type or issue scope it belongs to, where it is stored.
--
-- This is deliberate. Deriving those answers from anything else - a "current
-- type" field, the working directory - means two sources of truth that drift
-- apart as soon as the user moves between buffers or projects.
-------------------------------------------------------------------------------

local M = {}

--- Three shapes rather than one with everything optional: a list always has
--- a scope and a directory, an issue always has a file, and saying so is what
--- lets `info.kind == "list"` be enough to reach `info.scope`.

---@class scratch.NoteInfo
---@field kind "note"
---@field type string
---@field path string|nil: nil for the temporary note, which has no file

---@class scratch.ListInfo
---@field kind "list"
---@field scope string
---@field dir string

---@class scratch.IssueInfo
---@field kind "issue"
---@field path string

---@alias scratch.BufferInfo scratch.NoteInfo|scratch.ListInfo|scratch.IssueInfo

---@type table<number, scratch.BufferInfo>
local entries = {}

--- Record what a buffer is
---@param bufnr number
---@param info scratch.BufferInfo
function M.set(bufnr, info)
    entries[bufnr] = info
end

--- What the buffer is, or nil when it is none of ours. A buffer that has been
--- wiped stops being ours, and its entry goes with it.
---@param bufnr number
---@return scratch.BufferInfo|nil
function M.get(bufnr)
    local info = entries[bufnr]
    if info == nil then
        return nil
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
        entries[bufnr] = nil
        return nil
    end
    return info
end

--- Forget a buffer
---@param bufnr number
function M.forget(bufnr)
    entries[bufnr] = nil
end

--- Call fn(bufnr, info) for every live buffer of a kind
---@param kind string
---@param fn function
function M.each(kind, fn)
    for bufnr, info in pairs(entries) do
        if info.kind == kind then
            if vim.api.nvim_buf_is_valid(bufnr) then
                fn(bufnr, info)
            else
                entries[bufnr] = nil
            end
        end
    end
end

return M
