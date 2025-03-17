local M = {}

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

local prop = {
    title = " Scratch ",
    width = 0.6,
    height = 0.6,

    bufnr = nil,

    winnr = nil,
    footernr = nil,
}

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

local function createWindow()
    local config = make_window_config()

    -- main window
    prop.winnr = vim.api.nvim_open_win(prop.bufnr, true, config)

    -- footer window
    local footer_buf = vim.api.nvim_create_buf(false, true)
    local footer_text = " 'q' to close, 'R' to reset "
    vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, { footer_text })

    prop.footernr = vim.api.nvim_open_win(footer_buf, false, {
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

    -- lock the window to the buffer
    -- unfortunately, this interferes with the fzf-lua
    -- fzf-lua opens buffer in the new created split
    -- vim.wo.winfixbuf = true

    -- lock the window to the buffer
    vim.api.nvim_create_autocmd("BufEnter", {
        group = vim.api.nvim_create_augroup("scratch.nvim", { clear = true }),
        callback = function(event)
            local win = vim.api.nvim_get_current_win()
            local buf = vim.api.nvim_win_get_buf(win)

            if win == prop.winnr and buf ~= prop.bufnr then
                vim.schedule(function()
                    vim.api.nvim_set_current_buf(prop.bufnr)
                    -- vim.notify("This window is locked to a scratch buffer!", vim.log.levels.WARN)
                end)
            end
        end,
    })
end

M.toggle = function()
    if prop.winnr == nil or not vim.api.nvim_win_is_valid(prop.winnr) then
        createWindow()

        -- vim.notify("Create Win: " .. prop.winnr .. ", buf: " .. prop.bufnr)
    else
        if prop.winnr == vim.api.nvim_get_current_win() then
            -- If current window is visible, hide it
            M.close()

            -- vim.notify("Hide Win: " .. prop.winnr .. ", buf: " .. prop.bufnr)
        else
            -- Set focus on the floating window
            vim.api.nvim_set_current_win(prop.winnr)
            vim.wo.cursorline = false

            -- vim.notify("Show Win: " .. prop.winnr .. ", buf: " .. prop.bufnr)
        end
    end
end

M.close = function()
    vim.api.nvim_win_hide(prop.winnr)
    vim.api.nvim_win_hide(prop.footernr)
end

M.reset = function()
    vim.api.nvim_buf_set_lines(prop.bufnr, 0, -1, false, {})
end

-- create a new empty buffer
local function createBuffer()
    local bufnr = vim.api.nvim_create_buf(false, false)

    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].filetype = "markdown"
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].bufhidden = "hide"

    return bufnr
end

function M.setup(opts)
    opts = opts or {}
    M.config.title = opts.title or prop.title
    M.config.border = opts.border or M.config.border
    prop.width = opts.width or prop.width
    prop.height = opts.height or prop.height

    prop.bufnr = createBuffer()

    -- Merge the provided options with the default configuration
    -- opts = vim.tbl_deep_extend("force", M.config, opts)

    -- Enable Treesitter highlighting for the buffer
    vim.treesitter.start(prop.bufnr, "markdown")

    -- Bind commands to our lua functions
    vim.api.nvim_create_user_command("ScratchToggle", M.toggle, {})
    vim.api.nvim_create_user_command("ScratchReset", M.reset, {})
    vim.api.nvim_create_user_command("ScratchClose", M.close, {})

    vim.api.nvim_buf_set_keymap(
        prop.bufnr,
        "n",
        "q",
        "<cmd>ScratchClose<cr>",
        { noremap = true, silent = true }
    )

    vim.api.nvim_buf_set_keymap(
        prop.bufnr,
        "n",
        "R",
        "<cmd>ScratchReset<cr>",
        { noremap = true, silent = true }
    )
end

return M
