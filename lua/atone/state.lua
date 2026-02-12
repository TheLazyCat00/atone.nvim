-- _float_win: we have one float window only at the same time
-- _auto_diff_buf: diff result triggered automatically, shown in the window below tree graph

local state = {
    tree_win = nil,
    float_win = nil,
    diff_win = nil,
    tree_buf = nil,
    help_buf = nil,
    auto_diff_buf = nil,
    dummy_win = nil,
    dummy_buf = nil
}

return state
