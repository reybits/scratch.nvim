local issue = require("scratch.issue")

local M = {}

--- A closed issue is marked like a markdown checkbox rather than spelled out
local function cell_status(entry)
    return entry.status == "done" and "x" or " "
end

local function cell_type(entry)
    return entry.type:upper()
end

local function cell_priority(entry)
    return entry.priority:upper()
end

--- The date column shows whichever date the list is ordered by: the file name
--- starts with the creation date, and mtime carries the last change.
---@param entry scratch.Issue
---@param sort string
---@return string
local function cell_date(entry, sort)
    if sort == "updated" and entry.updated and entry.updated > 0 then
        return os.date("%Y-%m-%d", entry.updated)
    end
    return entry.id:sub(1, 10)
end

local function cell_title(entry)
    return entry.title
end

--- Columns are data, so changing what a cell looks like stays a one-liner.
--- A width of 0 means "take whatever is left".
--- `sorts` maps the orders a column stands for onto the name it takes while
--- that order is in effect. The active header is wrapped in angle brackets,
--- which name the keys that move the order; widths leave room for them.
local columns = {
    { header = " ", width = 2, format = cell_status },
    { header = "Type", width = 9, format = cell_type, sorts = { type = "Type" } },
    { header = "Priority", width = 11, format = cell_priority, sorts = { priority = "Priority" } },
    {
        header = "Created",
        width = 12,
        format = cell_date,
        sorts = { created = "Created", updated = "Updated" },
    },
    { header = "Description", width = 0, format = cell_title, sorts = { title = "Description" } },
}

--- Values a field cycles through, in order
local cycles = {
    type = { "bug", "feature", "task" },
    priority = { "low", "normal", "high", "critical" },
    status = { "open", "done" },
}

local priority_rank = { critical = 1, high = 2, normal = 3, low = 4 }
local type_rank = { bug = 1, feature = 2, task = 3 }

--- Order by a ranked field, newest first among equals
---@param field string
---@param ranks table<string, number>
---@return function
local function by_rank(field, ranks)
    return function(a, b)
        local left = ranks[a[field]] or math.huge
        local right = ranks[b[field]] or math.huge
        if left ~= right then
            return left < right
        end
        return a.id > b.id
    end
end

--- Sort orders, cycled with < and >. Every one falls back to the creation
--- date, because table.sort is not stable and equal rows would otherwise
--- swap places on each repaint.
local function by_created(a, b)
    return a.id > b.id
end

local function by_updated(a, b)
    if a.updated ~= b.updated then
        return a.updated > b.updated
    end
    return a.id > b.id
end

local function by_title(a, b)
    if a.title ~= b.title then
        return a.title < b.title
    end
    return a.id > b.id
end

--- In the order the columns appear, so < and > walk the header left to right
local sorters = {
    { name = "type", compare = by_rank("type", type_rank) },
    { name = "priority", compare = by_rank("priority", priority_rank) },
    { name = "created", compare = by_created },
    { name = "updated", compare = by_updated },
    { name = "title", compare = by_title },
}

--- Look a sorter up by name, falling back to the first one
---@param name string
---@return table
local function sorter(name)
    for _, entry in ipairs(sorters) do
        if entry.name == name then
            return entry
        end
    end
    return sorters[1]
end

local filters = {
    open = function(entry)
        return entry.status == "open"
    end,
}

--- How the store is presented. Sorting and filtering live here and never
--- touch the files.
---@class scratch.View
---@field sort string: name of a sorter
---@field filter string|nil
local view = {
    sort = "created",
    filter = "open",
}

local state = {
    bufnr = nil,
    scope = "local",
    line_map = {},
    cursors = {},
}

local namespace = vim.api.nvim_create_namespace("scratch.nvim/list")

--- Highlight group of the column header, so it does not read as another row.
--- Defined on every repaint because :colorscheme clears it, and marked default
--- so a user definition wins.
local header_group = "ScratchIssuesHeader"

