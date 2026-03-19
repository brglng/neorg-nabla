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

    --- When true, the `@math` and `@end` tag lines of math blocks are concealed
    --- (hidden when conceallevel >= 2).  Default is false.
    conceal_math_tags = false,
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

    --- Per-buffer last cursor column (0-indexed byte) seen by the cursor-move handler.
    last_cursor_col = {},

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

--- Walk the grid tree produced by nabla.ascii and apply highlight groups to
--- virt-line entries following common LaTeX rendering conventions.
---
--- Each nabla grid node type maps to its own highlight group so that users
--- can customise them independently.  The defaults follow standard LaTeX
--- math-mode conventions: variables and Greek letters are *italic*; named
--- math functions (e.g. cos, sin) and \mathbf content are **bold**; while
--- numbers, operators, and delimiters are upright (normal weight).
---
--- Type → highlight group (default style):
---   "var"                   → NeorgNablaVar        (italic      — Greek letters / special vars)
---   "sym" (single-char α)   → NeorgNablaSym        (italic      — variable names)
---   "sym" (multi-char α)    → NeorgNablaFun        (normal      — named functions: cos, sin …)
---   "sym" (numeric)         → NeorgNablaNumber     (normal      — numeric symbols)
---   "sym" (other)           → NeorgNablaOperator   (normal      — operator-like, may span rows)
---   "num"                   → NeorgNablaNumber     (normal      — numbers)
---   "op"                    → NeorgNablaOperator   (normal      — multi-row operators)
---   "par"                   → NeorgNablaDelimiter  (normal      — parentheses/brackets)
---   "bf"                    → NeorgNablaBold       (bold        — \mathbf)
---   "bfit"                  → NeorgNablaBoldItalic (bold+italic — \boldsymbol)
---   nil   (alphabetic)      → NeorgNablaFun        (bold        — plain functions: min, exp, log)
---
---@param g          table   grid object from nabla.ascii.to_ascii
---@param virt_lines table   array of virt-line arrays (1-indexed rows of {char, hl} tuples)
---@param first_dx   number  column offset on the very first output row
---@param dx         number  column offset on subsequent rows
---@param dy         number  row offset
local function stylize_virt(g, virt_lines, first_dx, dx, dy)
    if g.t == "num" then
        local off = (dy == 0) and first_dx or dx
        for i = 1, g.w do
            if virt_lines[dy + 1] and virt_lines[dy + 1][off + i] then
                virt_lines[dy + 1][off + i][2] = "NeorgNablaNumber"
            end
        end
    end

    if g.t == "sym" then
        local off = (dy == 0) and first_dx or dx
        if g.content and g.content[1] and string.match(g.content[1], "^%a") then
            if g.w > 1 then
                -- Multi-character alphabetic: named function (cos, sin, …) → upright
                for i = 1, g.w do
                    if virt_lines[dy + 1] and virt_lines[dy + 1][off + i] then
                        virt_lines[dy + 1][off + i][2] = "NeorgNablaFun"
                    end
                end
            else
                -- Single-character alphabetic: variable name → italic
                for i = 1, g.w do
                    if virt_lines[dy + 1] and virt_lines[dy + 1][off + i] then
                        virt_lines[dy + 1][off + i][2] = "NeorgNablaSym"
                    end
                end
            end
        elseif g.content and g.content[1] and string.match(g.content[1], "^%d") then
            -- Numeric symbols → normal (upright in LaTeX)
            for i = 1, g.w do
                if virt_lines[dy + 1] and virt_lines[dy + 1][off + i] then
                    virt_lines[dy + 1][off + i][2] = "NeorgNablaNumber"
                end
            end
        else
            -- Operator-like symbols (may span multiple rows) → normal (upright in LaTeX)
            for y = 1, g.h do
                local row_off = (y + dy == 1) and first_dx or dx
                for i = 1, g.w do
                    if virt_lines[dy + y] and virt_lines[dy + y][row_off + i] then
                        virt_lines[dy + y][row_off + i][2] = "NeorgNablaOperator"
                    end
                end
            end
        end
    end

    if g.t == "bf" then
        -- \mathbf content → bold (not italic).
        -- Skip children recursion so inner type-specific highlights don't
        -- overwrite the bold style.
        for y = 1, g.h do
            local off = (y + dy == 1) and first_dx or dx
            for i = 1, g.w do
                if virt_lines[dy + y] and virt_lines[dy + y][off + i] then
                    virt_lines[dy + y][off + i][2] = "NeorgNablaBold"
                end
            end
        end
        return
    end

    if g.t == "bfit" then
        -- \boldsymbol content → bold + italic.
        -- Skip children recursion so inner type-specific highlights don't
        -- overwrite the bold+italic style.
        for y = 1, g.h do
            local off = (y + dy == 1) and first_dx or dx
            for i = 1, g.w do
                if virt_lines[dy + y] and virt_lines[dy + y][off + i] then
                    virt_lines[dy + y][off + i][2] = "NeorgNablaBoldItalic"
                end
            end
        end
        return
    end

    if g.t == "op" then
        for y = 1, g.h do
            local off = (y + dy == 1) and first_dx or dx
            for i = 1, g.w do
                if virt_lines[dy + y] and virt_lines[dy + y][off + i] then
                    virt_lines[dy + y][off + i][2] = "NeorgNablaOperator"
                end
            end
        end
    end

    if g.t == "par" then
        for y = 1, g.h do
            local off = (y + dy == 1) and first_dx or dx
            for i = 1, g.w do
                if virt_lines[dy + y] and virt_lines[dy + y][off + i] then
                    virt_lines[dy + y][off + i][2] = "NeorgNablaDelimiter"
                end
            end
        end
    end

    if g.t == "var" then
        -- Greek letters / special variables → italic
        local off = (dy == 0) and first_dx or dx
        for i = 1, g.w do
            if virt_lines[dy + 1] and virt_lines[dy + 1][off + i] then
                virt_lines[dy + 1][off + i][2] = "NeorgNablaVar"
            end
        end
    end

    -- Grids without a type (e.g. nabla's plain_functions: min, exp, log) that
    -- contain purely alphabetic text are named functions → bold/upright.
    if g.t == nil and g.h == 1 and g.content and g.content[1]
        and string.match(g.content[1], "^%a+$") then
        local off = (dy == 0) and first_dx or dx
        for i = 1, g.w do
            if virt_lines[dy + 1] and virt_lines[dy + 1][off + i] then
                virt_lines[dy + 1][off + i][2] = "NeorgNablaFun"
            end
        end
    end

    if g.children then
        for _, child in ipairs(g.children) do
            stylize_virt(child[1], virt_lines, child[2] + first_dx, child[2] + dx, child[3] + dy)
        end
    end
end

--- Walk the parsed LaTeX AST and collect the content expressions that appear
--- inside \mathbf{} or \boldsymbol{} commands.  These are the sub-expressions
--- whose rendered grids should receive bold (or bold+italic) highlighting.
---
---@param exp  table  root expression from nabla.latex.parse_all
---@return table[]    list of {exp=table, macro=string} entries
local function find_font_content_exps(exp)
    local result = {}
    if not exp then
        return result
    end

    local function walk(node)
        if not node then
            return
        end

        if node.kind == "explist" then
            local exps = node.exps
            local i = 1
            while i <= #exps do
                local e = exps[i]
                if e.kind == "funexp"
                    and (e.sym == "mathbf" or e.sym == "boldsymbol")
                    and i + 1 <= #exps
                then
                    table.insert(result, { exp = exps[i + 1], macro = e.sym })
                    -- recurse into the inner content for nested font commands
                    walk(exps[i + 1])
                    i = i + 2
                else
                    walk(e)
                    i = i + 1
                end
            end
        elseif node.kind == "parexp" then
            walk(node.exp)
        elseif node.kind == "braexp" then
            walk(node.exp)
        elseif node.kind == "blockexp" then
            walk(node.content)
            walk(node.first)
        elseif node.kind == "chosexp" then
            walk(node.left)
            walk(node.right)
        end
    end

    walk(exp)
    return result
end

--- Walk the grid tree depth-first and mark nodes whose content and
--- dimensions match one of the `font_refs` entries by setting their type
--- to the corresponding target (e.g. `"bf"` or `"bfit"`).
--- Matched references are consumed so that each reference matches at most
--- one grid node (left-to-right order, matching expression order).
---
---@param g          table    root grid from nabla.ascii.to_ascii
---@param font_refs  table[]  list of {w, h, content, t, target} reference grids
local function mark_font_grids(g, font_refs)
    if #font_refs == 0 then
        return
    end

    -- Try to match this grid against the first unconsumed reference.
    for i, ref in ipairs(font_refs) do
        if g.w == ref.w and g.h == ref.h and g.t == ref.t then
            local match = true
            for j = 1, g.h do
                if (g.content[j] or "") ~= (ref.content[j] or "") then
                    match = false
                    break
                end
            end
            if match then
                g.t = ref.target
                table.remove(font_refs, i)
                return -- this node is consumed; do not recurse into children
            end
        end
    end

    -- Recurse depth-first (left-to-right) into children.
    if g.children then
        for _, child in ipairs(g.children) do
            mark_font_grids(child[1], font_refs)
            if #font_refs == 0 then
                return
            end
        end
    end
end

--- Collect tree-sitter conceal ranges on `row` from highlight queries.
--- These come from `@conceal` captures with `#set! conceal` directives
--- (e.g. Neorg's highlights.scm hides bold/italic delimiters this way).
--- Tree-sitter conceals are NOT visible via `nvim_buf_get_extmarks`, so
--- they must be queried separately.
---@return table[]  list of {s=number, e=number, rep=string}
local function get_ts_conceal_ranges(buf, row)
    local ranges = {}

    local ok, parser = pcall(vim.treesitter.get_parser, buf)
    if not ok or not parser then
        return ranges
    end

    local trees = parser:parse()
    if not trees or #trees == 0 then
        return ranges
    end

    local lang = parser:lang()
    local ok2, query = pcall(vim.treesitter.query.get, lang, "highlights")
    if not ok2 or not query then
        return ranges
    end

    for id, node, metadata in query:iter_captures(trees[1]:root(), buf, row, row + 1) do
        local name = query.captures[id]
        if name == "conceal" then
            local srow, scol, erow, ecol = node:range()
            if srow == row and erow == row then
                local rep = ""
                if metadata then
                    -- Neovim stores #set! conceal metadata at different
                    -- levels depending on the query structure and version:
                    -- capture-level (metadata[id].conceal) or match-level
                    -- (metadata.conceal).  Check both.
                    if type(metadata[id]) == "table" and metadata[id].conceal then
                        rep = metadata[id].conceal
                    elseif metadata.conceal then
                        rep = metadata.conceal
                    end
                end
                table.insert(ranges, { s = scol, e = ecol, rep = rep })
            end
        end
    end

    return ranges
end

--- Compute the 0-indexed visual (display) column of buffer byte position
--- `byte_col` on `row` in `buf`, accounting for both extmark-based AND
--- tree-sitter-based conceals.
---
--- Extmark conceals are read via `nvim_buf_get_extmarks` (all namespaces).
--- Tree-sitter conceals (e.g. `@conceal` in highlight queries) are read
--- via `get_ts_conceal_ranges`.  Passing pre-computed `ts_ranges` avoids
--- redundant tree-sitter queries when multiple formulas share a line.
local function visual_col_with_conceal(buf, row, byte_col, line_text, ts_ranges)
    if byte_col <= 0 then
        return 0
    end

    -- Collect conceal extmarks from ALL namespaces on this row.
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, {
        details = true,
        overlap = true,
    })

    local ranges = {}
    for _, mark in ipairs(marks) do
        local details = mark[4]
        if details.conceal ~= nil then
            local s = mark[3]
            local e = details.end_col
            if e and s < byte_col then
                e = math.min(e, byte_col)
                if e > s then
                    table.insert(ranges, { s = s, e = e, rep = details.conceal })
                end
            end
        end
    end

    -- Merge tree-sitter conceal ranges.
    if ts_ranges == nil then
        ts_ranges = get_ts_conceal_ranges(buf, row)
    end
    for _, r in ipairs(ts_ranges) do
        if r.s < byte_col then
            local e = math.min(r.e, byte_col)
            if e > r.s then
                table.insert(ranges, { s = r.s, e = e, rep = r.rep })
            end
        end
    end

    if #ranges == 0 then
        return vim.fn.strdisplaywidth(line_text:sub(1, byte_col))
    end

    -- Sort by start position; for equal starts, prefer the longer range.
    table.sort(ranges, function(a, b)
        if a.s ~= b.s then return a.s < b.s end
        return a.e > b.e
    end)

    -- Build the visual string by replacing concealed byte ranges with their
    -- replacement characters.  Skip overlapping ranges (first-wins).
    local parts = {}
    local pos = 0
    for _, r in ipairs(ranges) do
        if r.s >= pos then
            if r.s > pos then
                table.insert(parts, line_text:sub(pos + 1, r.s))
            end
            table.insert(parts, r.rep)
            pos = r.e
        end
    end
    if pos < byte_col then
        table.insert(parts, line_text:sub(pos + 1, byte_col))
    end

    return vim.fn.strdisplaywidth(table.concat(parts))
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

    -- Mark grid nodes that originate from \mathbf{} or \boldsymbol{} so that
    -- stylize_virt renders them with the appropriate bold / bold+italic style.
    local font_exps = find_font_content_exps(exp)
    if #font_exps > 0 then
        local font_refs = {}
        for _, entry in ipairs(font_exps) do
            local bok, bg = pcall(ascii_mod.to_ascii, { entry.exp }, 1)
            if bok and bg then
                table.insert(font_refs, {
                    w = bg.w,
                    h = bg.h,
                    content = bg.content,
                    t = bg.t,
                    target = entry.macro == "boldsymbol" and "bfit" or "bf",
                })
            end
        end
        if #font_refs > 0 then
            mark_font_grids(g, font_refs)
        end
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

    -- Build styled virtual-text lines with bold/italic formatting applied
    -- according to LaTeX rendering conventions.
    local virt_lines = {}
    for j = 1, #drawing do
        virt_lines[j] = make_virt_line(drawing[j])
    end
    stylize_virt(g, virt_lines, 0, 0, 0)
    drawing._virt_lines = virt_lines

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

--- Called on every cursor row/column change.  When the cursor enters or
--- leaves a formula region we re-render.  In normal mode, column changes on
--- a formula line also trigger re-render so that per-formula cursor detection
--- can reveal only the inline math span under the cursor.
local function handle_cursor_move(buf)
    if not module.private.do_render then
        return
    end

    local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0)
    if not ok then
        return
    end
    local cursor_row = pos[1] - 1 -- 0-indexed
    local cursor_col = pos[2]     -- 0-indexed byte column

    local last_row = module.private.last_cursor_row[buf]
    local last_col = module.private.last_cursor_col[buf]
    module.private.last_cursor_row[buf] = cursor_row
    module.private.last_cursor_col[buf] = cursor_col

    if cursor_row == last_row and cursor_col == last_col then
        return
    end

    if cursor_row ~= last_row then
        -- Row changed: re-render if entering or leaving a formula region.
        local was_on = last_row ~= nil and is_on_formula(buf, last_row)
        local now_on = is_on_formula(buf, cursor_row)
        if was_on or now_on then
            module.public.render(buf)
        end
    else
        -- Same row, column changed.
        local mode = vim.api.nvim_get_mode().mode
        local is_insert = mode:sub(1, 1) == "i" or mode:sub(1, 1) == "R"
        if not is_insert and is_on_formula(buf, cursor_row) then
            -- Normal mode on a formula line: re-render to update per-formula
            -- cursor detection for inline math.
            module.public.render(buf)
        end
    end
