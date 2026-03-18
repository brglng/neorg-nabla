--[[
    file: external.nabla
    title: Render LaTeX in Neorg using nabla.nvim
    summary: Renders LaTeX expressions in Neorg documents using nabla.nvim for ASCII art rendering.
    ---

Renders inline math (`$...$` / `$|...|$`) and math blocks (`@math`) in Neorg documents
using nabla.nvim to produce ASCII-art representations.

Toggle rendering with `:Neorg nabla toggle` (or `enable` / `disable`).

For the character-by-character inline concealment to take effect you need
`conceallevel >= 2` in your norg windows (nabla sets this automatically; this
module leaves it to the user so that other Neorg conceal features are not
disturbed).

Requires:
- [nabla.nvim](https://github.com/jbyuki/nabla.nvim) – the ASCII-art LaTeX renderer.
--]]

local neorg = require("neorg.core")
local modules = neorg.modules

local module = modules.create("external.nabla")

-- ─── module bookkeeping ───────────────────────────────────────────────────────

module.setup = function()
    return {
        success = true,
        requires = {
            "core.integrations.treesitter",
            "core.autocommands",
            "core.neorgcmd",
        },
    }
end

module.config.public = {
    --- When true, rendering is enabled automatically when a `.norg` buffer is entered.
    render_on_enter = false,

    --- Milliseconds to wait after the last text change before re-rendering.
    debounce_ms = 200,
}

module.private = {
    --- Extmark namespace used for all virtual text placed by this module.
    ns = nil,

    --- Whether rendering is currently active.
    do_render = false,

    --- Per-buffer debounce timer handles.
    render_timers = {},

    --- Per-buffer list of formula row ranges: { {start_row, end_row}, ... }
    --- Used to detect whether the cursor is inside a formula region.
    formula_ranges = {},

    --- Per-buffer last cursor row (0-indexed) seen by the cursor-move handler.
    last_cursor_row = {},

    --- Autocommand group id for cursor tracking.
    aug = nil,
}

-- ─── helpers ──────────────────────────────────────────────────────────────────

--- Build a virt-line list `{{char, hl}, ...}` from a plain string.
local function make_virt_line(str, hl)
    hl = hl or "Normal"
    local vl = {}
    local n = vim.str_utfindex(str)
    for i = 1, n do
        local a = vim.str_byteindex(str, i - 1)
        local b = vim.str_byteindex(str, i)
        table.insert(vl, { str:sub(a + 1, b), hl })
    end
    return vl
end

--- Place one conceal extmark per byte of the formula range `[scol, scol+width)`.
--- `chars` is an array of replacement strings indexed 1-based; bytes beyond
--- `#chars` are concealed with an empty string (hidden).
local function place_conceal_extmarks(buf, ns, row, scol, width, chars)
    for j = 1, width do
        vim.api.nvim_buf_set_extmark(buf, ns, row, scol + j - 1, {
            end_row = row,
            end_col = scol + j,
            conceal = chars[j] or "",
            strict = false,
            undo_restore = false,
            invalidate = true,
        })
    end
end

--- Parse the LaTeX `content` with nabla and return the ASCII drawing table,
--- or `nil` on any failure.  Errors are swallowed so bad formulas are silently
--- skipped.
local function gen_drawing(content)
    local ok1, latex_parser = pcall(require, "nabla.latex")
    local ok2, ascii_mod = pcall(require, "nabla.ascii")
    if not ok1 or not ok2 then
        vim.notify_once(
            "neorg-nabla: nabla.nvim is not installed or could not be loaded",
            vim.log.levels.WARN
        )
        return nil
    end

    local ok3, exp = pcall(latex_parser.parse_all, content)
    if not ok3 or not exp then
        return nil
    end

    local ok4, g = pcall(ascii_mod.to_ascii, { exp }, 1)
    if not ok4 or not g or g == "" then
        return nil
    end

    -- tostring(g) is the multi-line ASCII drawing
    local str_g = tostring(g)
    if str_g == "" then
        return nil
    end

    local drawing = {}
    for row in vim.gsplit(str_g, "\n") do
        table.insert(drawing, row)
    end
    -- trim trailing blank rows
    while #drawing > 0 and drawing[#drawing] == "" do
        table.remove(drawing)
    end
    if #drawing == 0 then
        return nil
    end

    -- attach the graph object so callers can read g.my (the baseline row)
    drawing._g = g
    return drawing
end

--- Return true when `row` falls inside any recorded formula range for `buf`.
local function is_on_formula(buf, row)
    local ranges = module.private.formula_ranges[buf]
    if not ranges then
        return false
    end
    for _, r in ipairs(ranges) do
        if row >= r[1] and row <= r[2] then
            return true
        end
    end
    return false
end

--- Called on every cursor row change.  When the cursor enters or leaves a
--- formula region we re-render so the formula at the cursor is revealed
--- (skipped) and the previously revealed formula is restored.
local function handle_cursor_move(buf)
    if not module.private.do_render then
        return
    end

    local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0)
    if not ok then
        return
    end
    local cursor_row = pos[1] - 1 -- 0-indexed

    local last_row = module.private.last_cursor_row[buf]
    module.private.last_cursor_row[buf] = cursor_row

    if cursor_row == last_row then
        return
    end

    local was_on = last_row ~= nil and is_on_formula(buf, last_row)
    local now_on = is_on_formula(buf, cursor_row)

    if was_on or now_on then
        module.public.render(buf)
    end
