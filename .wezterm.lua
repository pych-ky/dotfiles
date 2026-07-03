local wezterm = require("wezterm")

return {
  keys = {
    -- CMD+A: 標準の「全選択」では取り切れないスクロールバック全体をクリップボードへコピー
    {
      key = "a",
      mods = "CMD",
      action = wezterm.action_callback(function(window, pane)
        local dims = pane:get_dimensions()
        -- スクロールバックの先頭から末尾までを 1 つの選択範囲として取得
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