end

-- ─── rendering ────────────────────────────────────────────────────────────────

--- Render all inline math nodes that share a single buffer line as a group.
--- This merges the above- and below-baseline virtual-line rows from every
--- formula into a single set of virt_lines, so that multiple multi-line
--- formulas on the same line do not produce redundant blank lines.
---
--- Each formula's baseline is rendered as concealed source + inline virtual
--- text on non-cursor lines.  When `cursor_col` is non-nil (normal mode,
--- cursor on this line), ALL inline math formulas on the line reveal their
--- raw source text (no overlay or conceal is placed) so the user can
--- inspect and navigate the LaTeX.  Virtual lines (above/below baseline)
--- are always rendered for all formulas regardless of cursor position.
---
---@param buf        number       buffer handle
---@param entries    table        list of {node=TSNode, content=string}, sorted by column
---@param cursor_col number|nil   cursor byte column (0-indexed) or nil
local function render_inline_group(buf, entries, cursor_col)
    local srow = select(1, entries[1].node:range())
    local line_text = vim.api.nvim_buf_get_lines(buf, srow, srow + 1, false)[1] or ""

    -- Generate drawings and collect valid (successfully parsed) entries.
    local valid = {}
    for _, entry in ipairs(entries) do
        local drawing = gen_drawing(entry.content)
        if drawing then
            local _, scol, _, ecol = entry.node:range()
            table.insert(valid, {
                node = entry.node,
                drawing = drawing,
                main_row = (drawing._g.my or 0),
                scol = scol,
                ecol = ecol,
                baseline = drawing[(drawing._g.my or 0) + 1] or "",
            })
        end
    end
    if #valid == 0 then
        return
    end

    -- ── compute visual column for each formula ──────────────────────────
    -- Compute the 0-indexed visual column of each formula start and end,
    -- accounting for both extmark-based and tree-sitter-based conceals
    -- from other modules (e.g. neorg's core.concealer for bold/italic
    -- markers, and @conceal captures in highlight queries that hide
    -- markup delimiters).  Pre-compute tree-sitter ranges once for the
    -- whole line to avoid redundant queries.
    -- Wrapped long lines are intentionally not supported because Neovim
    -- cannot insert virtual lines between wrapped screen lines.
    local ts_ranges = get_ts_conceal_ranges(buf, srow)
    for _, v in ipairs(valid) do
        v.pre_col = visual_col_with_conceal(buf, srow, v.scol, line_text, ts_ranges)
        v.post_col = visual_col_with_conceal(buf, srow, v.ecol, line_text, ts_ranges)
    end

    -- Whether the cursor is on this particular source line.
    local is_cursor_line = cursor_col ~= nil

    -- On the cursor line Neovim reveals conceals (e.g. `$` delimiters
    -- hidden by tree-sitter @conceal captures) unless `concealcursor`
    -- includes the current mode.  When conceals are revealed the visual
    -- columns computed by visual_col_with_conceal are too small (they
    -- assume concealed characters are hidden when they are actually
    -- visible), so recompute pre_col using raw display widths so that
    -- virt_lines align correctly with the revealed source text.
    -- When concealcursor IS active, conceals are honoured on the cursor
    -- line too, so the existing visual_col_with_conceal values are already
    -- correct and no recomputation is needed.
    if is_cursor_line then
        local cc = vim.wo.concealcursor or ""
        local mode_char = vim.api.nvim_get_mode().mode:sub(1, 1):lower()
        if not cc:find(mode_char, 1, true) then
            for _, v in ipairs(valid) do
                v.pre_col = vim.fn.strdisplaywidth(line_text:sub(1, v.scol))
            end
        end
    end

    -- ── compute virt_col and place baseline rendering ─────────────────
    if is_cursor_line then
        -- Cursor line: all inline math formulas reveal their raw source text;
        -- no overlay or conceal is placed.  Since no baseline is replaced,
        -- every formula occupies its original source width and there is no
        -- cumulative width delta — virt_col equals pre_col directly.
        -- Virtual lines above/below are still rendered to keep the view.
        for _, v in ipairs(valid) do
            v.virt_col = v.pre_col
        end
    else
        -- Non-cursor lines: conceal source text and replace with rendered
        -- baseline as inline virtual text.
        local width_delta = 0
        for _, v in ipairs(valid) do
            v.virt_col = v.pre_col + width_delta
            local source_width = v.post_col - v.pre_col
            width_delta = width_delta
                + vim.fn.strdisplaywidth(v.baseline) - source_width
        end

        for _, v in ipairs(valid) do
            vim.api.nvim_buf_set_extmark(buf, module.private.ns, srow, v.scol, {
                end_row = srow,
                end_col = v.ecol,
                conceal = "",
                strict = false,
                undo_restore = false,
                invalidate = true,
            })
            vim.api.nvim_buf_set_extmark(buf, module.private.ns, srow, v.scol, {
                virt_text = v.drawing._virt_lines[v.main_row + 1]
                    or make_virt_line(v.baseline),
                virt_text_pos = "inline",
                strict = false,
                undo_restore = false,
                invalidate = true,
            })
        end
    end

    -- ── determine max rows above / below baseline ──────────────────────
    local max_above = 0
    local max_below = 0
    for _, v in ipairs(valid) do
        max_above = math.max(max_above, v.main_row)
        max_below = math.max(max_below, #v.drawing - v.main_row - 1)
    end

    -- ── build combined above-baseline virt_lines ───────────────────────
    if max_above > 0 then
        local vlines = {}
        for r = 1, max_above do
            local combined = {}
            local cur_col = 0
            for _, v in ipairs(valid) do
                -- Align from the bottom: when r == max_above the
                -- result must equal v.main_row (the row just above the
                -- baseline).  Solving: draw_r = r - max_above + v.main_row.
                local draw_r = r - max_above + v.main_row
                if draw_r >= 1 and draw_r <= v.main_row then
                    local text = v.drawing[draw_r] or ""
                    local row_virt = v.drawing._virt_lines[draw_r] or {}
                    if v.virt_col > cur_col then
                        for _ = 1, v.virt_col - cur_col do
                            table.insert(combined, { " ", "Normal" })
                        end
                        cur_col = v.virt_col
                    end
                    vim.list_extend(combined, row_virt)
                    cur_col = cur_col + vim.fn.strdisplaywidth(text)
                end
            end
            table.insert(vlines, combined)
        end
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, srow, 0, {
            virt_lines = vlines,
            virt_lines_above = true,
            strict = false,
            undo_restore = false,
            invalidate = true,
        })
    end

    -- ── build combined below-baseline virt_lines ───────────────────────
    if max_below > 0 then
        local vlines = {}
        for r = 1, max_below do
            local combined = {}
            local cur_col = 0
            for _, v in ipairs(valid) do
                local draw_r = v.main_row + 1 + r -- 1-indexed
                if draw_r <= #v.drawing then
                    local text = v.drawing[draw_r] or ""
                    local row_virt = v.drawing._virt_lines[draw_r] or {}
                    if v.virt_col > cur_col then
                        for _ = 1, v.virt_col - cur_col do
                            table.insert(combined, { " ", "Normal" })
                        end
                        cur_col = v.virt_col
                    end
                    vim.list_extend(combined, row_virt)
                    cur_col = cur_col + vim.fn.strdisplaywidth(text)
                end
            end
            table.insert(vlines, combined)
        end
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, srow, 0, {
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
--- When `cursor_inside` is true the baseline overlay and content-line
--- concealment are skipped so the original source is visible for editing,
--- while the virtual lines above/below are kept.
---
---@param buf  number  buffer handle
---@param node userdata  TSNode for the ranged_verbatim_tag
---@param cursor_inside boolean  whether the cursor is currently inside this block
local function render_math_block(buf, node, cursor_inside)
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
        local indent_virt = make_virt_line(indent)
        for r = 1, main_row do
            local combined = {}
            vim.list_extend(combined, indent_virt)
            vim.list_extend(combined, drawing._virt_lines[r] or {})
            table.insert(vlines, combined)
        end
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, content_row, 0, {
            virt_lines = vlines,
            virt_lines_above = true,
            strict = false,
            undo_restore = false,
            invalidate = true,
        })
    end

    -- When the cursor is on a content line, skip the baseline overlay so
    -- the raw text at srow+1 is visible.  Content lines after the first
    -- (srow+2 … erow-1) are still concealed; the cursor line is
    -- automatically revealed by Neovim when concealcursor does not
    -- include the current mode.
    if not cursor_inside then
        -- Baseline → virt_text overlay at content_row (content line is concealed
        -- so the overlay is the only thing visible there).
        local main_line_virt = {}
        vim.list_extend(main_line_virt, make_virt_line(indent))
        vim.list_extend(main_line_virt, drawing._virt_lines[main_row + 1] or {})
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, content_row, 0, {
            virt_text = main_line_virt,
            virt_text_pos = "overlay",
            strict = false,
            undo_restore = false,
            invalidate = true,
        })

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
    else
        -- Cursor is on a content line: skip the baseline overlay so the raw
        -- text at srow+1 (the baseline position) is visible.  Conceal the
        -- remaining content lines (srow+2 … erow-1) to keep the rendered
        -- appearance tidy; the cursor line auto-reveals its conceal.
        for r = srow + 2, erow - 1 do
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

    -- Rows below baseline → virt_lines at content_row.
    if #drawing > main_row + 1 then
        local vlines = {}
        local indent_virt = make_virt_line(indent)
        for r = main_row + 2, #drawing do
            local combined = {}
            vim.list_extend(combined, indent_virt)
            vim.list_extend(combined, drawing._virt_lines[r] or {})
            table.insert(vlines, combined)
        end
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, content_row, 0, {
            virt_lines = vlines,
            strict = false,
            undo_restore = false,
            invalidate = true,
        })
    end

    -- Optionally conceal the @math and @end tag lines as well.
    -- Uses Neovim 0.11 line-level concealing (`conceal_lines`) so that the
    -- entire screen row disappears (including line number) rather than just
    -- hiding the tag text.
    if module.config.public.conceal_math_tags then
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, srow, 0, {
            end_row = srow,
            conceal_lines = "",
            strict = false,
            undo_restore = false,
            invalidate = true,
        })
        vim.api.nvim_buf_set_extmark(buf, module.private.ns, erow, 0, {
            end_row = erow,
            conceal_lines = "",
            strict = false,
            undo_restore = false,
            invalidate = true,
        })
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

        -- Determine cursor position and editing mode.
        local cursor_row = nil
        local cursor_col = nil
        if buf == vim.api.nvim_get_current_buf() then
            local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0)
            if ok then
                cursor_row = pos[1] - 1
                cursor_col = pos[2]
            end
        end

        local mode = vim.api.nvim_get_mode().mode
        local is_insert = mode:sub(1, 1) == "i" or mode:sub(1, 1) == "R"

        local ts = module.required["core.integrations.treesitter"]

        -- ── inline math: $...$ and $|...|$ ──────────────────────────────
        -- Collect entries grouped by line so that multiple formulas on the
        -- same line share combined virt_lines (no redundant blank rows).
        local inline_by_line = {}
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

                local srow = select(1, node:range())
                table.insert(module.private.formula_ranges[buf], { srow, srow })

                -- In insert mode, skip all formulas on the cursor line so the
                -- original source is visible for editing.
                -- In normal mode, never skip here; per-formula cursor detection
                -- is handled inside render_inline_group.
                if is_insert and cursor_row and cursor_row == srow then
                    return
                end

                if not inline_by_line[srow] then
                    inline_by_line[srow] = {}
                end
                table.insert(inline_by_line[srow], { node = node, content = content })
            end,
            buf
        )

        -- Render each line's inline math formulas as a group.
        for _, group in pairs(inline_by_line) do
            table.sort(group, function(a, b)
                local _, a_scol = a.node:range()
                local _, b_scol = b.node:range()
                return a_scol < b_scol
            end)
            -- In normal mode, pass cursor column so render_inline_group can
            -- reveal only the specific formula the cursor is hovering on.
            local line_cursor_col = nil
            if not is_insert and cursor_row then
                local srow_first = select(1, group[1].node:range())
                if cursor_row == srow_first then
                    line_cursor_col = cursor_col
                end
            end
            render_inline_group(buf, group, line_cursor_col)
        end

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

                local srow, _, erow, _ = node:range()
                table.insert(module.private.formula_ranges[buf], { srow, erow })

                -- When the cursor is on a content line (not the @math or @end
                -- tag), clear the baseline overlay and reveal the raw text at
                -- the baseline, while keeping the virtual lines above/below.
                -- Hovering on the @math or @end tags does NOT reveal the block.
                local cursor_inside = cursor_row ~= nil
                    and cursor_row > srow and cursor_row < erow
                render_math_block(buf, node, cursor_inside)
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
    module.private.last_cursor_col = {}