local indent = "  "

--- Cut a line down to the window width.
--- strcharpart counts characters, which equals cells for the latin and
--- cyrillic titles this deals with.
---@param line string
---@param width number
---@return string
local function truncate(line, width)
    if width <= 0 or vim.fn.strdisplaywidth(line) <= width then
        return line
    end
    return vim.fn.strcharpart(line, 0, width)
end

--- Join pre-formatted cells into one padded line
---@param cells string[]
---@param width number
---@return string
local function format_row(cells, width)
    local parts = {}
    for i, column in ipairs(columns) do
        local cell = cells[i] or ""
        if column.width > 0 then
            parts[i] = cell .. string.rep(" ", math.max(1, column.width - #cell))
        else
            parts[i] = cell
        end
    end
    return truncate(indent .. table.concat(parts), width)
end

--- Pre-format one entry into cells, one per column
---@param entry scratch.Issue
---@param sort string
---@return string[]
local function row_cells(entry, sort)
    local cells = {}
    for i, column in ipairs(columns) do
        cells[i] = column.format(entry, sort)
    end
    return cells
end

--- Window showing the list, or -1 while it has none
---@return number
local function list_win()
    if state.bufnr == nil then
        return -1
    end
    return vim.fn.bufwinid(state.bufnr)
end

--- Width available to the list, or a sane default while it has no window
---@return number
local function window_width()
    local winnr = list_win()
    if winnr == -1 then
        return 80
    end
    return vim.api.nvim_win_get_width(winnr)
end

--- Lay entries out as text. Pure: the same entries and view give the same lines.
---@param entries scratch.Issue[]
---@param opts scratch.View
---@param width number
---@return string[] lines, table<number, scratch.Issue> line_map
function M.render(entries, opts, width)
    local keep = filters[opts.filter]
    local shown = {}
    for _, entry in ipairs(entries) do
        if keep == nil or keep(entry) then
            table.insert(shown, entry)
        end
    end
    table.sort(shown, sorter(opts.sort).compare)

    local headers = {}
    for i, column in ipairs(columns) do
        local active = column.sorts and column.sorts[opts.sort]
        headers[i] = active and ("<" .. active .. ">") or column.header
    end

    local lines = { format_row(headers, width) }
    local line_map = {}

    for _, entry in ipairs(shown) do
        table.insert(lines, format_row(row_cells(entry, opts.sort), width))
        line_map[#lines] = entry
    end

    if #shown == 0 then
        table.insert(lines, indent .. "No " .. opts.filter .. " issues")
    end

    return lines, line_map
end

--- Re-read the store and repaint the buffer
function M.refresh()
    local bufnr = state.bufnr
    if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local lines, line_map = M.render(issue.list(state.scope), view, window_width())
    state.line_map = line_map

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    vim.api.nvim_set_hl(0, header_group, { bold = true, default = true })
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, 0, {
        end_col = #lines[1],
        hl_group = header_group,
    })
end

--- Open the issue under the cursor as an ordinary file buffer, so writing,
--- undo and <C-o> back to the list all work as they do anywhere else
local function open_entry()
    local entry = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if entry == nil then
        return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
end

--- Re-read the file's buffer after the store changed it on disk. An edit of
--- the user's own outranks ours, so a modified buffer is left alone.
---@param path string
local function reload_buffer(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].modified then
        return
    end
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent edit")
    end)
end

--- Repaint a single row in place
---@param row number
---@param entry scratch.Issue
local function repaint_row(row, entry)
    local line = format_row(row_cells(entry, view.sort), window_width())
    vim.bo[state.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(state.bufnr, row - 1, row, false, { line })
    vim.bo[state.bufnr].modifiable = false
end

--- Move the field of the issue under the cursor to its next value
---@param field string
local function cycle_field(field)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local entry = state.line_map[row]
    if entry == nil then
        return
    end

    local values = cycles[field]
    local next_index = 1
    for i, value in ipairs(values) do
        if entry[field] == value then
            next_index = i % #values + 1
            break
        end
    end

    issue.set(entry.path, field, values[next_index])
    reload_buffer(entry.path)

    -- Repaint this row only. A full rebuild would drop a closed issue from
    -- under the cursor, and the next keypress would land on whatever slid
    -- into its place. The filter applies when the list is next built.
    entry[field] = values[next_index]
    repaint_row(row, entry)
end

--- Move to the next or previous sort order, keeping the cursor on the same
--- issue rather than the same row: the rows have just been reshuffled
---@param offset number: 1 for next, -1 for previous
local function cycle_sort(offset)
    local entry = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]

    local index = 1
    for i, candidate in ipairs(sorters) do
        if candidate.name == view.sort then
            index = i
            break
        end
    end
    view.sort = sorters[(index - 1 + offset) % #sorters + 1].name

    M.refresh()

    if entry then
        for row, shown in pairs(state.line_map) do
            if shown.path == entry.path then
                pcall(vim.api.nvim_win_set_cursor, list_win(), { row, 0 })
                break
            end
        end
    end

    require("scratch").update()
end

local function toggle_scope()
    M.remember_cursor()
    state.scope = state.scope == "local" and "global" or "local"
    M.refresh()
    M.restore_cursor()
    require("scratch").update()
end

--- The list buffer, created on first use and repainted whenever it is entered
---@return number bufnr
function M.buffer()
    if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
        return state.bufnr
    end

    local bufnr = vim.api.nvim_create_buf(false, true)

    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].filetype = "scratchissues"
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].modifiable = false

    vim.keymap.set("n", "<CR>", open_entry, { buffer = bufnr, noremap = true, silent = true })

    vim.keymap.set("n", "q", function()
        require("scratch").close()
    end, { buffer = bufnr, noremap = true, silent = true })

    -- Tab is the same keycode as C-i: mapping it would eat the jump forward
    vim.keymap.set("n", "<S-Tab>", toggle_scope, { buffer = bufnr, noremap = true, silent = true })

    for key, field in pairs({ T = "type", P = "priority", S = "status" }) do
        vim.keymap.set("n", key, function()
            cycle_field(field)
        end, { buffer = bufnr, noremap = true, silent = true })
    end

    for key, offset in pairs({ [">"] = 1, ["<"] = -1 }) do
        vim.keymap.set("n", key, function()
            cycle_sort(offset)
        end, { buffer = bufnr, noremap = true, silent = true })
    end

    -- Coming back from an issue must show what was just edited
    vim.api.nvim_create_autocmd("BufEnter", {
        group = vim.api.nvim_create_augroup("scratch.nvim-list", { clear = true }),
        buffer = bufnr,
        callback = function()
            M.refresh()
        end,
    })

    state.bufnr = bufnr
    return bufnr
end

--- Remember where the cursor stands, per scope: each scope is its own list
function M.remember_cursor()
    local winnr = list_win()
    if winnr ~= -1 then
        state.cursors[state.scope] = vim.api.nvim_win_get_cursor(winnr)
    end
end

--- Put the cursor back where this scope was left. With nothing remembered it
--- lands on the first issue rather than the header, which no key acts on.
function M.restore_cursor()
    local winnr = list_win()
    if winnr == -1 then
        return
    end

    local pos = state.cursors[state.scope] or { 2, 0 }
    local last = vim.api.nvim_buf_line_count(state.bufnr)
    pcall(vim.api.nvim_win_set_cursor, winnr, { math.min(pos[1], last), pos[2] })
end

--- Scope the list is currently showing
---@return string
function M.scope()
    return state.scope
end

--- Name of the sort order in effect
---@return string
function M.sort()
    return view.sort
end

--- Whether the buffer is the list itself
---@param bufnr number
---@return boolean
function M.is_buffer(bufnr)
    return state.bufnr ~= nil and bufnr == state.bufnr
end

return M
