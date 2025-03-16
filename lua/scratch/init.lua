local M = {}

M.config = {
	title = " Scratch ",
	relative = "editor",
	width = 1,
	height = 1,
	row = 1,
	col = 1,
	style = "minimal",
	border = "rounded",
}

local win_property = {
	width = 0.8,
	height = 0.8,
}

local function is_buffer_modified()
	local buf = vim.api.nvim_get_current_buf()
	return vim.api.nvim_get_option_value("modified", { buf = buf })
end

local floating_win = nil

M.toggle = function()
	if floating_win == nil or not vim.api.nvim_win_is_valid(floating_win) then
		M.config.width = math.floor(win_property.width * vim.o.columns)
		M.config.height = math.floor(win_property.height * vim.o.lines)
		M.config.col = math.floor((vim.o.columns - M.config.width) / 2)
		M.config.row = math.floor((vim.o.lines - M.config.height) / 2)

		-- Create a new floating window if it does not exist
		local buf = vim.api.nvim_create_buf(false, true) -- create a new empty buffer
		floating_win = vim.api.nvim_open_win(buf, true, M.config)
	else
		-- If the window exists, check its visibility and hide/show it
		local win_config = vim.api.nvim_win_get_config(floating_win)
		if win_config.relative ~= "" then
			local modified = is_buffer_modified()
			if modified then
				-- store buffer content
				local _ = ""
			end

			-- If the window is visible, hide it
			vim.api.nvim_win_set_config(floating_win, { relative = "" })
		else
			-- If the window is hidden, show it
			vim.api.nvim_win_set_config(floating_win, M.config)
		end
	end
end

function M.setup(opts)
	opts = opts or {}
	M.config.title = opts.title or M.config.title
	win_property.width = opts.width or 0.8
	win_property.height = opts.height or 0.8

	-- Merge the provided options with the default configuration
	-- opts = vim.tbl_deep_extend("force", M.config, opts)

	-- Bind commands to our lua functions
	vim.api.nvim_create_user_command("ScratchToggle", M.toggle, {})
end

return M