end

local function toggle_rendering()
    if module.private.do_render then
        disable_rendering()
    else
        enable_rendering()
    end
end

-- ─── module.load ─────────────────────────────────────────────────────────────

--- Define (or re-define) the highlight groups used for rendered formulas.
--- Called on load and again whenever the colorscheme or `background` changes,
--- since those events clear all highlight groups.
local function define_highlights()
    vim.api.nvim_set_hl(0, "NeorgNablaVar",        { italic = true, default = true })
    vim.api.nvim_set_hl(0, "NeorgNablaSym",        { italic = true, default = true })
    vim.api.nvim_set_hl(0, "NeorgNablaFun",        { default = true })
    vim.api.nvim_set_hl(0, "NeorgNablaBold",       { bold = true,   default = true })
    vim.api.nvim_set_hl(0, "NeorgNablaBoldItalic", { bold = true, italic = true, default = true })
    vim.api.nvim_set_hl(0, "NeorgNablaNumber",     { default = true })
    vim.api.nvim_set_hl(0, "NeorgNablaOperator",   { default = true })
    vim.api.nvim_set_hl(0, "NeorgNablaDelimiter",  { default = true })
end

module.load = function()
    module.private.ns = vim.api.nvim_create_namespace("neorg-nabla")
    module.private.do_render = module.config.public.render_on_enter
    module.private.render_timers = {}
    module.private.formula_ranges = {}
    module.private.last_cursor_row = {}
    module.private.last_cursor_col = {}

    -- Define highlight groups for LaTeX-style rendering.  Each nabla grid node
    -- type has its own group so users can customise them independently.
    -- The defaults follow standard LaTeX math-mode conventions: variables and
    -- Greek letters are italic; named functions (cos, sin, …) are upright;
    -- \mathbf is bold; \boldsymbol is bold+italic; numbers, operators, and
    -- delimiters are upright.
    -- Using `default = true` so users can override with their own styles.
    define_highlights()

    -- Register the autocommands neorg should forward to us
    module.required["core.autocommands"].enable_autocommand("BufWinEnter")
    module.required["core.autocommands"].enable_autocommand("BufReadPost")
    module.required["core.autocommands"].enable_autocommand("InsertLeave")
    module.required["core.autocommands"].enable_autocommand("TextChanged")

    -- Use native autocommands for high-frequency cursor events so we avoid
    -- the overhead of the Neorg event dispatch on every cursor movement.
    module.private.aug = vim.api.nvim_create_augroup("neorg-nabla-cursor", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = module.private.aug,
        callback = function(args)
            local buf = args.buf
            if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].ft ~= "norg" then
                return
            end
            handle_cursor_move(buf)
        end,
    })
    -- InsertEnter needs an unconditional re-render so the mode change
    -- (normal→insert) immediately switches to insert-mode behavior
    -- (hide virtual lines on cursor line).
    vim.api.nvim_create_autocmd("InsertEnter", {
        group = module.private.aug,
        callback = function(args)
            local buf = args.buf
            if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].ft ~= "norg" then
                return
            end
            if module.private.do_render then
                module.public.render(buf)
            end
        end,
    })

    -- Re-define highlights when the colorscheme or background option changes,
    -- since those events clear all user-defined highlight groups.
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = module.private.aug,
        callback = define_highlights,
    })
    vim.api.nvim_create_autocmd("OptionSet", {
        group = module.private.aug,
        pattern = "background",
        callback = define_highlights,
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
