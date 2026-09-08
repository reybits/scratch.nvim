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

--- Write a buffer that stands for a file. Everything the plugin keeps on disk
--- is an ordinary file buffer, so one rule covers notes and issues alike.
---
--- Vim must ask before overwriting a file that changed under a modified
--- buffer, and at quit time there is nobody to ask - which is how Neovim hung
--- instead of exiting. A drifted buffer is therefore left alone: quitting is
--- refused with E162 naming the file, and resolving it (`:w!` or `:e!`) stays
--- the user's call rather than something the plugin decides silently.
---@param bufnr number
local function write_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    if vim.bo[bufnr].buftype ~= "" or not vim.bo[bufnr].modified then
        return
    end

    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent write")
    end)
end

--- Write what is on screen, for the quit. Buffers are written when they stop
--- being visible; the one still in the window never gets that chance, and a
--- quit is refused before any window closes.
---
--- Nothing else is written here. A buffer of ours that is off screen has been
--- through that rule already, and one still modified afterwards was edited
--- outside the window - writing it would overwrite work we know nothing about.
local function save_all()
    local shown = window.current_buf()
    if shown and buffers.get(shown) then
        write_buffer(shown)
    end
end

--- Let go of the issue buffers when the window closes. They exist to be read
--- and edited in it; keeping them afterwards leaves modified buffers around
--- that block quitting and drift away from their files.
---
--- A buffer that is still modified here was changed outside the window - it
--- is not ours to discard, so it stays and Neovim will ask about it.
local function release_issues()
    buffers.each("issue", function(bufnr)
        if not vim.bo[bufnr].modified then
            buffers.forget(bufnr)
            pcall(vim.api.nvim_buf_delete, bufnr, {})
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
            -- the header answers to no key, so start on the first issue
            cursor_home = 2,
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
        -- a note is a buffer of its own, and Neovim keeps its position
        cursor_key = nil,
    }
end

-- ── Note buffers ────────────────────────────────────────────────────

--- Get or create the buffer of a note type.
---
--- A note that has a file *is* that file: Neovim then owns reading, writing,
--- undo, reloading and the cursor position, and the local note of another
--- project is another buffer by construction. Only the temporary note, which
--- has nowhere to be written, stays a scratch buffer.
---
--- Either way the buffer carries a name, because :edit takes over an empty,
--- nameless buffer instead of creating one, and plugins that open in the
--- current window inherit that - oil.nvim on `-` would turn the note into a
--- directory listing. bufadd, not nvim_create_buf: it returns the buffer that
--- already carries the name, where set_name would fail with E95.
---@param type string
---@return number bufnr
local function get_or_create_buffer(type)
    local path = note_path(type)
    local bufnr = vim.fn.bufadd(path or "scratch://note/temp")
    if buffers.get(bufnr) then
        return bufnr
    end

    vim.fn.bufload(bufnr)
    buffers.set(bufnr, { kind = "note", type = type, path = path })

    if path == nil then
        vim.bo[bufnr].buftype = "nofile"
        vim.bo[bufnr].swapfile = false
        vim.bo[bufnr].filetype = "markdown"
    end
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].bufhidden = "hide"

    vim.treesitter.start(bufnr, "markdown")

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

--- Buffer of the note to open with
---@return number bufnr
local function note_buffer()
    return get_or_create_buffer(current_type)
end

-- ── Public API ──────────────────────────────────────────────────────

--- Toggle the note in the scratch window
M.toggle = function()
    window.show("note", note_buffer)
end

--- Toggle the issue list in the scratch window
M.issues = function()
    window.show("list", list.buffer)
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
    -- written when the window swaps it out, and its cursor stays with it.
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
    window.swap_to(get_or_create_buffer(current_type))
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
    window.setup(config, describe, release_issues)

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
    ---
    --- Both are nested, because a :write from inside an autocommand raises no
    --- write events of its own unless it is, and the rules below - where the
    --- directory comes from, what an emptied note leaves behind - live in
    --- exactly those events.
    vim.api.nvim_create_autocmd({ "ExitPre", "VimLeavePre" }, {
        group = setup_augroup,
        nested = true,
        callback = save_all,
    })

    -- The one rule of persistence: a buffer is written when it stops being
    -- visible - left by C-o, swapped out of the window, or closed with it.
    vim.api.nvim_create_autocmd("BufWinLeave", {
        group = setup_augroup,
        nested = true,
        callback = function(args)
            if buffers.get(args.buf) == nil then
                return
            end

            write_buffer(args.buf)
        end,
    })

    -- The directory of a scope comes into being with the first file written
    -- into it. :write does not create it the way writefile() used to, and a
    -- note that was never touched is never written, so an untouched scope
    -- still leaves nothing on disk.
    vim.api.nvim_create_autocmd("BufWritePre", {
        group = setup_augroup,
        callback = function(args)
            local info = buffers.get(args.buf)
            if info == nil or info.path == nil then
                return
            end

            local dir = vim.fn.fnamemodify(info.path, ":h")
            if vim.fn.isdirectory(dir) == 0 then
                vim.fn.mkdir(dir, "p")
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

    -- A new working directory means a new project, and a new file for the
    -- local note. That file names its own buffer, so nothing has to be
    -- flushed or cleared here: the window swaps to the note of the project it
    -- is in now, and the note it leaves is written on the way out.
    vim.api.nvim_create_autocmd("DirChanged", {
        group = setup_augroup,
        callback = function()
            paths.reset()

            local shown = window.current_buf()
            local info = shown and buffers.get(shown)
            if info and info.kind == "note" and info.type == "local" then
                window.swap_to(get_or_create_buffer("local"))
            end
        end,
    })
end

return M
