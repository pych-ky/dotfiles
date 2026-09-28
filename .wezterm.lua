-- WezTerm キー設定

local wezterm = require("wezterm")

return {
  -- TUI が要求する Kitty keyboard protocol に対応
  enable_kitty_keyboard = true,
  keys = {
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
    -- Home/End は全画面 TUI に送り、通常画面ではスクロールバックを移動
    {
      key = "Home",
      mods = "NONE",
      action = wezterm.action_callback(function(window, pane)
        local action = pane:is_alt_screen_active()
          and wezterm.action.SendKey({ key = "Home", mods = "CTRL" })
          or wezterm.action.ScrollToTop
        window:perform_action(action, pane)
      end),
    },
    {
      key = "End",
      mods = "NONE",
      action = wezterm.action_callback(function(window, pane)
        local action = pane:is_alt_screen_active()
          and wezterm.action.SendKey({ key = "End", mods = "CTRL" })
          or wezterm.action.ScrollToBottom
        window:perform_action(action, pane)
      end),
    },
    -- アプリ内のセッション先頭・末尾へのジャンプを送り、スクロールバックの先頭・末尾へ移動
    {
      key = "Home",
      mods = "CMD",
      action = wezterm.action.Multiple({
        wezterm.action.SendKey({ key = "Home", mods = "CTRL" }),
        wezterm.action.ScrollToTop,
      }),
    },
    {
      key = "End",
      mods = "CMD",
      action = wezterm.action.Multiple({
        wezterm.action.SendKey({ key = "End", mods = "CTRL" }),
        wezterm.action.ScrollToBottom,
      }),
    },
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
    -- Ghostty・Orca の標準キーと下分割の共通キーを追加
    {
      key = "d",
      mods = "CMD",
      action = wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }),
    },
    {
      key = "d",
      mods = "CMD|SHIFT",
      action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }),
    },
    {
      key = "d",
      mods = "ALT|SHIFT",
      action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }),
    },
    -- Cmd+W でタブ全体ではなく現在のペインを閉じる
    {
      key = "w",
      mods = "CMD",
      action = wezterm.action.CloseCurrentPane({ confirm = true }),
    },
  },
}
