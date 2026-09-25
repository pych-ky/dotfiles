local wezterm = require("wezterm")

return {
  -- TUI が要求する Kitty keyboard protocol に対応
  enable_kitty_keyboard = true,
  keys = {
    -- スクロールバックを含めて全選択し、通常モードへ戻る
    {
      key = "a",
      mods = "CMD",
      action = wezterm.action_callback(function(window, pane)
        window:perform_action(wezterm.action.ActivateCopyMode, pane)
        window:perform_action(
          wezterm.action.Multiple({
            wezterm.action.CopyMode("ClearSelectionMode"),
            wezterm.action.CopyMode("MoveToScrollbackTop"),
            wezterm.action.CopyMode({ SetSelectionMode = "Line" }),
            wezterm.action.CopyMode("MoveToScrollbackBottom"),
            wezterm.action.CopyMode("Close"),
          }),
          pane
        )
      end),
    },
    -- Cmd+←/→ で単語移動
    {
      key = "LeftArrow",
      mods = "CMD",
      action = wezterm.action.SendString("\x1bb"),
    },
    {
      key = "RightArrow",
      mods = "CMD",
      action = wezterm.action.SendString("\x1bf"),
    },
    -- Cmd+R で履歴検索
    {
      key = "r",
      mods = "CMD",
      action = wezterm.action.SendKey({ key = "r", mods = "CTRL" }),
    },
  },
}
