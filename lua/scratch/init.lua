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

--- Make the window configuration
---@return vim.api.keyset.win_config
local function make_window_config()
    local config = M.config

    if prop.width <= 1.0 then
        config.width = math.floor(prop.width * vim.o.columns)
    else
        config.width = math.floor(prop.width)
    end

    config.col = math.floor((vim.o.columns - config.width) / 2)

    if prop.height <= 1.0 then
        config.height = math.floor(prop.height * vim.o.lines)
    else
        config.height = math.floor(prop.height)
    end

    config.row = math.floor((vim.o.lines - config.height) / 2)

    return config
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
---@param config vim.api.keyset.win_config
local function create_floating_window(config)
    -- main window
    wnd.winnr = vim.api.nvim_open_win(wnd.bufnr, true, config)

    -- footer window
    local footer_buf = vim.api.nvim_create_buf(false, true)
    local footer_text = " 'q' to close, 'R' to reset "
    vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, { footer_text })

    if wnd.foonr == nil or not vim.api.nvim_win_is_valid(wnd.foonr) then
        wnd.foonr = vim.api.nvim_open_win(footer_buf, false, {
            relative = "editor",
            width = #footer_text + 2,
            height = 1,
            row = config.row + config.height + 1,
            col = config.col + math.floor((config.width - #footer_text) / 2),
            style = "minimal",
            border = "none",
            zindex = config.zindex + 1,
            focusable = false, -- Футер нельзя выбрать
        })
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

    vim.api.nvim_create_autocmd("BufUnload", {
        buffer = wnd.bufnr,
        callback = function()
            M.close()
            wnd.bufnr = nil
        end,
    })
end

-- Toggle the visibility of the floating window
M.toggle = function()
    if wnd.bufnr == nil or not vim.api.nvim_buf_is_valid(wnd.bufnr) then
        wnd.bufnr = create_empty_buffer()
    end

    if wnd.winnr == nil or not vim.api.nvim_win_is_valid(wnd.winnr) then
        local config = make_window_config()
        create_floating_window(config)

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
