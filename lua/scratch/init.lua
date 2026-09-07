-------------------------------------------------------------------------------
-- scratch.nvim - Floating scratch notes and lightweight issue tracking.
--
-- Author: Andrey Ugolnik
-- License: MIT
-- GitHub: https://github.com/reybits/scratch.nvim
--
-- Configuration, the note buffers and the commands. The window lives in
-- window.lua and asks this module, through describe(), what a buffer should
-- be called and where its cursor belongs - so the dependencies point one way
-- only: init -> list -> window, and everyone -> buffers.
--
-- Persistence has a single rule: a buffer is written when it stops being
-- visible. Where it goes is a property of the buffer, kept in the registry,
-- never of a "currently selected" field.
-------------------------------------------------------------------------------

local paths = require("scratch.paths")
local buffers = require("scratch.buffers")
local issue = require("scratch.issue")
local list = require("scratch.list")
local window = require("scratch.window")

local M = {}

--- Default configuration
---@class scratch.Config
local defaults = {
    title = "Scratch",
    width = 0.6,
    height = 0.6,
    border = "rounded",
    local_notes = true,
    global_notes = true,
    close_on_leave = true,
    local_dir = ".scratch",
    win_opts = {
        wrap = true,
        linebreak = true,
        cursorline = true,
    },
}

--- Merged configuration (set during setup)
---@type scratch.Config
local config = vim.tbl_deep_extend("force", {}, defaults)

--- Which note to open with. Follows the buffer as soon as one is on screen;
--- it is a memory of the last note seen, never the answer to "which note is
--- this".
local current_type = "temp"

-- ── Notes on disk ───────────────────────────────────────────────────

--- Get the file path for a note type. A scope keeps its note beside its
--- issues, so both areas have the same shape.
---@param type string
---@return string|nil
local function note_path(type)
    if type == "temp" then
        return nil
    end
    return paths.scope_dir(type) .. "/note.md"
end

--- Load file contents into a buffer
---@param bufnr number
---@param path string
local function load_file(bufnr, path)
    if vim.fn.filereadable(path) == 1 then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.fn.readfile(path))
    end
end

--- Check whether the note holds nothing but blank lines
---@param lines string[]
---@return boolean
local function is_blank(lines)
    for _, line in ipairs(lines) do
        if not line:match("^%s*$") then
            return false
        end
    end
    return true
end

--- Save buffer contents to a file
---@param bufnr number
---@param path string
local function save_file(bufnr, path)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- An empty note leaves no file behind; a cleared one takes its file with it
    if is_blank(lines) then
        if vim.fn.filereadable(path) == 1 then
            vim.fn.delete(path)
        end
        return
    end

    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end
    vim.fn.writefile(lines, path)
end

--- Path a buffer is stored at, asked of the buffer rather than of any state
---@param bufnr number
---@return string|nil
local function path_of(bufnr)
    local info = buffers.get(bufnr)
    if info == nil or info.kind ~= "note" then
        return nil
    end
    return note_path(info.type)
end

--- Write a note buffer to the file of its own type
---@param bufnr number
local function save_note(bufnr)
    local path = path_of(bufnr)
    if path then
        save_file(bufnr, path)
    end
end

--- Re-read a note buffer from the file of its own type
---@param bufnr number
local function reload_note(bufnr)
    local path = path_of(bufnr)
    if path then
        load_file(bufnr, path)
    end
end

--- Write everything of ours, for the quit. Buffers are written when they stop
--- being visible; the one still on screen never gets that chance, and a quit
--- is refused before any window closes.
local function save_all()
    buffers.each("note", save_note)
    buffers.each("issue", function(bufnr)
        if vim.bo[bufnr].modified then
            vim.api.nvim_buf_call(bufnr, function()
                vim.cmd("silent write")
            end)
        end
    end)
end

-- ── Note types ──────────────────────────────────────────────────────

--- Get ordered list of enabled note types
---@return string[]
local function enabled_types()
    local types = { "temp" }
    if config.local_notes then
        table.insert(types, "local")
    end
    if config.global_notes then
        table.insert(types, "global")
    end
    return types
end

--- Get display label for a note type
---@param type string
---@return string
local function type_label(type)
    local labels = {
        temp = "Temporary",
        ["local"] = "Local",
        global = "Global",
    }
    return labels[type] or type
end

-- ── What the window shows ───────────────────────────────────────────

