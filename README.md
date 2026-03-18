# neorg-nabla

Render LaTeX in [Neorg](https://github.com/nvim-neorg/neorg) documents using
[nabla.nvim](https://github.com/jbyuki/nabla.nvim) – an ASCII-art LaTeX renderer that
requires no external binaries or image protocol support.

## Features

- Renders **inline math** (`$...$` / `$|...|$`) by replacing each character with the
  corresponding ASCII-art character (nabla-style concealment).
- Renders **`@math` display blocks** as virtual lines placed directly below the
  `@math` tag.
- Debounced re-render on text changes and insert-leave, keeping editing smooth.
- `:Neorg nabla toggle / enable / disable` commands.

## Requirements

- [Neorg](https://github.com/nvim-neorg/neorg) with tree-sitter-norg parser installed
- [nabla.nvim](https://github.com/jbyuki/nabla.nvim)

## Installation

### lazy.nvim

```lua
{
    "nvim-neorg/neorg",
    dependencies = {
        { "brglng/neorg-nabla", dependencies = { "jbyuki/nabla.nvim" } },
    },
    config = function()
        require("neorg").setup({
            load = {
                ["core.defaults"] = {},
                ["core.concealer"] = {},
                -- ... other modules ...
                ["external.nabla"] = {
                    config = {
                        -- Render automatically when opening a .norg file (default: false)
                        render_on_enter = false,
                        -- Milliseconds to wait after the last edit before re-rendering (default: 200)
                        debounce_ms = 200,
                    },
                },
            },
        })
    end,
},
```

## Usage

| Command | Description |
|---|---|
| `:Neorg nabla enable` | Start rendering LaTeX in the current buffer |
| `:Neorg nabla disable` | Stop rendering and clear all virtual text |
| `:Neorg nabla toggle` | Toggle rendering on/off |

### Inline math

Neorg has two inline-math syntaxes:

| Syntax | Meaning |
|---|---|
| `$...$` | Neorg-escaped math – backslash is Neorg's escape character, **not** a LaTeX prefix.  Useful for simple expressions like `$x^2$`. |
| `$\|...\|$` | Verbatim LaTeX – full LaTeX syntax, backslash works as normal. Use this for `\frac`, `\int`, Greek letters, etc. |

```norg
$x^2 + y^2 = z^2$

$|\frac{a}{b} + \frac{c}{d}|$
```

### Math blocks

```norg
@math
\frac{\partial f}{\partial x} = \lim_{h \to 0} \frac{f(x+h) - f(x)}{h}
@end
```

### Conceal level

The inline-math ASCII overlay uses Neovim's *conceal* mechanism.
Set `conceallevel = 2` in your norg windows for the rendering to take full effect:

```lua
vim.api.nvim_create_autocmd("FileType", {
    pattern = "norg",
    callback = function()
        vim.opt_local.conceallevel = 2
        vim.opt_local.concealcursor = "nc"
    end,
})
```

## How it works

1. `core.integrations.treesitter` is used to locate `inline_math` nodes and
   `ranged_verbatim_tag` nodes whose `tag_name` is `"math"`.
2. The LaTeX content is extracted (stripping Neorg markers / unescaping where
   needed) and passed to nabla.nvim's internal parser and ASCII renderer.
3. For inline math, the formula characters are replaced one-by-one with the
   corresponding ASCII-art characters using Neovim extmark concealment, and
   extra rows of the drawing are placed as `virt_lines_above` / `virt_lines`.
4. For `@math` blocks the drawing is placed as `virt_lines` after the tag line
   and the raw LaTeX content lines are concealed.  When the cursor moves inside
   a math block the baseline overlay and content concealment are removed so the
   original source is visible, while the virtual lines above/below are kept.
