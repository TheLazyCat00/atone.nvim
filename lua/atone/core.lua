local api, fn = vim.api, vim.fn
local diff = require("atone.diff")
local config = require("atone.config")
local tree = require("atone.tree")
local utils = require("atone.utils")
local state = require("atone.state")

local M = {
    _show = nil,
    attach_buf = nil,
    augroup = api.nvim_create_augroup("atone", { clear = true }),
    is_resizing = false
}

local TREE_PADDING = 5

--- position the cursor at a specific node in the tree graph
---@param id integer
local function pos_cursor_by_id(id)
    local compact = config.opts.ui.compact
    if id <= 0 then
        api.nvim_win_set_cursor(state.tree_win, { compact and tree.total or tree.total * 2 - 1, 0 })
    elseif id <= tree.total then
        local lnum = compact and tree.total - id + 1 or (tree.total - id) * 2 + 1
        local column = tree.nodes[tree.id_2seq(id)].depth * 2 - 1
        column = vim.str_byteindex(tree.lines[lnum], "utf-16", column - 1)
        api.nvim_win_set_cursor(state.tree_win, { lnum, column })
    end
end

---@param seq integer
local function undo_to(seq)
    api.nvim_buf_call(M.attach_buf, function()
        vim.cmd("silent undo " .. seq)
    end)
end

--- get the id under cursor in _tree_win
--- when the cursor is between two nodes, return the average (of their id).
---@return integer
local function id_under_cursor()
    -- compact: total - cur_id + 1 = lnum
    -- otherwise: 2 * (total - cur_id) + 1 = lnum
    local lnum = api.nvim_win_get_cursor(state.tree_win)[1]
    return config.opts.ui.compact and tree.total - lnum + 1 or tree.total - (lnum - 1) / 2
end

--- get the seq under cursor in _tree_win
--- when the cursor is between two nodes, return nil
---@return integer|nil
local function seq_under_cursor()
    local id = id_under_cursor()
    if id % 1 ~= 0 then
        return nil
    end
    return tree.id_2seq(id)
end

local used_mappings = {}
local mappings = {
    quit = {
        function()
            M.close()
        end,
        "Close all atone windows",
    },
    quit_help = {
        function()
            pcall(api.nvim_win_close, state.float_win, true)
        end,
        "Close help window",
    },
    next_node = {
        function()
            pos_cursor_by_id(math.ceil(id_under_cursor()) - vim.v.count1)
        end,
        "Jump to next node (v:count supported)",
    }, -- support v:count
    pre_node = {
        function()
            pos_cursor_by_id(math.floor(id_under_cursor()) + vim.v.count1)
        end,
        "Jump to previous node (v:count supported)",
    }, -- support v:count
    jump_to_G = {
        function()
            pos_cursor_by_id(tree.seq_2id(vim.v.count))
        end,
        "Jump to the node with the specified sequence number like G",
    },
    jump_to_gg = {
        function()
            local target_seq = vim.v.count == 0 and tree.last_seq or vim.v.count
            pos_cursor_by_id(tree.seq_2id(target_seq))
        end,
        "Jump to the node with the specified sequence number like gg",
    },
    undo_to = {
        function()
            local seq = seq_under_cursor()
            if seq then
                undo_to(seq)
                M.refresh()
            end
        end,
        "Undo to the node under cursor",
    },
    help = {
        function()
            M.show_help()
        end,
        "Show help page",
    },
}

