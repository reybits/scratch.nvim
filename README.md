# Neovim Scratch Buffer

This plugin provides a simple way to work with scratch buffers in Neovim.
It opens a floating window for temporary notes or edits and does not save
anything to disk. You can quickly open a scratch buffer without affecting
your current workspace. Additionally, the plugin allows customization of
the buffer’s default name and appearance.

![scratch.nvim](https://github.com/user-attachments/assets/89a154a0-96d7-4a04-916e-0ca8883f8a03)

## Features:

- Open a scratch buffer in a floating window for quick edits.
- Customize the default name, appearance, and behavior of the scratch buffer.
- The scratch buffer is purely temporary and does not save to disk.
- No interference with existing buffers or files, keeping your workspace clean.
- Markdow support for rich text editing.

## Installation

To install this plugin, you can use your favorite Neovim package manager. For example:

### [Lazy](https://github.com/folke/lazy.nvim)

```lua
{
    "reybits/scratch.nvim",
    lazy = true,
    keys = {
        { "<leader>ts", "<cmd>ScratchToggle<cr>", desc = "Toggle Scratch Buffer" },
    },
    cmd = {
        "ScratchToggle",
    },
    opts = {},
}
```

### Configuring

The default configuration options are listed below:

```lua
opts = {
    title = " Scratch ",
    border = "rounded",
    width = 0.8,
    height = 0.8,
}
```

## Usage

### Commands

The plugin provides two commands:

- `:ScratchToggle` — Opens or Closes scratch buffer.

### Lua Functions

You can also use the plugin's Lua functions directly:

- `require('scratch').toggle()` — Equivalent to `:ScratchToggle`.

## License

[MIT License](LICENSE)

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.