end

-- ─── rendering ────────────────────────────────────────────────────────────────

--- Render an inline math node using conceal to hide the formula source and
--- inline `virt_text` to display the rendered drawing at the baseline.
--- Non-math text on the same line is left as-is and shifts naturally, so no
--- width padding or overlay is needed.  Rows above and below the baseline
--- are shown with `virt_lines_above` / `virt_lines` respectively.
---
--- The conceal requires `conceallevel >= 2` to take effect.  When the
--- cursor is on the formula line the module skips rendering entirely,
--- revealing the original LaTeX source for editing.
---
---@param buf    number  buffer handle
---@param node   userdata  TSNode for the inline_math
---@param content string  stripped LaTeX content (no Neorg markers)
local function render_inline(buf, node, content)
    local drawing = gen_drawing(content)
    if not drawing then
        return
    end

    local g = drawing._g
    local main_row = g.my or 0 -- 0-indexed row in drawing that aligns with source line

    local srow, scol, _, ecol = node:range()

    -- Compute a padding prefix so that virt_lines above/below the baseline
    -- are horizontally aligned with the rendered math at scol.
    --
    -- We prefer screenpos() because it accounts for conceal and virtual text
    -- from other modules (e.g. Neorg's own concealer hides bold `*` markers).
    -- The baseline uses virt_text_pos="inline" which Neovim positions
    -- correctly, but virt_lines always start at column 0 of the text area
    -- and need a manual space prefix.
    local prefix_width
    local win = vim.fn.bufwinid(buf)
    if win > 0 then
        -- screenpos uses 1-indexed lnum and col
        local sp = vim.fn.screenpos(win, srow + 1, scol + 1)
        if sp.col > 0 then
            local wi = vim.fn.getwininfo(win)[1]
            if wi then
                -- Detect line wrapping: if the formula is on a continuation
                -- line, screenpos gives the wrapped column which won't match
                -- the virt_lines layout.  Fall back in that case.
                local line_start = vim.fn.screenpos(win, srow + 1, 1)
                if line_start.row > 0 and sp.row == line_start.row then
                    local vcol = sp.col - wi.wincol - wi.textoff
                    if vcol >= 0 then
                        prefix_width = vcol
                    end
                end
            end
        end
    end
    if not prefix_width then
        -- Fallback for off-screen lines, wrapped lines, or missing window
        local line_text = vim.api.nvim_buf_get_lines(buf, srow, srow + 1, false)[1] or ""
        prefix_width = vim.fn.strdisplaywidth(line_text:sub(1, scol))
    end
    local prefix = string.rep(" ", prefix_width)

    -- ── rows ABOVE the baseline ──────────────────────────────────────────
    if main_row > 0 then
        local vlines = {}
        for r = 1, main_row do -- drawing rows 1..main_row (1-indexed)
            table.insert(vlines, make_virt_line(prefix .. (drawing[r] or "")))
        end
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, srow, scol, {
            virt_lines = vlines,
            virt_lines_above = true,
            strict = false,
            undo_restore = false,
            invalidate = true,
        })
    end

    -- ── baseline ─────────────────────────────────────────────────────────
    local main_line = drawing[main_row + 1] or "" -- 1-indexed

    -- Conceal the formula text so only the inline virtual text is visible
    -- (requires conceallevel >= 2).
    vim.api.nvim_buf_set_extmark(buf, module.private.ns, srow, scol, {
        end_row = srow,
        end_col = ecol,
        conceal = "",
        strict = false,
        undo_restore = false,
        invalidate = true,
    })

    -- Place the rendered drawing as inline virtual text at the formula
    -- position.  The non-math text on the line is left as-is and shifts
    -- naturally – no width padding or overlay is needed.
    vim.api.nvim_buf_set_extmark(buf, module.private.ns, srow, scol, {
        virt_text = make_virt_line(main_line),
        virt_text_pos = "inline",
        strict = false,
        undo_restore = false,
        invalidate = true,
    })

    -- ── rows BELOW the baseline ──────────────────────────────────────────
    if #drawing > main_row + 1 then
        local vlines = {}
        for r = main_row + 2, #drawing do
            table.insert(vlines, make_virt_line(prefix .. (drawing[r] or "")))
        end
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, srow, scol, {
            virt_lines = vlines,
            strict = false,
            undo_restore = false,
            invalidate = true,
        })
    end