local function init()
    state.tree_buf = utils.new_buf()
    state.auto_diff_buf = utils.new_buf()
    state.help_buf = utils.new_buf()
    state.dummy_buf = utils.new_buf()
    if config.opts.diff_cur_node.enabled then
        api.nvim_set_option_value("syntax", "diff", { buf = state.auto_diff_buf })
    end


    if config.opts.diff_cur_node.enabled then
        api.nvim_create_autocmd("CursorMoved", {
            buffer = state.tree_buf,
            group = M.augroup,
            callback = vim.schedule_wrap(function()
                pcall(function()
                    local pre_seq = tree.nodes[seq_under_cursor()].parent or -1
                    local before_ctx = diff.get_context_by_seq(M.attach_buf, pre_seq)
                    ---@diagnostic disable-next-line: param-type-mismatch
                    local cur_ctx = diff.get_context_by_seq(M.attach_buf, seq_under_cursor())
                    local diff_ctx = diff.get_diff(before_ctx, cur_ctx)
                    utils.set_text(state.auto_diff_buf, diff_ctx)
                end)
            end),
        })
    end

    api.nvim_create_autocmd("WinClosed", {
        buffer = state.tree_buf,
        group = M.augroup,
        callback = M.close,
    })
    api.nvim_create_autocmd("WinClosed", {
        buffer = state.auto_diff_buf,
        group = M.augroup,
        callback = M.close,
    })
    -- Auto-focus diff window when dummy window is entered
    api.nvim_create_autocmd("WinEnter", {
        buffer = state.dummy_buf,
        group = M.augroup,
        callback = function()
            if api.nvim_win_is_valid(state.diff_win) then
                api.nvim_set_current_win(state.diff_win)
            end
        end,
    })

    api.nvim_create_autocmd("WinClosed", {
        group = M.augroup,
        callback = function()
            if M._show then
                vim.schedule(M.update_layout)
            end
        end,
    })

    api.nvim_create_autocmd("VimResized", {
        group = M.augroup,
        callback = function()
            if M._show then
                M.update_layout()
            end
        end,
    })

    -- register keymaps
    local keymaps_conf = config.opts.keymaps
    for action, lhs in pairs(keymaps_conf.tree) do
        utils.keymap("n", lhs, mappings[action][1], { buffer = state.tree_buf })
        used_mappings[action] = { lhs, mappings[action][2] }
    end
    for action, lhs in pairs(keymaps_conf.auto_diff) do
        utils.keymap("n", lhs, mappings[action][1], { buffer = state.auto_diff_buf })
        used_mappings[action] = { lhs, mappings[action][2] }
    end
    for action, lhs in pairs(keymaps_conf.help) do
        utils.keymap("n", lhs, mappings[action][1], { buffer = state.help_buf })
        used_mappings[action] = { lhs, mappings[action][2] }
    end
end

---@param strings string[]
---@return integer
local function max_length(strings)
    local length = 0
    for _, s in ipairs(strings) do
        if #s > length then
            length = #s
        end
    end
    return length
end

local function get_tree_width()
    local width = config.opts.layout.width
    if width == "adaptive" then
        local lines = api.nvim_buf_get_lines(state.tree_buf, 0, 1, false)
        return max_length(lines) + TREE_PADDING
    elseif width < 1 then
        return math.floor(vim.o.columns * width + 0.5) + TREE_PADDING
    else
        return math.floor(width) + TREE_PADDING
    end
end

---@param win integer
---@return boolean
local function win_exists(win)
    return win and api.nvim_win_is_valid(win)
end

---@param direction string
---@return string
local function get_anchor(direction)
    local anchors = {
        left = "SW",
        right = "SE"
    }

    return anchors[direction]
end

---@param direction string
---@return integer
local function get_col(direction)
    ---@type table<string, fun(): integer>
    local layouts = {
        left = function ()
            local col = 0
            return col
        end,
        right = function ()
            local dummy_width = api.nvim_win_get_width(state.dummy_win)
            local col = dummy_width
            return col
        end
    }

    return layouts[direction]()
end

