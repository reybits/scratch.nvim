# Neovim Scratch Buffer

A Neovim plugin for quick scratch notes in a floating window. Supports
three note types: temporary (in-memory), local (per-project, saved to disk),
and global (shared across projects, saved to disk). Switch between them with
`Tab`/`S-Tab`.

![scratch.nvim](https://github.com/user-attachments/assets/a409f547-12ec-4d5b-b395-b4de8d51fae9)

## Features

- Floating scratch window with markdown and Treesitter highlighting.
- **Temporary notes** — in-memory, never written to disk.
- **Local notes** — persisted per-project (`.scratch.md` at the git root).
- **Global notes** — persisted across projects (`stdpath("data")/scratch.nvim/global.md`).
- Cycle between note types with `Tab` / `S-Tab`.
- Notes auto-save on close, type switch, and `VimLeavePre`.
- Configurable window size, border, title, and behavior.

## Installation

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

## Configuration

Default options:

```lua
opts = {
    title = "Scratch",
    border = "rounded",
    width = 0.6,
    height = 0.6,

    -- enable per-project notes
    local_notes = true,

    -- enable global notes
    global_notes = true,

    -- filename for local notes
    local_notes_file = ".scratch.md",

    -- close window when leaving the buffer
    close_on_leave = true,

    -- window-local options (vim.wo)
    win_opts = {
        wrap = true,
    },
}
```

Set `local_notes = false` or `global_notes = false` to disable a note type.
When only one type is enabled, the type label and switch keymaps are hidden.

`win_opts` accepts any `vim.wo` option. For example:

```lua
opts = {
    win_opts = {
        wrap = true,
        linebreak = true,
        number = true,
    },
}
```

## Usage

### Commands

- `:ScratchToggle` — Open or close the scratch window.

### Keymaps (inside the scratch window)

| Key       | Action                        |
|-----------|-------------------------------|
| `q`       | Close the scratch window      |
| `R`       | Reset (clear) the current note|
| `Tab`     | Switch to next note type      |
| `S-Tab`   | Switch to previous note type  |

### Lua API

- `require('scratch').toggle()` — Toggle the scratch window.
- `require('scratch').close()` — Close the scratch window.
- `require('scratch').reset()` — Clear the current note buffer.
- `require('scratch').next_type()` — Switch to the next note type.
- `require('scratch').prev_type()` — Switch to the previous note type.

## License

[MIT License](LICENSE)

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.
