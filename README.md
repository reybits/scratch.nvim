# Neovim Scratch Buffer

> WARNING: This plugin is still in development and may not be stable!

This plugin provides an easy way to work with scratch buffers in Neovim. It
allows you to quickly open a scratch buffer in your current window or in a new
split window. The plugin also offers the flexibility to configure the default
name and appearance of the scratch buffer.

## Features:

- Open a scratch buffer in a floating window.
- Automatically switch to an existing scratch buffer if it already exists.
- Configure default options for the scratch buffer.
- The scratch buffer acts as a temporary workspace and is not backed by a file.

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
