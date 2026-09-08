-------------------------------------------------------------------------------
-- scratch.nvim - Floating scratch notes and lightweight issue tracking.
--
-- Author: Andrey Ugolnik
-- License: MIT
-- GitHub: https://github.com/reybits/scratch.nvim
--
-- The issue list. render() is pure: sorting, filtering and columns are data
-- in the view, so the presentation changes without touching a single file.
-- Every sort order falls back to the creation date, because table.sort is not
-- stable and tied rows would otherwise swap places on each repaint.
--
-- Knows nothing about files: entries come from the store.
-------------------------------------------------------------------------------

local buffers = require("scratch.buffers")
local issue = require("scratch.issue")
local window = require("scratch.window")

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

--- One colour axis, and it is priority: type is already legible as a word,
--- while HIGH and LOW read the same until they differ in colour. Everything
--- unimportant is dimmed instead of coloured, so the eye has one thing to
--- follow rather than two competing ones.
local priority_group = {
    critical = "ScratchIssueCritical",
    high = "ScratchIssueHigh",
    low = "ScratchIssueLow",
}

--- Groups the list defines, linked to whatever the colourscheme provides.
--- Marked default, so a user definition wins, and redefined on every repaint
--- because :colorscheme clears them.
local highlight_links = {
    ScratchIssueCritical = "DiagnosticError",
    ScratchIssueHigh = "DiagnosticWarn",
    ScratchIssueLow = "Comment",
    ScratchIssueDate = "Comment",
    ScratchIssueDone = "Comment",
}

---@param entry scratch.Issue
---@return string|nil
local function hl_priority(entry)
    return priority_group[entry.priority]
end

---@return string
local function hl_date()
    return "ScratchIssueDate"
end

