local paths = require("scratch.paths")
local issue = require("scratch.issue")
local list = require("scratch.list")

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
    local_notes_file = ".scratch.md",
    win_opts = {
        wrap = true,
        linebreak = true,
    },
}

--- Merged configuration (set during setup)
---@type scratch.Config
local config = vim.tbl_deep_extend("force", {}, defaults)

--- Internal state
---@class scratch.State
---@field buffers table<string, number|nil>
---@field cursors table<string, number[]|nil>
---@field winnr number|nil
---@field foonr number|nil
---@field foo_bufnr number|nil
---@field current_type string
---@field prev_winnr number|nil: window the scratch window was opened from
---@field closing boolean
local state = {
    buffers = {},
    cursors = {},
    winnr = nil,
    foonr = nil,
    foo_bufnr = nil,
    current_type = "temp",
    prev_winnr = nil,
    closing = false,
}

local augroup = vim.api.nvim_create_augroup("scratch.nvim", { clear = true })

-- ── Persistence helpers ─────────────────────────────────────────────

--- Get the file path for a note type
---@param type string
---@return string|nil
local function note_path(type)
    if type == "temp" then
        return nil
    elseif type == "local" then
        return paths.root() .. "/" .. config.local_notes_file
    elseif type == "global" then
        return paths.data_dir() .. "/global.md"
    end
end

--- Load file contents into a buffer
---@param bufnr number
---@param path string
local function load_file(bufnr, path)
    if vim.fn.filereadable(path) == 1 then
        local lines = vim.fn.readfile(path)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
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

--- Save the current note type to disk (if applicable)
local function save_current()
    local bufnr = state.buffers[state.current_type]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        local path = note_path(state.current_type)
        if path then
            save_file(bufnr, path)
        end
    end
end

--- Save all persistent note types to disk
local function save_all()
    for type, bufnr in pairs(state.buffers) do
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            local path = note_path(type)
            if path then
                save_file(bufnr, path)
            end
        end
    end
end

--- Reload the current note type from disk (if applicable)
local function reload_current()
    local bufnr = state.buffers[state.current_type]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        local path = note_path(state.current_type)
        if path then
            load_file(bufnr, path)
        end
    end
end

-- ── Type helpers ────────────────────────────────────────────────────

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

-- ── Title & footer builders ─────────────────────────────────────────

--- What the window is showing. Derived from the buffer itself, so the chrome
--- can never disagree with what is on screen, and a buffer that belongs to
--- nobody is recognised as such.
---@param bufnr number
---@return string: "note", "list", "issue" or "foreign"
local function buffer_kind(bufnr)
    if list.is_buffer(bufnr) then
        return "list"
    end
    for _, note in pairs(state.buffers) do
        if note == bufnr then
            return "note"
        end
    end
    if issue.is_issue(vim.api.nvim_buf_get_name(bufnr)) then
        return "issue"
    end
    return "foreign"
end

--- Build the window title string
---@param bufnr number
---@return string
local function build_title(bufnr)
    local kind = buffer_kind(bufnr)
    if kind == "list" then
        return " " .. config.title .. " [Issues: " .. type_label(list.scope()) .. "] "
    elseif kind == "issue" then
        return " " .. config.title .. " [Issue] "
    end

    local types = enabled_types()
    if #types == 1 then
        return " " .. config.title .. " "
    end
    return " " .. config.title .. " [" .. type_label(state.current_type) .. "] "
end

--- Build the footer text string
---@param bufnr number
---@return string
local function build_footer_text(bufnr)
    local kind = buffer_kind(bufnr)
    if kind == "list" then
        return table.concat({
            "'q' close",
            "'CR' open",
            "'S-Tab' scope",
            "'T'ype/'P'riority/'S'tatus",
        }, "  |  ")
    elseif kind == "issue" then
        return table.concat({ "'C-o' back", "':w' save" }, "  |  ")
    end

    local types = enabled_types()
    local parts = { "'q' close", "'R' reset" }
    if #types > 1 then
        table.insert(parts, "'S-Tab' switch note")
    end
    return table.concat(parts, "  |  ")
end

-- ── Window config builder ───────────────────────────────────────────

---@class scratch.WinConfig
---@field cfg_wnd vim.api.keyset.win_config
---@field cfg_foo vim.api.keyset.win_config
---@field footer_text string: already cut to the window width

