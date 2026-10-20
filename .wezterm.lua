-- WezTerm キー設定

local wezterm = require("wezterm")
local act = wezterm.action

-- Home/End の画面別キー設定
local function home_end(key, scroll)
  -- TUI はキー送信、通常画面はスクロール
  return wezterm.action_callback(function(window, pane)
    local action = pane:is_alt_screen_active()
      and act.SendKey({ key = key, mods = "CTRL" })
      or scroll
    window:perform_action(action, pane)
  end)
end

return {
  enable_kitty_keyboard = true,
  keys = {
    -- Karabiner の Option キー変換で単語移動・削除
    {
      key = "LeftArrow",
      mods = "ALT",
      action = act.SendString("\x1bb"),
    },
    {
      key = "RightArrow",
      mods = "ALT",
      action = act.SendString("\x1bf"),
    },
    {
      key = "Backspace",
      mods = "ALT",
      action = act.SendString("\x1b\x7f"),
    },
    {
      key = "Home",
      mods = "NONE",
      action = home_end("Home", act.ScrollToTop),
    },
    {
      key = "End",
      mods = "NONE",
      action = home_end("End", act.ScrollToBottom),
    },
    -- セッション先頭・末尾とスクロールバックを同時に移動
    {
      key = "Home",
      mods = "CMD",
      action = act.Multiple({
        act.SendKey({ key = "Home", mods = "CTRL" }),
        act.ScrollToTop,
      }),
    },
    {
      key = "End",
      mods = "CMD",
      action = act.Multiple({
        act.SendKey({ key = "End", mods = "CTRL" }),
        act.ScrollToBottom,
      }),
    },
    {
      key = "a",
      mods = "CMD",
      -- スクロールバック全体を選択し、通常モードへ戻す
      -- overlay を解決し直すため CopyMode 起動と操作を分ける
      action = wezterm.action_callback(function(window, pane)
        window:perform_action(act.ActivateCopyMode, pane)
        window:perform_action(
          act.Multiple({
            act.CopyMode("ClearSelectionMode"),
            act.CopyMode("MoveToScrollbackTop"),
            act.CopyMode({ SetSelectionMode = "Line" }),
            act.CopyMode("MoveToScrollbackBottom"),
            act.CopyMode("Close"),
          }),
          pane
        )
      end),
    },
    {
      key = "d",
      mods = "CMD",
      action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }),
    },
    {
      key = "d",
      mods = "CMD|SHIFT",
      action = act.SplitVertical({ domain = "CurrentPaneDomain" }),
    },
    {
      key = "d",
      mods = "ALT|SHIFT",
      action = act.SplitVertical({ domain = "CurrentPaneDomain" }),
    },
    {
      key = "w",
      mods = "CMD",
      action = act.CloseCurrentPane({ confirm = true }),
    },
  },
}
