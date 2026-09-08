-------------------------------------------------------------------------------
-- scratch.nvim - Floating scratch notes and lightweight issue tracking.
--
-- Author: Andrey Ugolnik
-- License: MIT
-- GitHub: https://github.com/reybits/scratch.nvim
--
-- The floating window and its footer: opening, closing, swapping what is on
-- screen, keeping the chrome in step with it, and remembering where the
-- cursor stood.
--
-- It knows nothing about notes or issues. What a buffer is called, what its
-- footer says and under which key its cursor belongs is answered by the
-- describe() callback the application installs, so this module never has to
-- reach back into the one that owns the content.
-------------------------------------------------------------------------------

local M = {}

---@class scratch.Chrome
---@field title string
---@field footer string
---@field cursor_key string|nil: nil for buffers whose position Neovim keeps itself
---@field cursor_home number|nil: line to start on when nothing is remembered
---@field kind string

---@type scratch.Config
local config

---@type fun(bufnr: number): scratch.Chrome
local describe

---@type fun()|nil: called after the window is gone, so the application can
--- let go of whatever it was keeping for it
local on_close

local state = {
    winnr = nil,
    foonr = nil,
    foo_bufnr = nil,
    prev_winnr = nil,
    cursors = {},
    closing = false,
}

--- Install the configuration, the buffer describer and the close hook
---@param cfg scratch.Config
---@param describer fun(bufnr: number): scratch.Chrome
---@param closer fun()|nil
function M.setup(cfg, describer, closer)
    config = cfg
    describe = describer
    on_close = closer
end

-- ── geometry ────────────────────────────────────────────────────────

---@class scratch.WinConfig
---@field cfg_wnd vim.api.keyset.win_config
---@field cfg_foo vim.api.keyset.win_config
---@field footer_text string: already cut to the window width

--- Build main and footer window configurations
---@param bufnr number: buffer the window will show
---@return scratch.WinConfig
local function make_config(bufnr)
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

    local chrome = describe(bufnr)

    -- The footer window is sized by its text, so a long hint list would hang
    -- off the screen on a narrow terminal. One column goes to the leading
    -- space update_footer adds.
    local footer_text = chrome.footer
    if #footer_text + 1 > width then
        footer_text = footer_text:sub(1, width - 1)
    end

    local cfg_wnd = {
        relative = "editor",
        border = config.border,
        style = "minimal",
        zindex = 50,
        title = chrome.title,
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

    return { cfg_wnd = cfg_wnd, cfg_foo = cfg_foo, footer_text = footer_text }
end

--- Apply the user's window-local options. Needed after every open or
--- set_config, because style = "minimal" resets them to defaults.
---@param winnr number
local function apply_win_opts(winnr)
    for opt, val in pairs(config.win_opts) do
        vim.wo[winnr][opt] = val
    end
end

local function footer_buffer()
    if state.foo_bufnr and vim.api.nvim_buf_is_valid(state.foo_bufnr) then
        return state.foo_bufnr
    end
    state.foo_bufnr = vim.api.nvim_create_buf(false, true)
    return state.foo_bufnr
end

---@param text string: as sized by make_config, so window and contents agree
local function draw_footer(text)
    vim.api.nvim_buf_set_lines(footer_buffer(), 0, -1, false, { " " .. text })
end

-- ── cursor ──────────────────────────────────────────────────────────

--- Remember where the cursor stands in whatever is on screen
function M.remember_cursor()
    if not M.is_open() then
        return
    end

    local key = describe(vim.api.nvim_win_get_buf(state.winnr)).cursor_key
    if key then
        state.cursors[key] = vim.api.nvim_win_get_cursor(state.winnr)
    end
end

--- Put the cursor back where this content was left, clamped to the buffer.
--- Called by the window itself whenever it changes what it shows, so no
--- caller has to remember to do it - forgetting once loses the position for
--- that path only, which is exactly how it went unnoticed before.
function M.restore_cursor()
    if not M.is_open() then
        return
    end

    local bufnr = vim.api.nvim_win_get_buf(state.winnr)
    local chrome = describe(bufnr)
    local pos = chrome.cursor_key and state.cursors[chrome.cursor_key]

    if pos == nil and chrome.cursor_home == nil then
        return
    end

    pos = pos or { chrome.cursor_home, 0 }
    local last = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, state.winnr, { math.min(pos[1], math.max(last, 1)), pos[2] })
end

