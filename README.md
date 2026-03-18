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
                        -- Conceal the @math and @end tag lines when conceallevel >= 2 (default: false)
                        conceal_math_tags = false,
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