--- Build main and footer window configurations
---@param bufnr number: buffer the window will show
---@return scratch.WinConfig
local function make_window_config(bufnr)
    local width, height

    if config.width > 0 and config.width <= 1 then
        width = math.floor(config.width * vim.o.columns)
    else
        width = math.floor(config.width)
    end

    local available_lines = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)

    if config.height > 0 and config.height <= 1 then
        height = math.floor(config.height * available_lines)
    else
        height = math.floor(config.height)
    end
    local row = math.floor((available_lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local title = build_title(bufnr)

    -- The footer window is sized by its text, so a long hint list would hang
    -- off the screen on a narrow terminal. One column goes to the leading
    -- space update_footer adds.
    local footer_text = build_footer_text(bufnr)
    if #footer_text + 1 > width then
        footer_text = footer_text:sub(1, width - 1)
    end

    local cfg_wnd = {
        relative = "editor",
        border = config.border,
        style = "minimal",
        zindex = 50,
        title = title,
        title_pos = "center",
        width = width,
        height = height,
        row = row,
        col = col,
    }

    local cfg_foo = {
        relative = "editor",
        style = "minimal",
        zindex = 51,
        border = "none",
        focusable = false,
        width = math.min(#footer_text + 2, width),
        height = 1,
        row = row + height + 1,
        col = col + math.floor((width - #footer_text) / 2),
    }

    return {
        cfg_wnd = cfg_wnd,
        cfg_foo = cfg_foo,
        footer_text = footer_text,
    }
end

-- ── Buffer creation ─────────────────────────────────────────────────

--- Get or create a buffer for the given note type
---@param type string
---@return number bufnr
local function get_or_create_buffer(type)
    local bufnr = state.buffers[type]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        return bufnr
    end

    bufnr = vim.api.nvim_create_buf(false, true)

    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].filetype = "markdown"
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].bufhidden = "hide"

    vim.treesitter.start(bufnr, "markdown")

    -- Load from disk if applicable
    local path = note_path(type)
    if path then
        load_file(bufnr, path)
    end

    -- Set keymaps on the buffer
    vim.keymap.set("n", "q", function()
        M.close()
    end, { buffer = bufnr, noremap = true, silent = true })

    vim.keymap.set("n", "R", function()
        M.reset()
    end, { buffer = bufnr, noremap = true, silent = true })

    -- Tab is the same keycode as C-i, so mapping it would eat the jumplist
    local types = enabled_types()
    if #types > 1 then
        vim.keymap.set("n", "<S-Tab>", function()
            M.next_type()
        end, { buffer = bufnr, noremap = true, silent = true })
    end

    state.buffers[type] = bufnr
    return bufnr
end

-- ── Footer helpers ──────────────────────────────────────────────────

--- Get or create the footer buffer
---@return number bufnr
local function get_or_create_footer_buf()
    if state.foo_bufnr and vim.api.nvim_buf_is_valid(state.foo_bufnr) then
        return state.foo_bufnr
    end
    state.foo_bufnr = vim.api.nvim_create_buf(false, true)
    return state.foo_bufnr
end

--- Update footer buffer contents
---@param text string: as sized by make_window_config, so the two agree
local function update_footer(text)
    local foo_bufnr = get_or_create_footer_buf()
    vim.api.nvim_buf_set_lines(foo_bufnr, 0, -1, false, { " " .. text })
end

-- ── Window update helper ────────────────────────────────────────────

--- Apply user's window-local options to a window.
--- Needed after every nvim_win_set_config / nvim_open_win because
--- style = "minimal" resets window-local options to defaults.
---@param winnr number
local function apply_win_opts(winnr)
    for opt, val in pairs(config.win_opts) do
        vim.wo[winnr][opt] = val
    end
end

--- Save the current cursor position for a note type.
--- In-memory only; not persisted across Neovim sessions.
---@param winnr number|nil
---@param type string
local function save_cursor(winnr, type)
    if not winnr or not vim.api.nvim_win_is_valid(winnr) then
        return
    end
    state.cursors[type] = vim.api.nvim_win_get_cursor(winnr)
end

--- Restore a previously saved cursor position, clamped to the current buffer.
---@param winnr number
---@param type string
local function restore_cursor(winnr, type)
    local pos = state.cursors[type]
    if pos == nil then
        return
    end
    local bufnr = vim.api.nvim_win_get_buf(winnr)
    local last = vim.api.nvim_buf_line_count(bufnr)
    local row = math.min(pos[1], last > 0 and last or 1)
    pcall(vim.api.nvim_win_set_cursor, winnr, { row, pos[2] })
end

--- Update window title and footer after a buffer swap, type switch or resize
local function update_windows()
    if not state.winnr or not vim.api.nvim_win_is_valid(state.winnr) then
        return
    end

    local bufnr = vim.api.nvim_win_get_buf(state.winnr)
    local cfg = make_window_config(bufnr)
    vim.api.nvim_win_set_config(state.winnr, cfg.cfg_wnd)
    apply_win_opts(state.winnr)

    update_footer(cfg.footer_text)
    if state.foonr and vim.api.nvim_win_is_valid(state.foonr) then
        vim.api.nvim_win_set_config(state.foonr, cfg.cfg_foo)
    end
end

-- ── Window management ───────────────────────────────────────────────

--- Buffer of the current note type, loaded from disk
---@return number bufnr
local function note_buffer()
    local bufnr = get_or_create_buffer(state.current_type)
    reload_current()
    return bufnr
end

--- Persist whatever the window is showing. A foreign buffer is never written:
--- it is not ours to save.
local function save_shown()
    if state.winnr == nil or not vim.api.nvim_win_is_valid(state.winnr) then
        return
    end

    local bufnr = vim.api.nvim_win_get_buf(state.winnr)
    local kind = buffer_kind(bufnr)
    if kind == "note" then
        save_current()
        save_cursor(state.winnr, state.current_type)
    elseif kind == "list" then
        list.remember_cursor()
    elseif kind == "issue" and vim.bo[bufnr].modified then
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent write")
        end)
    end
end

--- A jump can drag any file into the floating window (C-o, gF, gd), leaving
--- the user stuck in a window whose keymaps do not apply. Hand the buffer to
--- a normal window instead and let the scratch window go.
---@param bufnr number
local function evacuate(bufnr)
    local target = state.prev_winnr
    if
        target == nil
        or not vim.api.nvim_win_is_valid(target)
        or vim.api.nvim_win_get_config(target).relative ~= ""
    then
        target = nil
        for _, winnr in ipairs(vim.api.nvim_list_wins()) do
            if winnr ~= state.winnr and vim.api.nvim_win_get_config(winnr).relative == "" then
                target = winnr
                break
            end
        end
    end

    if target == nil then
        return
    end

    M.close()
    vim.api.nvim_set_current_win(target)
    vim.api.nvim_win_set_buf(target, bufnr)
end

--- Open the scratch floating window
---@param bufnr number: buffer to show
local function open_window(bufnr)
    local cfg = make_window_config(bufnr)
    state.prev_winnr = vim.api.nvim_get_current_win()

    -- Main window
    state.winnr = vim.api.nvim_open_win(bufnr, true, cfg.cfg_wnd)
    apply_win_opts(state.winnr)
    if buffer_kind(bufnr) == "note" then
        restore_cursor(state.winnr, state.current_type)
    end

    -- Footer window
    update_footer(cfg.footer_text)
    local foo_bufnr = get_or_create_footer_buf()
    state.foonr = vim.api.nvim_open_win(foo_bufnr, false, cfg.cfg_foo)

    -- Set up autocmds (clear previous ones)
    vim.api.nvim_clear_autocmds({ group = augroup })

    -- WinClosed for main window
    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        pattern = tostring(state.winnr),
        once = true,
        callback = function()
            M.close()
        end,
    })

    -- Leaving the window, not the buffer: swapping buffers inside the window
    -- (type switch, opening an issue) must not count as leaving
    if config.close_on_leave then
        vim.api.nvim_create_autocmd("WinLeave", {
            group = augroup,
            callback = function()
                if state.winnr and vim.api.nvim_get_current_win() == state.winnr then
                    M.close()
                end
            end,
        })
    end

    -- VimResized
    vim.api.nvim_create_autocmd("VimResized", {
        group = augroup,
        callback = function()
            update_windows()
        end,
    })

    -- Title and footer follow whatever buffer the window ends up showing,
    -- including a jump back to the list with C-o. A buffer that is none of
    -- ours does not belong here at all.
    vim.api.nvim_create_autocmd("BufEnter", {
        group = augroup,
        callback = function()
            if state.winnr == nil or vim.api.nvim_get_current_win() ~= state.winnr then
                return
            end

            local shown = vim.api.nvim_get_current_buf()
            if buffer_kind(shown) == "foreign" then
                evacuate(shown)
            else
                update_windows()
            end
        end,
    })