--- Forget the remembered position of a piece of content
---@param key string
function M.forget_cursor(key)
    state.cursors[key] = nil
end

-- ── window ──────────────────────────────────────────────────────────

---@return boolean
function M.is_open()
    return state.winnr ~= nil and vim.api.nvim_win_is_valid(state.winnr)
end

---@return number|nil
function M.current_buf()
    if not M.is_open() then
        return nil
    end
    return vim.api.nvim_win_get_buf(state.winnr)
end

--- Repaint title and footer after a buffer swap, a scope change or a resize
function M.update()
    if not M.is_open() then
        return
    end

    local cfg = make_config(vim.api.nvim_win_get_buf(state.winnr))
    vim.api.nvim_win_set_config(state.winnr, cfg.cfg_wnd)
    apply_win_opts(state.winnr)

    draw_footer(cfg.footer_text)
    if state.foonr and vim.api.nvim_win_is_valid(state.foonr) then
        vim.api.nvim_win_set_config(state.foonr, cfg.cfg_foo)
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

local augroup = vim.api.nvim_create_augroup("scratch.nvim", { clear = true })

--- Open the window on a buffer
---@param bufnr number
function M.open(bufnr)
    local cfg = make_config(bufnr)
    state.prev_winnr = vim.api.nvim_get_current_win()

    state.winnr = vim.api.nvim_open_win(bufnr, true, cfg.cfg_wnd)
    apply_win_opts(state.winnr)
    M.restore_cursor()

    draw_footer(cfg.footer_text)
    state.foonr = vim.api.nvim_open_win(footer_buffer(), false, cfg.cfg_foo)

    vim.api.nvim_clear_autocmds({ group = augroup })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        pattern = tostring(state.winnr),
        once = true,
        callback = function()
            M.close()
        end,
    })

    -- Leaving the window, not the buffer: swapping buffers inside it is not
    -- leaving, which is what makes jumping between our buffers possible
    if config.close_on_leave then
        vim.api.nvim_create_autocmd("WinLeave", {
            group = augroup,
            callback = function()
                if M.is_open() and vim.api.nvim_get_current_win() == state.winnr then
                    M.close()
                end
            end,
        })
    end

    vim.api.nvim_create_autocmd("VimResized", {
        group = augroup,
        callback = function()
            M.update()
        end,
    })

    -- The chrome follows whatever ends up on screen, including a jump with
    -- C-o. A buffer that is none of ours does not belong here at all.
    vim.api.nvim_create_autocmd("BufEnter", {
        group = augroup,
        callback = function()
            if not M.is_open() or vim.api.nvim_get_current_win() ~= state.winnr then
                return
            end

            local shown = vim.api.nvim_get_current_buf()
            if describe(shown).kind == "foreign" then
                evacuate(shown)
            else
                M.update()
            end
        end,
    })
end

--- Show a buffer: open the window if closed, focus it if the focus is
--- elsewhere, swap to the buffer if something else is on screen, and close if
--- that kind is already in front.
---@param kind string
---@param get_buffer function: called only when a buffer is actually needed
function M.show(kind, get_buffer)
    if not M.is_open() then
        M.open(get_buffer())
        return
    end

    if describe(vim.api.nvim_win_get_buf(state.winnr)).kind == kind then
        if state.winnr == vim.api.nvim_get_current_win() then
            M.close()
        else
            vim.api.nvim_set_current_win(state.winnr)
        end
        return
    end

    M.remember_cursor()
    vim.api.nvim_win_set_buf(state.winnr, get_buffer())
    vim.api.nvim_set_current_win(state.winnr)
    M.update()
    M.restore_cursor()
end

--- Put a buffer on screen, opening the window if needed
---@param bufnr number
function M.swap_to(bufnr)
    if M.is_open() then
        M.remember_cursor()
        vim.api.nvim_set_current_win(state.winnr)
        vim.api.nvim_win_set_buf(state.winnr, bufnr)
    else
        M.open(bufnr)
    end
    M.update()
    M.restore_cursor()
end

--- Close the window and its footer
function M.close()
    if state.closing then
        return
    end
    state.closing = true

    M.remember_cursor()

    pcall(vim.api.nvim_win_close, state.winnr, true)
    state.winnr = nil

    pcall(vim.api.nvim_win_close, state.foonr, true)
    state.foonr = nil

    vim.api.nvim_clear_autocmds({ group = augroup })

    state.closing = false

    if on_close then
        on_close()
    end
end

return M
