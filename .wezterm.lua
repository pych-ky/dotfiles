local wezterm = require("wezterm")

return {
  -- TUI が要求する Kitty keyboard protocol に対応
  enable_kitty_keyboard = true,
  keys = {
    -- メニューを介さず選択をコピーし、未選択なら中断
    {
      key = "c",
      mods = "CMD",
      action = wezterm.action_callback(function(window, pane)
        local text = window:get_selection_text_for_pane(pane)
        if text ~= "" then
          window:copy_to_clipboard(text, "Clipboard")
        else
          window:perform_action(wezterm.action.SendKey({ key = "c", mods = "CTRL" }), pane)
        end
      end),
    },
    -- Cmd+A/E/R を Ctrl+A/E/R として送信
    {
      key = "a",
      mods = "CMD",
      action = wezterm.action.SendKey({ key = "a", mods = "CTRL" }),
    },
    {
      key = "e",
      mods = "CMD",
      action = wezterm.action.SendKey({ key = "e", mods = "CTRL" }),
    },
    {
      key = "r",
      mods = "CMD",
      action = wezterm.action.SendKey({ key = "r", mods = "CTRL" }),
    },
    -- 標準の「全選択」が含めないスクロールバックもコピー
    {
      key = "a",
      mods = "CMD|SHIFT",
      action = wezterm.action_callback(function(window, pane)
        local dims = pane:get_dimensions()
        local text = pane:get_text_from_region(
          0,
          dims.scrollback_top,
          0,
          dims.scrollback_top + dims.scrollback_rows
        )

        window:copy_to_clipboard(text:match("^%s*(.-)%s*$"))
      end),
    },
  },
}
