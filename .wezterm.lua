local wezterm = require("wezterm")

return {
  -- TUI から要求された Kitty keyboard protocol のキーエンコーディングを有効化
  enable_kitty_keyboard = true,
  keys = {
    -- CMD+C: 選択中はメニュー処理を介さずコピーし、選択がなければ中断
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
    -- CMD+SHIFT+A: 標準の「全選択」では取り切れないスクロールバック全体をクリップボードへコピー
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

        -- 前後の空白・空行をトリムしたうえでクリップボードへコピー
        window:copy_to_clipboard(text:match("^%s*(.-)%s*$"))
      end),
    },
  },
}
