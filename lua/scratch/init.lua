local M = {}

M.config = {
	title = " Scratch ",
	relative = "editor",
	width = 60,
	height = 40,
	-- row = 5,
	-- col = 10,
	style = "minimal",
	border = "rounded",
}

local function is_buffer_modified()
	local buf = vim.api.nvim_get_current_buf()
	return vim.api.nvim_get_option_value("modified", { buf = buf })
end

local floating_win = nil

M.toggle = function()
	if floating_win == nil or not vim.api.nvim_win_is_valid(floating_win) then
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

	-- Merge the provided options with the default configuration
	vim.tbl_deep_extend("force", M.config, opts)

	-- Bind commands to our lua functions
	vim.api.nvim_create_user_command("ScratchToggle", M.toggle, {})
end

return M