end

--- Show a buffer in the scratch window: open the window if it is closed, focus
--- it if the focus is elsewhere, swap to the buffer if the window shows
--- something else, and close if that kind is already in front.
---@param kind string: "note" or "list"
---@param get_buffer function: called only when a buffer is actually needed
local function show(kind, get_buffer)
    if state.winnr == nil or not vim.api.nvim_win_is_valid(state.winnr) then
        open_window(get_buffer())
        return
    end

    if buffer_kind(vim.api.nvim_win_get_buf(state.winnr)) == kind then
        if state.winnr == vim.api.nvim_get_current_win() then
            M.close()
        else
            vim.api.nvim_set_current_win(state.winnr)
        end
        return
    end

    save_shown()
    vim.api.nvim_win_set_buf(state.winnr, get_buffer())
    vim.api.nvim_set_current_win(state.winnr)
    update_windows()
end

-- ── Issue helpers ───────────────────────────────────────────────────

--- Show an issue file in the scratch window
---@param path string
local function open_issue(path)
    if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        save_shown()
        vim.api.nvim_set_current_win(state.winnr)
    else
        -- Open on the list, so C-o from the issue lands there
        open_window(list.buffer())
        list.refresh()
    end

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.cmd("normal! G")
    update_windows()
end

-- ── Public API ──────────────────────────────────────────────────────

