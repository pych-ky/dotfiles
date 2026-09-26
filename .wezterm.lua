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
    -- Karabiner が変換した Option キーで単語移動・削除
    {
      key = "LeftArrow",
      mods = "ALT",
      action = wezterm.action.SendString("\x1bb"),
    },
    {
      key = "RightArrow",
      mods = "ALT",
      action = wezterm.action.SendString("\x1bf"),
    },
    {
      key = "Backspace",
      mods = "ALT",
      action = wezterm.action.SendString("\x1b\x7f"),
    },
    {
      key = "w",
      mods = "CMD",
      action = wezterm.action.CloseCurrentPane({ confirm = true }),
    },
    -- Orca と同じキーで右・下へ分割
    {
      key = "d",
      mods = "CMD|SHIFT",
      action = wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }),
    },
    {
      key = "d",
      mods = "ALT|SHIFT",
      action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }),
    },
  },
}
