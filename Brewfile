# ============================================================================
# Homebrew パッケージマニフェスト (brew bundle --file=Brewfile で一括導入)
# ============================================================================

# ----------------------------------------------------------------------------
# サードパーティ tap
# ----------------------------------------------------------------------------
tap "hudochenkov/sshpass"
tap "terraform-linters/tap"

# ----------------------------------------------------------------------------
# CLI (formula)
# ----------------------------------------------------------------------------

# シェル / ターミナル UX
brew "bash"
brew "starship"
brew "fzf"
brew "zoxide"
brew "tmux"

# 基本ユーティリティ
brew "tree"
brew "jq"
brew "shfmt"
brew "duti"

# Git / GitHub
brew "git"
brew "git-lfs"
brew "gibo"
brew "gh"

# ランタイム / パッケージツール
brew "node"
brew "uv"

# クラウド / IaC / ポリシー / Kubernetes
brew "awscli"
brew "tfenv"
brew "terragrunt"
brew "opa"
brew "helm"
brew "kubernetes-cli", link: false
brew "openshift-cli"
brew "rosa-cli"
brew "trivy"

# DB / その他
# libpq の PATH 追加は .zshrc 側では行っていない (必要時: export PATH="$(brew --prefix libpq)/bin:$PATH")
brew "libpq"
brew "hudochenkov/sshpass/sshpass", trusted: true

# ----------------------------------------------------------------------------
# GUI アプリ (cask)
# ----------------------------------------------------------------------------

# ブラウザ
cask "google-chrome"

# ターミナル
cask "wezterm"
cask "warp"

# 開発エディタ / AI ツール
cask "visual-studio-code" # 設定・拡張は VS Code Settings Sync 側で管理
cask "claude"
cask "codex"

# コミュニケーション / コラボレーション
cask "slack"
cask "notion"
cask "obsidian"

# DB ツール
cask "dbeaver-community"

# 入力 / ウィンドウ管理 / 自動化
cask "karabiner-elements"
cask "typeless"
cask "rectangle"
cask "hammerspoon"
cask "raycast"

# ユーティリティ
cask "appcleaner"
cask "licecap"
cask "logi-options+"

# セキュリティ / パスワード管理
cask "1password"

# コンテナ / 仮想化
cask "docker-desktop"

# IaC linter (cask 配布)
cask "terraform-linters/tap/tflint", trusted: true

# ----------------------------------------------------------------------------
# npm グローバル (MCP サーバー)
# ----------------------------------------------------------------------------
npm "@modelcontextprotocol/server-github"
npm "@upstash/context7-mcp"
npm "chrome-devtools-mcp"
