local wezterm = require("wezterm")

return {
  keys = {
    {
      key = "a",
      mods = "CMD",
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