end

--- Render a `@math` block: align the ASCII-art drawing so that its baseline
--- row is at the first content line (srow+1).  Rows above the baseline are
--- placed as `virt_lines_above` at that line; the baseline itself is shown
--- as a `virt_text` overlay; rows below the baseline are placed as
--- `virt_lines`.  All content lines are concealed (blank at conceallevel >= 2).
---
---@param buf  number  buffer handle
---@param node userdata  TSNode for the ranged_verbatim_tag
local function render_math_block(buf, node)
    local srow, _, erow, _ = node:range()

    -- Detect the indentation of the @math tag line so the rendered ASCII art
    -- is placed at the same indentation level as the original block.
    local tag_line = vim.api.nvim_buf_get_lines(buf, srow, srow + 1, false)[1] or ""
    local indent = tag_line:match("^(%s*)") or ""

    -- Lines between @math (srow) and @end (erow), exclusive on both ends.
    local lines = vim.api.nvim_buf_get_lines(buf, srow + 1, erow, false)

    -- Drop any trailing @end line that might be included
    while #lines > 0 and lines[#lines]:match("^%s*@end") do
        table.remove(lines)
    end

    if #lines == 0 then
        return
    end

    -- Join lines for the parser (nabla processes a flat string)
    local content = vim.trim(table.concat(lines, " "))
    if content == "" then
        return
    end

    local drawing = gen_drawing(content)
    if not drawing then
        return
    end

    local g = drawing._g
    local main_row = g.my or 0 -- 0-indexed row in drawing for baseline

    -- The drawing baseline aligns with the first content line.
    local content_row = srow + 1

    -- Rows above baseline → virt_lines_above at content_row (appear between
    -- the @math tag line and the first content line).
    if main_row > 0 then
        local vlines = {}
        for r = 1, main_row do
            table.insert(vlines, make_virt_line(indent .. (drawing[r] or "")))
        end
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, content_row, 0, {
            virt_lines = vlines,
            virt_lines_above = true,
            strict = false,
            undo_restore = false,
            invalidate = true,
        })
    end

    -- Baseline → virt_text overlay at content_row (content line is concealed
    -- so the overlay is the only thing visible there).
    local main_line = indent .. (drawing[main_row + 1] or "")
    vim.api.nvim_buf_set_extmark(buf, module.private.ns, content_row, 0, {
        virt_text = make_virt_line(main_line),
        virt_text_pos = "overlay",
        strict = false,
        undo_restore = false,
        invalidate = true,
    })

    -- Rows below baseline → virt_lines at content_row.
    if #drawing > main_row + 1 then
        local vlines = {}
        for r = main_row + 2, #drawing do
            table.insert(vlines, make_virt_line(indent .. (drawing[r] or "")))
        end
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, content_row, 0, {
            virt_lines = vlines,
            strict = false,
            undo_restore = false,
            invalidate = true,
        })
    end

    -- Conceal each content line (shows as blank when conceallevel >= 2)
    for r = srow + 1, erow - 1 do
        local line = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
        if #line > 0 then
            vim.api.nvim_buf_set_extmark(buf, module.private.ns, r, 0, {
                end_row = r,
                end_col = #line,
                conceal = "",
                strict = false,
                undo_restore = false,
                invalidate = true,
            })
        end
    end