--- Everything the window needs about a buffer: how to name it, what to offer
--- in the footer, and under which key its cursor belongs. Derived from the
--- registry, so it always describes what is on screen.
---@param bufnr number
---@return scratch.Chrome
local function describe(bufnr)
    local info = buffers.get(bufnr)
    local kind = info and info.kind or "foreign"

    if kind == "list" then
        return {
            kind = kind,
            title = " " .. config.title .. " [Issues: " .. type_label(list.scope()) .. "] ",
            footer = table.concat({
                "'q' close",
                "'CR' open",
                "'S-Tab' scope",
                "'T'ype/'P'riority/'S'tatus",
                "'<'/'>' sort",
            }, "  |  "),
            cursor_key = "list/" .. list.scope(),
        }
    end

    if kind == "issue" then
        return {
            kind = kind,
            title = " " .. config.title .. " [Issue] ",
            footer = table.concat({ "'C-o' back", "saved on close" }, "  |  "),
            -- a file buffer keeps its own position
            cursor_key = nil,
        }
    end

    -- A foreign buffer is on its way out; it only needs a kind
    local type = info and info.type or current_type
    local types = enabled_types()
    local parts = { "'q' close", "'R' reset" }
    if #types > 1 then
        table.insert(parts, "'S-Tab' switch note")
    end

    return {
        kind = kind,
        title = #types == 1 and (" " .. config.title .. " ")
            or (" " .. config.title .. " [" .. type_label(type) .. "] "),
        footer = table.concat(parts, "  |  "),
        cursor_key = "note/" .. type,
    }
end

-- ── Note buffers ────────────────────────────────────────────────────

--- Get or create the buffer of a note type
---@param type string
---@return number bufnr
local function get_or_create_buffer(type)
    local bufnr = buffers.find("note", type)
    if bufnr then
        return bufnr
    end

    -- A name keeps the buffer from being reused: :edit takes over an empty,
    -- nameless buffer instead of creating one, and plugins that open in the
    -- current window inherit that - oil.nvim on `-` would turn the note into
    -- a directory listing. bufadd rather than nvim_create_buf, because it
    -- returns the buffer already carrying the name if an older one survived a
    -- plugin reload, where set_name would fail with E95.
    bufnr = vim.fn.bufadd("scratch://note/" .. type)
    vim.fn.bufload(bufnr)
    buffers.set(bufnr, { kind = "note", type = type })

    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].filetype = "markdown"
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].bufhidden = "hide"

    vim.treesitter.start(bufnr, "markdown")

    local path = note_path(type)
    if path then
        load_file(bufnr, path)
    end

    vim.keymap.set("n", "q", function()
        window.close()
    end, { buffer = bufnr, noremap = true, silent = true })

    vim.keymap.set("n", "R", M.reset, { buffer = bufnr, noremap = true, silent = true })

    -- Tab is the same keycode as C-i, so mapping it would eat the jumplist
    if #enabled_types() > 1 then
        vim.keymap.set(
            "n",
            "<S-Tab>",
            M.next_type,
            { buffer = bufnr, noremap = true, silent = true }
        )
    end

    return bufnr
end

--- Buffer of the note to open with, refreshed from disk
---@return number bufnr
local function note_buffer()
    local bufnr = get_or_create_buffer(current_type)
    reload_note(bufnr)
    return bufnr
end

-- ── Public API ──────────────────────────────────────────────────────

--- Toggle the note in the scratch window
M.toggle = function()
    window.show("note", note_buffer)
end

--- Toggle the issue list in the scratch window
M.issues = function()
    window.show("list", list.buffer)
    if window.is_open() then
        list.refresh()
        -- with nothing remembered, start on the first issue rather than the
        -- header, which no key acts on
        window.restore_cursor(2)
    end
end

--- Show an issue file in the scratch window
---@param path string
M.open_issue = function(path)
    list.open(path)
end