--- Columns are data, so changing what a cell looks like stays a one-liner.
--- A width of 0 means "take whatever is left".
--- `sorts` maps the orders a column stands for onto the name it takes while
--- that order is in effect. The active header is wrapped in angle brackets,
--- which name the keys that move the order; widths leave room for them.
local columns = {
    { header = " ", width = 2, format = cell_status },
    { header = "Type", width = 9, format = cell_type, sorts = { type = "Type" } },
    {
        header = "Priority",
        width = 11,
        format = cell_priority,
        hl = hl_priority,
        sorts = { priority = "Priority" },
    },
    {
        header = "Created",
        width = 12,
        format = cell_date,
        hl = hl_date,
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
    --- Which list to open with. A memory of the last one seen, the way init
    --- keeps the last note type - never the answer to "which list is this".
    scope = "local",

    --- One record per issue directory, because that is what a list shows: the
    --- local list of another project is another list, with rows and a cursor
    --- of its own, and a single buffer could not hold two of them.
    ---@type table<string, { bufnr: number, line_map: table }>
    lists = {},
}

--- The record behind a buffer, or nil when the buffer is not a list of ours
---@param bufnr number
---@return table|nil
local function record(bufnr)
    local info = buffers.get(bufnr)
    if info == nil or info.kind ~= "list" then
        return nil
    end
    return state.lists[info.dir]
end

local namespace = vim.api.nvim_create_namespace("scratch.nvim/list")

--- Cleared once, when the module loads: clearing it per buffer would take the
--- autocommands of every list created before this one with it.
local augroup = vim.api.nvim_create_augroup("scratch.nvim-list", { clear = true })

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

--- Join pre-formatted cells into one padded line, and report where each cell
--- landed so it can be highlighted without measuring the line again.
---@param cells string[]
---@param width number
---@return string line, table[] spans: byte range of each cell
local function format_row(cells, width)
    local parts = {}
    local spans = {}
    local at = #indent

    for i, column in ipairs(columns) do
        local cell = cells[i] or ""
        spans[i] = { from = at, to = at + #cell }

        if column.width > 0 then
            parts[i] = cell .. string.rep(" ", math.max(1, column.width - #cell))
        else
            parts[i] = cell
        end
        at = at + #parts[i]
    end

    return truncate(indent .. table.concat(parts), width), spans
end

--- Highlights of one row. A closed issue is dimmed as a whole instead of
--- carrying per-column colour: it is done, and nothing in it is urgent.
---@param entry scratch.Issue
---@param spans table[]
---@param line string
---@param row number: zero-based
---@return table[]
local function row_marks(entry, spans, line, row)
    if entry.status == "done" then
        return { { row = row, from = 0, to = #line, group = "ScratchIssueDone" } }
    end

    local marks = {}
    for i, column in ipairs(columns) do
        local group = column.hl and column.hl(entry)
        -- a narrow window can cut a cell off entirely
        if group and spans[i].from < #line then
            table.insert(marks, {
                row = row,
                from = spans[i].from,
                to = math.min(spans[i].to, #line),
                group = group,
            })
        end
    end
    return marks
end

--- Paint a set of marks into the buffer
---@param bufnr number
---@param marks table[]
local function apply_marks(bufnr, marks)
    for _, mark in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(bufnr, namespace, mark.row, mark.from, {
            end_col = mark.to,
            hl_group = mark.group,
        })
    end
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

--- Window showing a list buffer, or -1 while it has none
---@param bufnr number
---@return number
local function list_win(bufnr)
    return vim.fn.bufwinid(bufnr)
end

--- Width available to a list, or a sane default while it has no window
---@param bufnr number
---@return number
local function window_width(bufnr)
    local winnr = list_win(bufnr)
    if winnr == -1 then
        return 80
    end
    return vim.api.nvim_win_get_width(winnr)
end

--- Lay entries out as text. Pure: the same entries and view give the same lines.
---@param entries scratch.Issue[]
---@param opts scratch.View
---@param width number
---@return string[] lines, table<number, scratch.Issue> line_map, table[] marks
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

    -- one value on purpose: format_row also returns spans, and a table
    -- constructor would swallow them as a second line
    local header_line = format_row(headers, width)
    local lines = { header_line }
    local line_map = {}
    local marks = {}

    for _, entry in ipairs(shown) do
        local line, spans = format_row(row_cells(entry, opts.sort), width)
        table.insert(lines, line)
        line_map[#lines] = entry
        vim.list_extend(marks, row_marks(entry, spans, line, #lines - 1))
    end

    if #shown == 0 then
        -- "No open issues" while a filter is on, plain "No issues" without
        -- one: a view with no filter shows everything, and there is nothing
        -- to name in that case
        local what = opts.filter and (opts.filter .. " issues") or "issues"
        table.insert(lines, indent .. "No " .. what)
    end

    return lines, line_map, marks
end

--- Put lines into the buffer, touching only the range that differs.
---
--- Replacing every line would be simpler and is wrong: a mark cannot survive
--- the deletion of the line it sits on, and the jumplist is made of marks. A
--- list repainted on every entry would drop the entry that C-o goes back to,
--- so the second jump into it would land on the first row.
---@param bufnr number
---@param lines string[]
local function set_lines(bufnr, lines)
    local shown = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    local first = 1
    while first <= #shown and first <= #lines and shown[first] == lines[first] do
        first = first + 1
    end

    local last_shown, last_new = #shown, #lines
    while last_shown >= first and last_new >= first and shown[last_shown] == lines[last_new] do
        last_shown = last_shown - 1
        last_new = last_new - 1
    end

    if first > last_shown and first > last_new then
        return
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(
        bufnr,
        first - 1,
        last_shown,
        false,
        vim.list_slice(lines, first, last_new)
    )
    vim.bo[bufnr].modifiable = false
end

--- Re-read the store and repaint the buffer, leaving the cursor on the issue
--- it stood on. A repaint may reorder the rows or drop one, so the row number
--- the cursor held says nothing: what it belongs to is the issue.
---@param bufnr number
function M.refresh(bufnr)
    local shown = record(bufnr)
    if shown == nil or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    -- Rows are cut to the width of the window they are shown in, so off
    -- screen there is nothing to render against. Guessing a width produces
    -- rows that differ from the real ones, and replacing them would take the
    -- position of the buffer with them. Entering it repaints it anyway.
    local winnr = list_win(bufnr)
    if winnr == -1 then
        return
    end

    local pos = vim.api.nvim_win_get_cursor(winnr)
    local standing = shown.line_map[pos[1]]

    local scope = buffers.get(bufnr).scope
    local lines, line_map, marks = M.render(issue.list(scope), view, window_width(bufnr))
    shown.line_map = line_map

    set_lines(bufnr, lines)

    -- :colorscheme clears them, so they are declared on every repaint
    vim.api.nvim_set_hl(0, header_group, { bold = true, default = true })
    for group, link in pairs(highlight_links) do
        vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end

    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, 0, {
        end_col = #lines[1],
        hl_group = header_group,
    })
    apply_marks(bufnr, marks)

    local row = pos[1]
    if standing then
        for at, shown in pairs(line_map) do
            if shown.path == standing.path then
                row = at
                break
            end
        end
    end
    pcall(vim.api.nvim_win_set_cursor, winnr, { math.min(row, #lines), pos[2] })
end

--- Show an issue as an ordinary file buffer, so writing, undo and C-o back
--- to the list work as they do anywhere else.
---
--- Deliberately not :edit. That command reuses the current buffer when it is
--- empty and unmodified - exactly what a note looks like once its entries
--- have been moved out - and the note buffer would silently turn into the
--- file while still being registered as a note.
---@param path string
function M.open(path)
    if not window.is_open() then
        -- open on the list, so C-o from the issue lands there
        window.open(M.buffer())
    end

    local bufnr = vim.fn.bufadd(path)
    buffers.set(bufnr, { kind = "issue", path = path })
    window.swap_to(bufnr)
end

--- Open the issue under the cursor
local function open_entry()
    local shown = record(vim.api.nvim_get_current_buf())
    local entry = shown and shown.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if entry == nil then
        return
    end
    M.open(entry.path)
end

--- Re-read the file's buffer after the store changed it on disk.
---
--- An issue shown in the scratch window is written the moment it stops being
--- visible, so by the time the list is reachable its buffer is clean. A copy
--- open elsewhere is not covered by that rule and may still hold changes;
--- re-reading it would fail, so it is left alone.
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
---@param bufnr number
---@param row number
---@param entry scratch.Issue
local function repaint_row(bufnr, row, entry)
    local line, spans = format_row(row_cells(entry, view.sort), window_width(bufnr))

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { line })
    vim.bo[bufnr].modifiable = false

    -- the row may have just become a closed one, so its old marks go too
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, row - 1, row)
    apply_marks(bufnr, row_marks(entry, spans, line, row - 1))
end

--- Move the field of the issue under the cursor to its next value
---@param field string
local function cycle_field(field)
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local shown = record(bufnr)
    local entry = shown and shown.line_map[row]
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
    repaint_row(bufnr, row, entry)
end

--- Move to the next or previous sort order. The repaint carries the cursor
--- through the reshuffling on its own.
---@param offset number: 1 for next, -1 for previous
local function cycle_sort(offset)
    local index = 1
    for i, candidate in ipairs(sorters) do
        if candidate.name == view.sort then
            index = i
            break
        end
    end
    view.sort = sorters[(index - 1 + offset) % #sorters + 1].name

    M.refresh(vim.api.nvim_get_current_buf())
    window.update()
end

--- Switch between the local and the global list. Each is a buffer of its own,
--- so showing one is an ordinary swap and the window does the rest.
local function toggle_scope()
    state.scope = state.scope == "local" and "global" or "local"
    window.swap_to(M.buffer())
end

--- The buffer of the list to show, created on first use, always ready to go
---@return number bufnr
function M.buffer()
    local scope = state.scope
    local dir = issue.dir(scope)
    local shown = state.lists[dir]

    if shown == nil or not vim.api.nvim_buf_is_valid(shown.bufnr) then
        -- Named after the directory it lists, so that every project gets a
        -- buffer of its own, and so that :edit and plugins that open in the
        -- current window create their own instead of taking this one over
        local bufnr = vim.fn.bufadd("scratch://issues" .. dir)
        vim.fn.bufload(bufnr)
        buffers.set(bufnr, { kind = "list", scope = scope, dir = dir })

        vim.bo[bufnr].buftype = "nofile"
        vim.bo[bufnr].filetype = "scratchissues"
        vim.bo[bufnr].buflisted = false
        vim.bo[bufnr].swapfile = false
        vim.bo[bufnr].bufhidden = "hide"
        vim.bo[bufnr].modifiable = false

        vim.keymap.set("n", "<CR>", open_entry, { buffer = bufnr, noremap = true, silent = true })

        vim.keymap.set("n", "q", window.close, { buffer = bufnr, noremap = true, silent = true })

        -- Tab is the same keycode as C-i: mapping it would eat the jump forward
        vim.keymap.set(
            "n",
            "<S-Tab>",
            toggle_scope,
            { buffer = bufnr, noremap = true, silent = true }
        )

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

        -- Coming back from an issue must show what was just edited. The list
        -- entered is also the one to open with next time, the same way the
        -- note last seen decides which note :ScratchToggle shows.
        vim.api.nvim_create_autocmd("BufEnter", {
            group = augroup,
            buffer = bufnr,
            callback = function()
                state.scope = scope
                M.refresh(bufnr)

                -- The header answers to no key, so a list is entered on its
                -- first issue. Only the first time: after that the position
                -- is the one the buffer was left on.
                if shown.fresh then
                    shown.fresh = false
                    pcall(vim.api.nvim_win_set_cursor, 0, { 2, 0 })
                end
            end,
        })

        shown = { bufnr = bufnr, line_map = {}, fresh = true }
        state.lists[dir] = shown
    end

    -- Not repainted here: that happens on entering the buffer, which is the
    -- first moment there is a window to size the rows against.
    return shown.bufnr
end

--- Scope of the list to open with: a memory of the last one seen
---@return string
function M.scope()
    return state.scope
end

--- Name of the sort order in effect
---@return string
function M.sort()
    return view.sort
end

return M