--- Cycle through note types
---@param offset number: 1 for next, -1 for previous
local function cycle_type(offset)
    if not state.winnr or not vim.api.nvim_win_is_valid(state.winnr) then
        return
    end

    local types = enabled_types()
    if #types <= 1 then
        return
    end

    -- Save current before switching
    save_current()
    save_cursor(state.winnr, state.current_type)

    -- Find current index
    local current_idx = 1
    for i, t in ipairs(types) do
        if t == state.current_type then
            current_idx = i
            break
        end
    end

    -- Compute next index (wrapping)
    local next_idx = ((current_idx - 1 + offset) % #types) + 1
    state.current_type = types[next_idx]

    -- Get or create the buffer for the new type
    local bufnr = get_or_create_buffer(state.current_type)

    vim.api.nvim_win_set_buf(state.winnr, bufnr)

    -- Reload from disk to pick up changes from other sessions
    reload_current()
    restore_cursor(state.winnr, state.current_type)

    -- Update title and footer
    update_windows()
end

--- Toggle the note in the scratch window
M.toggle = function()
    show("note", note_buffer)
end

--- Toggle the issue list in the scratch window
M.issues = function()
    show("list", list.buffer)
    if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        list.refresh()
        list.restore_cursor()
    end
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
        open_issue(issue.create(scope, {
            type = hint and hint.type,
            title = text,
            body = body,
        }))
    end

    if title and title ~= "" then
        create(title)
    else
        vim.ui.input({ prompt = "Issue title: ", default = hint and hint.title or "" }, create)
    end
end

--- Repaint the window chrome; the list calls this after changing scope
M.update = function()
    update_windows()
end

--- Close the scratch window
M.close = function()
    if state.closing then
        return
    end
    state.closing = true

    save_shown()

    pcall(vim.api.nvim_win_close, state.winnr, true)
    state.winnr = nil

    pcall(vim.api.nvim_win_close, state.foonr, true)
    state.foonr = nil

    vim.api.nvim_clear_autocmds({ group = augroup })

    state.closing = false
end

--- Reset the current buffer content
M.reset = function()
    local bufnr = state.buffers[state.current_type]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end
    state.cursors[state.current_type] = nil
end

--- Switch to the next note type
M.next_type = function()
    cycle_type(1)
end

--- Switch to the previous note type
M.prev_type = function()
    cycle_type(-1)
end

--- Setup the plugin
---@param opts scratch.Config|nil
function M.setup(opts)
    opts = opts or {}
    config = vim.tbl_deep_extend("force", {}, defaults, opts)

    vim.api.nvim_create_user_command("ScratchToggle", M.toggle, {})
    vim.api.nvim_create_user_command("ScratchIssues", M.issues, {})

    -- Bang targets the global scope; inside the list the visible scope wins
    vim.api.nvim_create_user_command("ScratchTask", function(opts)
        local scope = "local"
        if opts.bang then
            scope = "global"
        elseif list.is_buffer(vim.api.nvim_get_current_buf()) then
            scope = list.scope()
        end
        M.task(scope, opts.args)
    end, { nargs = "?", bang = true })

    local setup_augroup = vim.api.nvim_create_augroup("scratch.nvim-setup", { clear = true })

    -- Save all persistent notes on VimLeavePre
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = setup_augroup,
        callback = function()
            save_all()
        end,
    })

    -- None of our buffers belong in the buffer list. Both :edit and a jumplist
    -- move set 'buflisted' back to true, so this has to run on every display
    -- rather than once at creation.
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = setup_augroup,
        callback = function(args)
            if buffer_kind(args.buf) ~= "foreign" then
                vim.bo[args.buf].buflisted = false
            end
        end,
    })

    -- A new working directory means a new project: flush the note to the old
    -- path before the root is re-resolved, or it would leak into the new one
    vim.api.nvim_create_autocmd("DirChanged", {
        group = setup_augroup,
        callback = function()
            local bufnr = state.buffers["local"]
            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                save_file(bufnr, note_path("local"))
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
                state.cursors["local"] = nil
            end
            paths.reset()
            if state.current_type == "local" then
                reload_current()
            end
        end,
    })
end

return M