--- Cycle through note types
---@param offset number: 1 for next, -1 for previous
local function cycle_type(offset)
    if not window.is_open() then
        return
    end

    local types = enabled_types()
    if #types <= 1 then
        return
    end

    -- Step away from the note on screen, whichever it is. Its contents are
    -- written when the window swaps it out, so only the cursor is kept here.
    window.remember_cursor()

    local shown = buffers.get(window.current_buf())
    local from = shown and shown.type or current_type

    local index = 1
    for i, type in ipairs(types) do
        if type == from then
            index = i
            break
        end
    end

    current_type = types[((index - 1 + offset) % #types) + 1]

    local bufnr = get_or_create_buffer(current_type)
    window.swap_to(bufnr)

    -- Reload from disk to pick up changes from other sessions
    reload_note(bufnr)
    window.restore_cursor()
end

--- Switch to the next note type
M.next_type = function()
    cycle_type(1)
end

--- Switch to the previous note type
M.prev_type = function()
    cycle_type(-1)
end

--- Clear the note on screen. Which one that is comes from the window, not
--- from any remembered type: the two part ways as soon as the user jumps.
M.reset = function()
    local bufnr = window.current_buf()
    local info = bufnr and buffers.get(bufnr)
    if info == nil or info.kind ~= "note" then
        return
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    window.forget_cursor("note/" .. info.type)
end

--- Close the scratch window
M.close = function()
    window.close()
end

--- Create an issue and open it. The line under the cursor seeds type and
--- title when it is a todo comment, and its location goes into the body.
---@param scope string: "local" or "global"
---@param title string|nil
M.task = function(scope, title)
    local hint = issue.from_comment(vim.api.nvim_get_current_line())
    local body = {}

    local bufnr = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.bo[bufnr].buftype == "" and name ~= "" then
        local file = vim.fn.fnamemodify(name, ":.")
        table.insert(body, file .. ":" .. vim.api.nvim_win_get_cursor(0)[1])
    end

    local function create(text)
        if text == nil or text == "" then
            return
        end

        list.open(issue.create(scope, {
            type = hint and hint.type,
            title = text,
            body = body,
        }))

        -- Start at the end, where the body is written. Not `normal! G`: that
        -- is a jump, and its jumplist entry would make the first C-o land in
        -- this very buffer instead of going back.
        local opened = vim.api.nvim_get_current_buf()
        pcall(vim.api.nvim_win_set_cursor, 0, { vim.api.nvim_buf_line_count(opened), 0 })
    end

    if title and title ~= "" then
        create(title)
    else
        vim.ui.input({ prompt = "Issue title: ", default = hint and hint.title or "" }, create)
    end
end

--- Setup the plugin
---@param opts scratch.Config|nil
function M.setup(opts)
    config = vim.tbl_deep_extend("force", {}, defaults, opts or {})
    paths.setup(config)
    window.setup(config, describe)

    vim.api.nvim_create_user_command("ScratchToggle", M.toggle, {})
    vim.api.nvim_create_user_command("ScratchIssues", M.issues, {})

    -- Bang targets the global scope; inside the list the visible scope wins
    vim.api.nvim_create_user_command("ScratchTask", function(args)
        local scope = "local"
        if args.bang then
            scope = "global"
        elseif list.is_buffer(vim.api.nvim_get_current_buf()) then
            scope = list.scope()
        end
        M.task(scope, args.args)
    end, { nargs = "?", bang = true })

    local setup_augroup = vim.api.nvim_create_augroup("scratch.nvim-setup", { clear = true })

    -- Both events on purpose. ExitPre runs before Neovim decides whether an
    -- unwritten buffer cancels the quit, so it is the one that keeps an issue
    -- edited and left behind from blocking :qa. VimLeavePre, which the manual
    -- calls the event "for really exiting", stays as the guarantee.
    vim.api.nvim_create_autocmd({ "ExitPre", "VimLeavePre" }, {
        group = setup_augroup,
        callback = save_all,
    })

    -- The one rule of persistence: a buffer is written when it stops being
    -- visible - left by C-o, swapped out of the window, or closed with it.
    vim.api.nvim_create_autocmd("BufWinLeave", {
        group = setup_augroup,
        callback = function(args)
            local info = buffers.get(args.buf)
            if info == nil then
                return
            end

            if info.kind == "note" then
                save_note(args.buf)
            elseif info.kind == "issue" and vim.bo[args.buf].modified then
                vim.api.nvim_buf_call(args.buf, function()
                    vim.cmd("silent write")
                end)
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufEnter", {
        group = setup_augroup,
        callback = function(args)
            local info = buffers.get(args.buf)
            -- The note to open with is simply the last one seen
            if info and info.kind == "note" then
                current_type = info.type
            end
        end,
    })

    -- None of our buffers belong in the buffer list. Both :edit and a jumplist
    -- move set 'buflisted' back to true, so this runs on every display rather
    -- than once at creation.
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = setup_augroup,
        callback = function(args)
            if buffers.get(args.buf) then
                vim.bo[args.buf].buflisted = false
            end
        end,
    })

    -- A new working directory means a new project: flush the note to the old
    -- path before the root is re-resolved, or it would leak into the new one
    vim.api.nvim_create_autocmd("DirChanged", {
        group = setup_augroup,
        callback = function()
            local bufnr = buffers.find("note", "local")
            if bufnr then
                save_file(bufnr, note_path("local"))
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
                window.forget_cursor("note/local")
            end

            paths.reset()

            if bufnr and vim.fn.bufwinid(bufnr) ~= -1 then
                reload_note(bufnr)
            end
        end,
    })
end

return M
