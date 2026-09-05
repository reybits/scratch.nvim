# Neovim Scratch Buffer

A Neovim plugin for quick scratch notes in a floating window. Supports
three note types: temporary (in-memory), local (per-project, saved to disk),
and global (shared across projects, saved to disk). Switch between them with
`S-Tab`.

Alongside free-form notes it keeps lightweight issues: plain markdown files
with a few metadata fields, shown as a sortable list in the same window.

![scratch.nvim](https://github.com/user-attachments/assets/a409f547-12ec-4d5b-b395-b4de8d51fae9)

## Features

- Floating scratch window with markdown and Treesitter highlighting.
- **Temporary notes** — in-memory, never written to disk.
- **Local notes** — persisted per-project (`.scratch.md` at the git root).
- **Global notes** — persisted across projects (`stdpath("data")/scratch.nvim/global.md`).
- Cycle between note types with `S-Tab`.
- Notes auto-save on close, type switch, and `VimLeavePre`.
- An empty note keeps no file on disk: the file appears once the note has
  content and is removed when the note is cleared.
- **Issues** — one markdown file per issue, local to a project or global,
  listed in the same window and opened as ordinary file buffers.
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
        linebreak = true,
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

- `:ScratchToggle` — Show the note in the scratch window, or close the window
  if the note is already in front.
- `:ScratchIssues` — Same for the issue list. Either command swaps the window
  to what it names, so `:ScratchIssues` on an open note shows the list rather
  than closing anything.
- `:ScratchTask [title]` — Create an issue in the current project and open it.
  With `!` the issue goes to the global scope instead. Without a title, one is
  asked for.

### Keymaps (inside the scratch window)

| Key       | Action                        |
|-----------|-------------------------------|
| `q`       | Close the scratch window      |
| `R`       | Reset (clear) the current note|
| `S-Tab`   | Switch to next note type      |

### Keymaps (inside the issue list)

| Key       | Action                        |
|-----------|-------------------------------|
| `q`       | Close the scratch window      |
| `CR`      | Open the issue under the cursor|
| `S-Tab`   | Switch between local and global|
| `T`       | Cycle type: bug, feature, task|
| `P`       | Cycle priority: low, normal, high, critical|
| `S`       | Toggle status: open, done     |

`Tab` is deliberately left alone: it is the same keycode as `C-i`, and mapping
it would break jumping forward through the jumplist.

An issue opens as an ordinary file buffer, so `:w`, undo and `C-o`/`C-i`
between the list and the issue behave as they do anywhere else. Issue buffers
are kept out of the buffer list, like the note buffers.

A jump can also land on a file that has nothing to do with notes or issues
(`gF` from an issue into the code, `C-o` further back, `gd`). Such a file is
never left inside the floating window: it is handed to a normal window, and
the scratch window closes.

### Lua API

- `require('scratch').toggle()` — Toggle the scratch window.
- `require('scratch').close()` — Close the scratch window.
- `require('scratch').reset()` — Clear the current note buffer.
- `require('scratch').next_type()` — Switch to the next note type.
- `require('scratch').prev_type()` — Switch to the previous note type.
- `require('scratch').issues()` — Toggle the issue list.
- `require('scratch').task(scope, title)` — Create an issue in `"local"` or
  `"global"` scope.

## Issues

Every issue is one markdown file. Local issues live in `.scratch/issues/` at
the git root, global ones in `stdpath("data")/scratch.nvim/issues/`. The file
name is the creation time, so the store needs no counter and the directory
sorts chronologically on its own.

```markdown
---
type: bug
priority: high
status: open
---

# Parser drops the last line of a file

src/parser.c:412

Free-form markdown below the title.
```

- `type` — `bug`, `feature` or `task`
- `priority` — `low`, `normal`, `high` or `critical`
- `status` — `open` or `done`

Only these fields and the first `#` heading are read; everything else in the
file is left alone. Missing fields fall back to `task`, `normal` and `open`,
so a file written by hand still shows up in the list. Fields can be changed
from the list with `T`, `P` and `S`, which rewrite that one frontmatter line
and leave the rest of the file alone, or by editing the file by hand. The list
is re-read whenever it is entered.

The list shows open issues, newest first, with a checkbox-style mark for
closed ones. Sorting and filtering are properties of the view and never
rewrite the files.

```text
    Type     Priority  Created     Description
    BUG      HIGH      2026-09-06  Parser drops the last line of a file
  x TASK     NORMAL    2026-09-05  Update the build image
```

The column header uses the `ScratchIssuesHeader` group, bold by default.
Redefine it to taste, for example:

```lua
vim.api.nvim_set_hl(0, "ScratchIssuesHeader", { link = "Title" })
```

Changing a field repaints only its own row: the filter is applied when the
list is built, not while you are working in it. So closing an issue leaves it
in place, marked, and it disappears the next time the list is entered — the
key never lands on a different issue than the one under the cursor.

A path with a line number, like `src/parser.c:412`, is what `gF` already
understands, so it doubles as a jump back into the code.

`:ScratchTask` reads the line under the cursor: if it is a todo comment, its
keyword sets the type (`BUG`, `FIXME`, `ISSUE` give `bug`; `TODO`, `HACK`,
`PERF` give `task`) and its text seeds the title. The location of the cursor is
written into the body. The scoped form `BUG(ref):` is recognised as well; note
that [todo-comments.nvim](https://github.com/folke/todo-comments.nvim) does not
highlight that form with its default `search.pattern` and `highlight.pattern`.

## License

[MIT License](LICENSE)

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.
