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
}

--- Merged configuration (set during setup)
---@type scratch.Config
local config = vim.tbl_deep_extend("force", {}, defaults)

--- Internal state
---@class scratch.State
---@field buffers table<string, number|nil>
---@field winnr number|nil
---@field foonr number|nil
---@field foo_bufnr number|nil
---@field current_type string
---@field closing boolean
---@field project_root string|nil
local state = {
    buffers = {},
    winnr = nil,
    foonr = nil,
    foo_bufnr = nil,
    current_type = "temp",
    closing = false,
    switching = false,
    project_root = nil,
}

local augroup = vim.api.nvim_create_augroup("scratch.nvim", { clear = true })

-- ── Persistence helpers ─────────────────────────────────────────────

--- Find the project root (git root or cwd)
---@return string
local function find_project_root()
    if state.project_root then
        return state.project_root
    end
    local result = vim.fn.systemlist("git rev-parse --show-toplevel 2>/dev/null")
    if vim.v.shell_error == 0 and result[1] then
        state.project_root = result[1]
    else
        state.project_root = vim.fn.getcwd()
    end
    return state.project_root
end

--- Get the file path for a note type
---@param type string
---@return string|nil
local function note_path(type)
    if type == "temp" then
        return nil
    elseif type == "local" then
        return find_project_root() .. "/" .. config.local_notes_file
    elseif type == "global" then
        return vim.fn.stdpath("data") .. "/scratch.nvim/global.md"
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

--- Save buffer contents to a file
---@param bufnr number
---@param path string
local function save_file(bufnr, path)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
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

--- Build the window title string
---@return string
local function build_title()
    local types = enabled_types()
    if #types == 1 then
        return " " .. config.title .. " "
    end
    return " " .. config.title .. " [" .. type_label(state.current_type) .. "] "
end

--- Build the footer text string
---@return string
local function build_footer_text()
    local types = enabled_types()
    local parts = { "'q' close", "'R' reset" }
    if #types > 1 then
        table.insert(parts, "'Tab'/'S-Tab' switch note")
    end
    return table.concat(parts, "  |  ")
end

-- ── Window config builder ───────────────────────────────────────────

---@class scratch.WinConfig
---@field cfg_wnd vim.api.keyset.win_config
---@field cfg_foo vim.api.keyset.win_config

--- Build main and footer window configurations
---@return scratch.WinConfig
local function make_window_config()
    local width, height

    if config.width > 0 and config.width <= 1 then
        width = math.floor(config.width * vim.o.columns)
    else
        width = math.floor(config.width)
    end

    if config.height > 0 and config.height <= 1 then
        height = math.floor(config.height * vim.o.lines)
    else
        height = math.floor(config.height)
    end

    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local title = build_title()
    local footer_text = build_footer_text()

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
        width = #footer_text + 2,
        height = 1,
        row = row + height + 1,
        col = col + math.floor((width - #footer_text) / 2),
    }

    return {
        cfg_wnd = cfg_wnd,
        cfg_foo = cfg_foo,
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

    local types = enabled_types()
    if #types > 1 then
        vim.keymap.set("n", "<Tab>", function()
            M.next_type()
        end, { buffer = bufnr, noremap = true, silent = true })

        vim.keymap.set("n", "<S-Tab>", function()
            M.prev_type()
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
local function update_footer()
    local bufnr = get_or_create_footer_buf()
    local text = build_footer_text()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { " " .. text })
end

-- ── Window update helper ────────────────────────────────────────────

--- Update window title and footer after a type switch or resize
local function update_windows()
    if not state.winnr or not vim.api.nvim_win_is_valid(state.winnr) then
        return
    end

    local cfg = make_window_config()
    vim.api.nvim_win_set_config(state.winnr, cfg.cfg_wnd)

    update_footer()
    if state.foonr and vim.api.nvim_win_is_valid(state.foonr) then
        vim.api.nvim_win_set_config(state.foonr, cfg.cfg_foo)
    end
end

-- ── Window management ───────────────────────────────────────────────

--- Open the scratch floating window
local function open_window()
    local bufnr = get_or_create_buffer(state.current_type)
    local cfg = make_window_config()

    -- Main window
    state.winnr = vim.api.nvim_open_win(bufnr, true, cfg.cfg_wnd)
    vim.wo[state.winnr].cursorline = false

    -- Footer window
    update_footer()
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

    -- BufLeave
    if config.close_on_leave then
        vim.api.nvim_create_autocmd("BufLeave", {
            group = augroup,
            buffer = bufnr,
            callback = function()
                if not state.switching then
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

    -- Swap buffer in window (guard against BufLeave firing during swap)
    state.switching = true
    vim.api.nvim_win_set_buf(state.winnr, bufnr)
    state.switching = false

    -- Re-register BufLeave for the new buffer
    vim.api.nvim_clear_autocmds({ group = augroup, event = "BufLeave" })
    if config.close_on_leave then
        vim.api.nvim_create_autocmd("BufLeave", {
            group = augroup,
            buffer = bufnr,
            callback = function()
                if not state.switching then
                    M.close()
                end
            end,
        })
    end

    -- Update title and footer
    update_windows()
end

--- Toggle the scratch window
M.toggle = function()
    if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        if state.winnr == vim.api.nvim_get_current_win() then
            M.close()
        else
            vim.api.nvim_set_current_win(state.winnr)
        end
        return
    end

    open_window()
end

--- Close the scratch window
M.close = function()
    if state.closing then
        return
    end
    state.closing = true

    save_current()

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

    -- Save all persistent notes on VimLeavePre
    local leave_augroup = vim.api.nvim_create_augroup("scratch.nvim-leave", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = leave_augroup,
        callback = function()
            save_all()
        end,
    })
end

return M