end

-- ─── public API ───────────────────────────────────────────────────────────────

---@class external.nabla
module.public = {
    --- Render all LaTeX expressions in `buf` (defaults to current buffer).
    render = function(buf)
        buf = buf or vim.api.nvim_get_current_buf()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        if vim.bo[buf].ft ~= "norg" then
            return
        end

        -- Clear stale extmarks first
        vim.api.nvim_buf_clear_namespace(buf, module.private.ns, 0, -1)

        -- Track formula row-ranges so handle_cursor_move knows which rows
        -- belong to a formula and can trigger a re-render on transitions.
        module.private.formula_ranges[buf] = {}

        -- Determine the cursor row (0-indexed) so we can skip rendering for
        -- the formula the cursor is sitting on, revealing the original source.
        local cursor_row = nil
        if buf == vim.api.nvim_get_current_buf() then
            local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0)
            if ok then
                cursor_row = pos[1] - 1
            end
        end

        local ts = module.required["core.integrations.treesitter"]

        -- ── inline math: $...$ and $|...|$ ──────────────────────────────
        ts.execute_query(
            [[(inline_math) @math]],
            function(query, id, node)
                if query.captures[id] ~= "math" then
                    return
                end

                local text = ts.get_node_text(node, buf)
                if not text or text == "" then
                    return
                end

                local content
                if text:match("^%$|") then
                    -- $|...|$ – verbatim LaTeX, strip $| and |$
                    content = text:sub(3, #text - 2)
                elseif text:match("^%$") then
                    -- $...$ – Neorg-escaped math: in this syntax backslash is
                    -- Neorg's own escape character (not a LaTeX command prefix),
                    -- so `\x` → `x`.  This follows core.latex.renderer behaviour.
                    -- For standard LaTeX use the $|...|$ verbatim syntax instead.
                    content = text:sub(2, #text - 1)
                    content = content:gsub("\\(.)", "%1")
                else
                    return
                end

                content = vim.trim(content)
                if content == "" then
                    return
                end

                -- Record range and skip rendering when cursor is on this line
                -- so the original LaTeX source is visible for editing.
                local srow = select(1, node:range())
                table.insert(module.private.formula_ranges[buf], { srow, srow })
                if cursor_row and cursor_row == srow then
                    return
                end

                render_inline(buf, node, content)
            end,
            buf
        )

        -- ── @math ... @end blocks ────────────────────────────────────────
        ts.execute_query(
            [[
                (ranged_verbatim_tag
                    (tag_name) @name
                    (#eq? @name "math")
                ) @block
            ]],
            function(query, id, node)
                if query.captures[id] ~= "block" then
                    return
                end

                -- Record range and skip rendering when cursor is inside the
                -- block so the original content lines are visible.
                local srow, _, erow, _ = node:range()
                table.insert(module.private.formula_ranges[buf], { srow, erow })
                if cursor_row and cursor_row >= srow and cursor_row <= erow then
                    return
                end

                render_math_block(buf, node)
            end,
            buf
        )
    end,

    --- Clear all neorg-nabla extmarks from `buf` (defaults to current buffer).
    clear = function(buf)
        buf = buf or vim.api.nvim_get_current_buf()
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_clear_namespace(buf, module.private.ns, 0, -1)
        end
    end,
}

-- ─── scheduling helpers ───────────────────────────────────────────────────────

local function schedule_render(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    if not module.private.do_render then
        return
    end

    -- Cancel any pending timer for this buffer
    local existing = module.private.render_timers[buf]
    if existing then
        existing:stop()
        existing:close()
        module.private.render_timers[buf] = nil
    end

    local timer = vim.uv.new_timer()
    module.private.render_timers[buf] = timer
    timer:start(
        module.config.public.debounce_ms,
        0,
        vim.schedule_wrap(function()
            if module.private.render_timers[buf] == timer then
                timer:stop()
                timer:close()
                module.private.render_timers[buf] = nil
            end
            module.public.render(buf)
        end)
    )
end

local function enable_rendering()
    module.private.do_render = true
    schedule_render()
end

local function disable_rendering()
    module.private.do_render = false
    -- Cancel all pending timers
    for buf, timer in pairs(module.private.render_timers) do
        timer:stop()
        timer:close()
        module.private.render_timers[buf] = nil
    end
    -- Clear extmarks from every valid buffer
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
            module.public.clear(buf)
        end
    end
    -- Reset cursor tracking state
    module.private.formula_ranges = {}
    module.private.last_cursor_row = {}
end

local function toggle_rendering()
    if module.private.do_render then
        disable_rendering()
    else
        enable_rendering()
    end
end

-- ─── module.load ─────────────────────────────────────────────────────────────

module.load = function()
    module.private.ns = vim.api.nvim_create_namespace("neorg-nabla")
    module.private.do_render = module.config.public.render_on_enter
    module.private.render_timers = {}
    module.private.formula_ranges = {}
    module.private.last_cursor_row = {}

    -- Register the autocommands neorg should forward to us
    module.required["core.autocommands"].enable_autocommand("BufWinEnter")
    module.required["core.autocommands"].enable_autocommand("BufReadPost")
    module.required["core.autocommands"].enable_autocommand("InsertLeave")
    module.required["core.autocommands"].enable_autocommand("TextChanged")

    -- Use native autocommands for high-frequency cursor events so we avoid
    -- the overhead of the Neorg event dispatch on every cursor movement.
    module.private.aug = vim.api.nvim_create_augroup("neorg-nabla-cursor", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter" }, {
        group = module.private.aug,
        callback = function(args)
            local buf = args.buf
            if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].ft ~= "norg" then
                return
            end
            handle_cursor_move(buf)
        end,
    })

    -- Register `:Neorg nabla [enable|disable|toggle]`
    modules.await("core.neorgcmd", function(neorgcmd)
        neorgcmd.add_commands_from_table({
            ["nabla"] = {
                name = "nabla.render",
                min_args = 0,
                max_args = 1,
                subcommands = {
                    enable = {
                        args = 0,
                        name = "nabla.enable",
                    },
                    disable = {
                        args = 0,
                        name = "nabla.disable",
                    },
                    toggle = {
                        args = 0,
                        name = "nabla.toggle",
                    },
                },
                condition = "norg",
            },
        })
    end)
end

-- ─── event handling ───────────────────────────────────────────────────────────

local event_handlers = {
    ["core.neorgcmd.events.nabla.render"] = enable_rendering,
    ["core.neorgcmd.events.nabla.enable"] = enable_rendering,
    ["core.neorgcmd.events.nabla.disable"] = disable_rendering,
    ["core.neorgcmd.events.nabla.toggle"] = toggle_rendering,
    ["core.autocommands.events.bufwinenter"] = function(event)
        schedule_render(event.buffer)
    end,
    ["core.autocommands.events.bufreadpost"] = function(event)
        if module.config.public.render_on_enter then
            schedule_render(event.buffer)
        end
    end,
    ["core.autocommands.events.insertleave"] = function(event)
        schedule_render(event.buffer)
    end,
    ["core.autocommands.events.textchanged"] = function(event)
        schedule_render(event.buffer)
    end,
}

module.on_event = function(event)
    -- Ignore autocommand events from non-norg buffers
    if event.referrer == "core.autocommands" then
        local buf = event.buffer
        if not buf or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].ft ~= "norg" then
            return
        end
    end

    local handler = event_handlers[event.type]
    if handler then
        -- neorgcmd events have no buffer; autocommand events do
        if event.referrer == "core.autocommands" then
            handler(event)
        else
            handler()
        end
    end
end

module.events.subscribed = {
    ["core.autocommands"] = {
        bufwinenter = true,
        bufreadpost = true,
        insertleave = true,
        textchanged = true,
    },
    ["core.neorgcmd"] = {
        ["nabla.render"] = true,
        ["nabla.enable"] = true,
        ["nabla.disable"] = true,
        ["nabla.toggle"] = true,
    },
}

return module