function M.update_layout()
    if not M._show then
        return
    end

    -- Enforce tree width
    local target_width = get_tree_width()
    api.nvim_win_set_width(state.tree_win, target_width)

    local diff_width_conf = config.opts.diff_cur_node.width
    if diff_width_conf == "adaptive" then
        return
    end

    if not (win_exists(state.diff_win) and win_exists(state.dummy_win)) then
        return
    end

    local diff_width = 0
    if diff_width_conf < 1 then
        diff_width = math.floor(vim.o.columns * diff_width_conf + 0.5)
    else
        diff_width = math.floor(diff_width_conf)
    end

    local col = get_col(config.opts.layout.direction)
    local anchor = get_anchor(config.opts.layout.direction)

    -- Ensure at least 1 column
    diff_width = math.max(1, diff_width)

    local height = math.floor(api.nvim_win_get_height(state.tree_win) * config.opts.diff_cur_node.split_percent + 0.5)
    api.nvim_win_set_config(state.diff_win, {
        width = diff_width,
        height = height,
        relative = "win",
        win = state.dummy_win,
        anchor = anchor,
        row = height,
        col = col,
    })
    api.nvim_win_set_height(state.dummy_win, height)
end

local function check()
    if api.nvim_buf_is_valid(state.auto_diff_buf) and api.nvim_buf_is_valid(state.tree_buf) and api.nvim_buf_is_valid(state.help_buf) then
        return true
    end
    M.close()
    pcall(api.nvim_buf_delete, state.tree_buf, { force = false })
    pcall(api.nvim_buf_delete, state.auto_diff_buf, { force = false })
    pcall(api.nvim_buf_delete, state.help_buf, { force = false })
    pcall(api.nvim_buf_delete, state.dummy_buf, { force = false })
end

function M.open()
    if M._show == nil or not check() then
        init()
    end

    if M._show then
        M.focus()
        return
    end

    M._show = true
    M.attach_buf = api.nvim_get_current_buf()

    local directions = {
        left = "topleft",
        right = "botright"
    }
    local direction = directions[config.opts.layout.direction]

    local width = get_tree_width()
    state.tree_win = utils.new_win(direction .. " vsplit", state.tree_buf, { width = width })
    if config.opts.diff_cur_node.enabled then
        local height = math.floor(api.nvim_win_get_height(state.tree_win) * config.opts.diff_cur_node.split_percent + 0.5)
        local diff_width_conf = config.opts.diff_cur_node.width

        local use_float = false
        local diff_width = 0

        if diff_width_conf == "adaptive" or diff_width_conf == nil then
            use_float = false
        else
            use_float = true
            if diff_width_conf < 1 then
                diff_width = math.floor(vim.o.columns * diff_width_conf + 0.5)
            else
                diff_width = math.floor(diff_width_conf)
            end
        end

        if use_float then
            state.dummy_win = utils.new_win("belowright split", state.dummy_buf, { height = height }, false)

            local anchor = get_anchor(config.opts.layout.direction)
            local col = get_col(config.opts.layout.direction)

            local border = config.opts.ui.border
            if type(border) == "string" and border ~= "none" then
                local borders = {
                    single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
                    double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
                    rounded ={ "╭", "─", "╮", "│", "╯", "─", "╰", "│" }
                }

                local border_chars = borders[border]

                local remove_border_chars = {
                    left = function ()
                        -- Layout is left: tree on left, diff at bottom-left
                        -- "Editor borders" are Left and Bottom
                        -- Remove Left (8), Bottom (6), and Bottom-Left corner (7)
                        border_chars[8] = ""
                        border_chars[6] = ""
                        border_chars[7] = ""
                    end,
                    right = function ()
                        -- Layout is right: tree on right, diff at bottom-right
                        -- "Editor borders" are Right and Bottom
                        -- Remove Right (4), Bottom (6), and Bottom-Right corner (5)
                        border_chars[4] = ""
                        border_chars[6] = ""
                        border_chars[5] = ""
                    end
                }
                remove_border_chars[config.opts.layout.direction]()
                border = border_chars
            end

            state.diff_win = utils.new_win("float", state.auto_diff_buf, {
                float = {
                    relative = "win",
                    win = state.dummy_win,
                    anchor = anchor,
                    row = api.nvim_win_get_height(state.dummy_win),
                    col = col,
                    width = diff_width,
                    height = height,
                    style = "minimal",
                    border = border,
                    zindex = 10,
                }
            }, false)
            M.update_layout()
        else
            state.diff_win = utils.new_win("belowright split", state.auto_diff_buf, { height = height }, false)
        end
    end

    api.nvim_win_call(state.tree_win, function()
        fn.matchadd("AtoneSeqBracket", [=[\v\[\d+\]]=])
        fn.matchadd("AtoneSeq", [=[\v\[\zs\d+\ze\]]=])
    end)
    M.refresh()
