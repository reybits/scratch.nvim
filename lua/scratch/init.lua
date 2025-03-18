local M = {}

--- Default window configuration
---@class vim.api.keyset.win_config
M.config = {
    title_pos = "center",
    relative = "editor",
    border = "rounded",
    width = 1,
    height = 1,
    row = 1,
    col = 1,
    style = "minimal",
    zindex = 50,
}

--- User configuration
---@class scratch.Prop
local prop = {
    title = " Scratch ",
    width = 0.6,
    height = 0.6,
    border = "rounded",
}

local footer_text = " 'q' to close, 'R' to reset "

--- Make the window configuration
--- @return table: A table containing the main and footer window configurations
local function make_window_config()
    -- main body window configuration
    local cfg_wnd = vim.tbl_deep_extend("force", {}, M.config)

    if prop.width <= 1.0 then
        cfg_wnd.width = math.floor(prop.width * vim.o.columns)
    else
        cfg_wnd.width = math.floor(prop.width)
    end

    cfg_wnd.col = math.floor((vim.o.columns - cfg_wnd.width) / 2)

    if prop.height <= 1.0 then
        cfg_wnd.height = math.floor(prop.height * vim.o.lines)
    else
        cfg_wnd.height = math.floor(prop.height)
    end

    cfg_wnd.row = math.floor((vim.o.lines - cfg_wnd.height) / 2)

    -- footer window configuration

    local cfg_foo = vim.tbl_deep_extend("force", {}, M.config)

    cfg_foo.width = #footer_text + 2
    cfg_foo.height = 1
    cfg_foo.row = cfg_wnd.row + cfg_wnd.height + 1
    cfg_foo.col = cfg_wnd.col + math.floor((cfg_wnd.width - #footer_text) / 2)
    -- cfg_foo.style = "minimal"
    cfg_foo.border = "none"
    cfg_foo.zindex = cfg_wnd.zindex + 1
    cfg_foo.focusable = false

    return {
        cfg_wnd = cfg_wnd,
        cfg_foo = cfg_foo,
    }
end

--- Internal window state
---@class scratch.Wnd
---@field bufnr number|nil: number of the scratch buffer
---@field winnr number|nil: number of the scratch window
---@field foonr number|nil: number of the footer window
local wnd = {
    bufnr = nil,

    winnr = nil,
    foonr = nil,
}

--- Create a new empty buffer
---@eturn number scratch buffer number
local function create_empty_buffer()
    local bufnr = vim.api.nvim_create_buf(false, true)

    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].filetype = "markdown"
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].bufhidden = "hide"

    -- Enable Treesitter highlighting for the buffer
    vim.treesitter.start(bufnr, "markdown")

    -- TODO: Disable the buffer deletion

    return bufnr
end

--- Create a new scratch Window
---@param config table: vim.api.keyset.win_config
local function create_floating_window(config)
    -- print(vim.inspect(config))

    -- main window
    wnd.winnr = vim.api.nvim_open_win(wnd.bufnr, true, config.cfg_wnd)

    -- footer window
    local footer_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, { footer_text })

    if wnd.foonr == nil or not vim.api.nvim_win_is_valid(wnd.foonr) then
        wnd.foonr = vim.api.nvim_open_win(footer_buf, false, config.cfg_foo)
    end

    -- lock the window to the buffer
    -- unfortunately, this interferes with the fzf-lua
    -- fzf-lua opens buffer in the new created split
    -- vim.wo.winfixbuf = true

    -- lock the window to the buffer
    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = wnd.bufnr,
        callback = function()
            -- local win = vim.api.nvim_get_current_win()
            -- local buf = vim.api.nvim_win_get_buf(win)
            --
            -- if win == wnd.winnr and buf ~= wnd.bufnr then
            vim.schedule(function()
                vim.api.nvim_set_current_buf(wnd.bufnr)
                -- vim.notify("This window is locked to a scratch buffer!", vim.log.levels.WARN)
            end)
            -- end
        end,
    })

    -- handle uloading the buffer (ex. :quit)
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = wnd.bufnr,
        callback = function()
            M.close()
        end,
    })

    -- handle uloading the buffer (ex. :bd, :bw)
    vim.api.nvim_create_autocmd("BufUnload", {
        buffer = wnd.bufnr,
        callback = function()
            M.close()
            wnd.bufnr = nil
        end,
    })

    vim.api.nvim_create_autocmd("VimResized", {
        group = vim.api.nvim_create_augroup("scratch.nvim-resize", {}),
        buffer = wnd.bufnr,
        callback = function()
            if wnd.winnr == nil or not vim.api.nvim_win_is_valid(wnd.winnr) then
                return
            end
            if wnd.foonr == nil or not vim.api.nvim_win_is_valid(wnd.foonr) then
                return
            end

            local cfg = make_window_config()
            vim.api.nvim_win_set_config(wnd.winnr, cfg.cfg_wnd)
            vim.api.nvim_win_set_config(wnd.foonr, cfg.cfg_foo)
        end,
    })
end

-- Toggle the visibility of the floating window
M.toggle = function()
    if wnd.bufnr == nil or not vim.api.nvim_buf_is_valid(wnd.bufnr) then
        wnd.bufnr = create_empty_buffer()
    end

    if wnd.winnr == nil or not vim.api.nvim_win_is_valid(wnd.winnr) then
        local cfg = make_window_config()
        create_floating_window(cfg)

        -- vim.notify("Create Win: " .. wnd.winnr .. ", buf: " .. wnd.bufnr)
    else
        if wnd.winnr == vim.api.nvim_get_current_win() then
            -- If current window is visible, hide it
            pcall(vim.api.nvim_win_hide, wnd.winnr, true)
            if wnd.winnr ~= nil and vim.api.nvim_win_is_valid(wnd.winnr) then
                vim.api.nvim_win_hide(wnd.winnr)
            end

            if wnd.foonr ~= nil and vim.api.nvim_win_is_valid(wnd.foonr) then
                vim.api.nvim_win_hide(wnd.foonr)
            end

            -- vim.notify("Hide Win: " .. wnd.winnr .. ", buf: " .. wnd.bufnr)
        else
            -- Set focus on the floating window
            vim.api.nvim_set_current_win(wnd.winnr)
            vim.wo.cursorline = false

            -- vim.notify("Show Win: " .. wnd.winnr .. ", buf: " .. wnd.bufnr)
        end
    end
end

--- Close the floating window
M.close = function()
    pcall(vim.api.nvim_win_close, wnd.winnr, true)
    wnd.winnr = nil
    pcall(vim.api.nvim_win_close, wnd.foonr, true)
    wnd.foonr = nil
end

--- Reset the buffer content
M.reset = function()
    vim.api.nvim_buf_set_lines(wnd.bufnr, 0, -1, false, {})
end

--- Setup the plugin
---@param opts scratch.Prop
function M.setup(opts)
    opts = opts or {}
    M.config.title = opts.title or prop.title
    M.config.border = opts.border or M.config.border
    prop.width = opts.width or prop.width
    prop.height = opts.height or prop.height

    -- Merge the provided options with the default configuration
    -- opts = vim.tbl_deep_extend("force", M.config, opts)

    -- Bind commands to our lua functions
    vim.api.nvim_create_user_command("ScratchToggle", M.toggle, {})

    vim.keymap.set("n", "q", function()
        M.close()
    end, { buffer = wnd.bufnr, noremap = true, silent = true })

    vim.keymap.set("n", "R", function()
        M.reset()
    end, { buffer = wnd.bufnr, noremap = true, silent = true })
end

return M