end

function M.refresh()
    if M._show then
        tree.convert(M.attach_buf)
        local buf_lines = tree.render()
        if config.opts.layout.width == "adaptive" then
            api.nvim_win_set_config(state.tree_win, { width = max_length(buf_lines) + TREE_PADDING })
        end
        utils.set_text(state.tree_buf, buf_lines)

        -- Update layout on refresh (in case tree resized)
        if api.nvim_win_is_valid(state.diff_win) and api.nvim_win_get_config(state.diff_win).relative ~= "" then
            M.update_layout()
        end

        pos_cursor_by_id(tree.seq_2id(tree.cur_seq))

        local cur_line = api.nvim_win_get_cursor(state.tree_win)[1]
        utils.color_char(
            state.tree_buf,
            "AtoneCurrentNode",
            buf_lines[cur_line],
            cur_line,
            tree.nodes[tree.cur_seq].depth * 2 - 1
        )

        local pre_seq = tree.nodes[tree.cur_seq].parent or -1
        local before_ctx = diff.get_context_by_seq(M.attach_buf, pre_seq)
        local cur_ctx = diff.get_context_by_seq(M.attach_buf, tree.cur_seq)
        local diff_ctx = diff.get_diff(before_ctx, cur_ctx)
        utils.set_text(state.auto_diff_buf, diff_ctx)
    end
end

function M.show_help()
    -- set context for help buffer
    local help_lines = {}
    local max_lhs = 0
    local max_line = 0
    for _, v in pairs(used_mappings) do
        local lhs = v[1]
        local desc = v[2]
        if type(lhs) == "table" then
            lhs = table.concat(lhs, "/")
        end
        max_lhs = math.max(max_lhs, vim.api.nvim_strwidth(lhs))
        max_line = math.max(max_line, #lhs + #desc)
        help_lines[#help_lines + 1] = lhs .. "\t" .. desc
    end
    max_line = max_line + max_lhs + 4
    api.nvim_set_option_value("vartabstop", tostring(max_lhs + 4), { buf = state.help_buf })
    utils.set_text(state.help_buf, help_lines)

    -- open help window
    local editor_columns = api.nvim_get_option_value("columns", {})
    local editor_lines = api.nvim_get_option_value("lines", {})
    state.float_win = utils.new_win("float", state.help_buf, {
        float = {
            relative = "editor",
            row = math.max(0, (editor_lines - #help_lines) / 2),
            col = math.max(0, (editor_columns - max_line - 1) / 2),
            width = math.min(editor_columns, max_line + 1),
            height = math.min(editor_lines, #help_lines),
            zindex = 150,
            style = "minimal",
            border = config.opts.ui.border,
        },
        autoclose = true
    })
end

function M.close()
    if M._show then
        M._show = false
        pcall(api.nvim_win_close, state.tree_win, true)
        pcall(api.nvim_win_close, state.diff_win, true)
        pcall(api.nvim_win_close, state.float_win, true)
        pcall(api.nvim_win_close, state.dummy_win, true)
    end
end

function M.focus()
    if M._show then
        pos_cursor_by_id(tree.seq_2id(tree.cur_seq))
        api.nvim_set_current_win(state.tree_win)
    end
end

function M.toggle()
    if M._show then
        M.close()
    else
        M.open()
    end
end

return M
