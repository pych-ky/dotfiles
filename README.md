# dotfiles

個人用の macOS 環境を構築する dotfiles です。
`bootstrap.sh` で、OS 設定、シンボリックリンク、Homebrew、CLI、Git、非公開の Codex Custom Pets と Agent Skills をまとめてセットアップします。

## 一括セットアップ

### 前提条件

- macOS
- 対話可能なローカル端末
- `sudo` を実行できるユーザー
- このリポジトリへのアクセス

`bootstrap.sh` と、そこから呼び出す `macos/defaults.sh`、`scripts/link-dotfiles.sh`、`scripts/setup-git.sh` に `sudo` を付けないでください。

### 実行

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

### 処理内容

1. `sudo` 認証を行う
2. `macos/defaults.sh` で macOS 設定を適用する
3. `scripts/link-dotfiles.sh` でシンボリックリンクを展開する
4. Homebrew を導入する。
   未導入時は Xcode Command Line Tools も導入する
5. `macos/Brewfile` に不足する CLI・GUI アプリをインストールする
6. `mise install` でグローバル開発ツール（node、go、terraform など）を導入する
7. `scripts/setup-git.sh` で Git 共通設定を適用する
8. `zsh-autosuggestions` と `fast-syntax-highlighting` を取得する
9. 未導入の Claude Code CLI と Codex CLI を導入する
10. アクセス可能な非公開 Codex Custom Pets を取得し、収録されている全ペットをインストールする
11. アクセス可能な非公開 Agent Skills を取得し、管理 CLI で同期する
12. アクセス可能な非公開 dotfiles-private（組織固有・個人設定）を取得し、適用する

終了後は「手動セットアップ」も行ってください。

### 失敗と再実行

各処理は原則として冪等なため、途中で失敗しても再実行できます。

- 実行環境の検証または最初の `sudo` 認証に失敗すると、その場で終了する
- 独立した処理は失敗を記録して続行し、最後に一覧を表示して非ゼロで終了する
- 前提が揃わず**実行しなかった**処理（mise 未導入、非公開リポジトリへアクセス不可など）は
  「skipped steps」として一覧に出す。失敗ではないので終了状態は 0 だが、
  1 件でもあれば「完了」とは表示しない（未実行を見落とさないため）
- `sudo` のタイムスタンプはバックグラウンドで延長せず、終了時に無効化する
- 各特権処理は有効なタイムスタンプを再利用し、失効時や Homebrew cask の要求時は再認証する
- Homebrew、Claude Code、Codex のリモートインストーラは、取得後に実行する

## 個別セットアップ

### シンボリックリンク

```sh
./scripts/link-dotfiles.sh --dry-run   # 事前確認のみ
./scripts/link-dotfiles.sh             # リンク作成
```

- 既存の通常ファイルとディレクトリは `~/.dotfiles-backup/<timestamp>[-<sequence>]/` に退避する
- 退避したファイルがリポジトリ版と内容が異なる場合は、実行末尾に警告を表示する。
  端末ローカルの変更はリポジトリか `~/.zshrc.local` などへ統合してから再リンクする
- 同じ秒の再実行は連番で別世代にし、スクリプトが生成した最新 5 世代だけを保持する
- 同じ `HOME` への並行実行は排他ロックで直列化する
- 既存のシンボリックリンクはリンク先が異なる場合のみ張り替える
- Karabiner が変更を検知できるよう、`.config/karabiner` はディレクトリごとリンクする
- 共通エージェントルールは `.config/agents/AGENTS.md` を正本とし、`~/.config/agents/AGENTS.md` と `~/.codex/AGENTS.md` から参照する
- Codex の基本設定を `sudo` で `/etc/codex/config.toml` にリンクし、端末固有の `~/.codex/config.toml` で上書き可能にする
- 管理対象の正確な一覧は `scripts/link-dotfiles.sh` を参照する

### Git 共通設定

Git 2.37 以上が必要です。

```sh
./scripts/setup-git.sh
```

`~/.gitconfig` 全体は置き換えず、共通化する以下の項目だけを設定します。
`user.name` / `user.email` は公開リポジトリに個人情報を置かないため、ここでは設定せず `~/.gitconfig.local`（非公開側）で設定します。

- `user.useConfigOnly`: 名前やメールの自動推測を無効にする（identity は `~/.gitconfig.local` で明示的に設定する）
- `fetch.prune`: `git fetch` 時に削除済みリモートブランチの追跡参照を削除する
- `init.defaultBranch`: 新しいリポジトリの最初のブランチ名を `main` にする
- `branch.autoSetupMerge`: 同名のリモートブランチだけを自動追跡する
- `push.default`: 同名のブランチだけを push する
- `push.autoSetupRemote`: 初回 push 時に `upstream` を自動設定する
- `transfer.credentialsInUrl`: `<protocol>://<user>:<password>@...` 形式の URL を拒否する（`remote.*.pushurl` とユーザー名部分だけに指定したトークンは対象外）
- `pull.ff`: 履歴の分岐時は自動マージせず停止する
- `merge.conflictStyle`: 競合時に変更前・自分・相手を表示する
- `credential.https://github.com.helper`: GitHub の通常の認証を `!gh auth git-credential` に委譲する（下記「GitHub の認証」を参照）
- `credential.https://github.com.useHttpPath`: 認証時にリポジトリパスを helper へ渡す
- `include.path`: 組織固有設定の受け皿として `~/.gitconfig.local` を読み込む（存在しない間は無視される）
- `core.hooksPath`: `~/.local/share/dotfiles/git-hooks` を指定する（下記「グローバルフック」を参照）
- Git LFS が導入済みの場合は `git lfs install --skip-repo` でグローバルフィルタを有効化する

`transfer.credentialsInUrl` は `remote.*.pushurl` を対象にしないため、push URL を含め、URL にトークンやパスワードを埋め込まないでください（Git credential helper を使います）。

### GitHub の認証

GitHub へは HTTPS で接続し、通常の認証は `gh auth git-credential` に委譲します。SSH へは移行しません。

- 公開側は GitHub ホスト全体の helper を空値でリセットし、`!gh auth git-credential` を設定する
- 組織固有の URL に限り、非公開側（`~/.gitconfig.local`）で helper を空値でリセットして `!ghtkn git-credential` に切り替える。組織名や対象 URL は公開側に置かない
- [ghtkn](https://github.com/suzuki-shunsuke/ghtkn) の helper は GitHub App の User Access Token（有効期間 8 時間）を Git へ直接渡す
- ghtkn 本体は mise が導入する（`.config/mise/config.toml`）。Homebrew では管理しない
- 認証は**利用者が明示的に**開始する。AI エージェントから実行する場合は事前確認を経る

```sh
gh auth login --hostname github.com --git-protocol https
```

URL 限定の ghtkn helper を使う端末では、非公開側の設定に従って追加で認証します。

```sh
ghtkn init   # ~/.config/ghtkn/ghtkn.yaml を作成し、対象の GitHub App の Client ID を書く
ghtkn auth   # デバイスフローで認証する
```

- `gh auth token` / `gh auth git-credential` / `ghtkn get` / `ghtkn exec` / `ghtkn git-credential` の直接実行はトークンの取り出しになるため、AI エージェントには許可しない
- AI エージェントから使える範囲は、その操作がサンドボックスの外で走るかどうかで決まる
  - `git commit` / `git push`: `excludedCommands` でサンドボックス外を走るため helper が働く
  - `git fetch` / `git pull` / `git clone`: サンドボックス内で走り、helper がトークンの保管先（キーチェーン）へ到達できない。
    公開リポジトリは認証なしで成功するが、**非公開リポジトリでは失敗する**。
    待ち続けないよう `GIT_TERMINAL_PROMPT=0` を設定してあり、ハングはしない
  - `gh`: `excludedCommands` でサンドボックス外を走り、gh 自身が保管先からトークンを読む。
    トークンはエージェントへ渡らないため、`gh pr list` などは通常どおり使える。
    ただしこれは `gh auth login` が保管した**別系統のトークン**であり、ghtkn 経由ではない。
    認証を ghtkn へ一本化するには `gh` 用の broker か wrapper が別途要る（未実装）
- `gh` と `terraform` はサンドボックス外で走るため、任意コマンドの起動口を個別に塞いでいる。
  `gh alias` / `gh extension` / `gh config`、`terraform console`、既知でないサブコマンド、
  `--` 以降を git / ssh へ素通しする `gh repo clone` / `gh codespace ssh` は拒否する
- `git fetch` などを `excludedCommands` へ足せば非公開リポジトリでも動くが、
  サンドボックスを迂回できる範囲がその分広がる。限定した wrapper／ブローカーを用意するまでは足さない

### グローバルフック

`core.hooksPath` を設定すると、Git は各リポジトリの `.git/hooks` を参照しなくなります。
個別のフックを直接指定するとリポジトリ固有フックと Git LFS のフックが動かなくなるため、`scripts/setup-git.sh` が振り分け用のディレクトリ `~/.local/share/dotfiles/git-hooks` を作り、そこを参照させます。

| フック | 実行内容 |
| --- | --- |
| すべて | `git-hooks/dispatch`（gitleaks 検査 → denylist 検査 → リポジトリ固有フック → Git LFS のフック） |

- `pre-commit` は `gitleaks git --staged --redact` でステージ内容を検査する。
  `--redact` を付けるため、検出した値そのものは出力に載らない。
  gitleaks が未導入の端末では、検査漏れのままコミットさせないようコミットを中断する
- リポジトリ固有フックが失敗した場合は、その終了状態を伝播してコミットや push を中断する
- Git LFS が扱うフック（`pre-push`、`post-checkout`、`post-commit`、`post-merge`）は `git lfs <フック名>` を呼ぶ。
  そのため各リポジトリでの `git lfs install` は不要
- `pre-push` と `post-rewrite` は標準入力で情報を受け取るため、内容を保持して各実行先へ渡す
- 特定のリポジトリでグローバルな検査（gitleaks と下記の denylist）を止める場合は、`~/.local/share/dotfiles/IGNORE_GLOBAL_HOOKS` にそのリポジトリのパスを記載する（上流と同じ仕組み）。
  リポジトリ固有フックと Git LFS のフックは、そのリポジトリの動作そのものに必要なため止めない

#### 公開リポジトリへの混入防止（denylist）

`git-hooks/deny-private-strings` が、組織固有の識別子や過去の所属先の情報を公開リポジトリへコミット・push させないように止めます。
**判定パターンはこのリポジトリに置きません。**書いた時点で漏洩になるため、非公開側が以下へ配置します。

| ファイル | 内容 |
| --- | --- |
| `~/.config/dotfiles/denylist.txt` | 1 行 1 パターン。固定文字列として扱い、大文字小文字は区別しない。行頭 `#` と空行は無視する |
| `~/.config/dotfiles/work-remotes.txt` | 1 行 1 部分文字列。remote URL が**すべて**一致するリポジトリは組織のものとみなして検査しない |

- `denylist.txt` が無い端末では何もしません（公開リポジトリ単体でも動きます）
- `pre-commit` はステージ済みのパス名と、その index 上の**内容全体**を見ます。今回の差分だけでなく既存行の混入も止まります
- `pre-push` は push 対象コミットを**1 件ずつ**見ます。範囲の net diff ではないため、「あるコミットで追加し、後のコミットで消した」内容も検出します
- remote が 1 つも無いリポジトリは検査対象です
- 回避は `git commit --no-verify` / `git push --no-verify` のみです

### Homebrew パッケージ

```sh
brew bundle --no-upgrade --file=macos/Brewfile        # 不足パッケージのインストール
brew bundle upgrade --file=macos/Brewfile             # 管理対象パッケージのアップグレード
brew bundle check --no-upgrade --file=macos/Brewfile  # 不足パッケージの確認
brew bundle cleanup --file=macos/Brewfile             # Brewfile にないパッケージの確認 (削除は --force)
```

- `bootstrap.sh` は `formula` と `cask` を一括アップグレードしない。
  不足パッケージの依存関係は更新される場合がある
- Homebrew 本体とパッケージ情報は自動更新される
- 一部の GUI アプリ（ブラウザ、エディタ、コミュニケーションツールなど）は、別の手段で導入する端末があるため既定ではコメントアウトしてある。
  個人用端末など brew で導入したい場合はコメントアウトを外して `brew bundle` を再実行してよい
- `cleanup` は Brewfile の追加・削除を反映した後に、まず `--force` なしで削除候補を確認してから実行する（稼働中のツールを誤って削除しないため）
- グローバルの `pre-commit` は `gitleaks` を使うため、コミットする端末には gitleaks が必要

### macOS 設定

```sh
./macos/defaults.sh
```

- macOS の既定値から意図的に変える項目だけを `defaults write` で適用する。
  対象はキーボードのリピート速度、Dock、Finder、日本語入力など
- Rectangle の設定は、エクスポート済みの `macos/rectangle.plist` を読み込んで適用する
- ログイン時に開くアプリ（Rectangle、Typeless、Logi Options+）をログイン項目に登録する。
  初回は System Events へのオートメーション許可を求められる。許可しない端末では警告を出して続行する
- デスクトップのアイコンの並べ方のように入れ子の辞書に含まれる項目は、
  現在の設定を書き出して該当キーだけ差し替えてから読み込む（同じ辞書にある他の表示設定を失わないため）
- 電源管理（`pmset`）の変更は、認証済みの `sudo`（`sudo -n`）で実行する
- 日本語入力、外観（ダークモード）、ファンクションキーの設定は再ログイン後に反映される

### 非公開 Codex Custom Pets

#### 実行と動作

`bootstrap.sh` から呼び出されますが、単独でも実行できます。

```sh
./pets/setup.sh
```

未取得の場合は、非公開リポジトリを一時ディレクトリにクローンします。
リポジトリルート、`origin`、インストーラを検証して `$HOME/src/pych/codex-custom-pets` に配置します。
一括インストール対応版では `bin/install-pet --all` を実行し、未対応の旧版では収録ペットを個別にインストールします。

Git、jq、macOS 標準の `lockf` が必要です。
`sudo` は使いません。

#### 設定

初回クローン前のアクセス確認に失敗した場合は、既定で警告してスキップします。
以下の環境変数で動作を変更できます。

- `CODEX_CUSTOM_PETS_STRICT=1`: アクセス失敗時に `bootstrap.sh` も失敗させる
- `CODEX_CUSTOM_PETS_SKIP=1`: 導入をスキップする
- `CODEX_CUSTOM_PETS_REPO_URL`: クローン元を上書きする
- `CODEX_CUSTOM_PETS_REPO_DIR`: 保存先を絶対パスで上書きする
- `CODEX_HOME`: インストール先を上書きする。
  未指定時は `$HOME/.codex` になる

#### 更新

既存のチェックアウトは自動更新しません。

```sh
cd "${CODEX_CUSTOM_PETS_REPO_DIR:-$HOME/src/pych/codex-custom-pets}"
git switch main
git pull --ff-only
```

再実行時は現在のチェックアウトでペットを置き換え、既存ファイルを `${CODEX_HOME:-$HOME/.codex}/pets/.backups` に退避します。
インストール後は Codex の `Settings → Pets` で `Refresh` を実行してください。

### 非公開 Agent Skills

#### 実行と動作

`bootstrap.sh` から呼び出されますが、単独でも実行できます。

```sh
./skills/setup.sh
```

未取得の場合だけ、非公開リポジトリを一時ディレクトリにクローンします。
リポジトリルート、`origin`、管理 CLI を検証して `$HOME/src/pych/agent-skills` に配置し、公開コマンド `bin/agent-skills sync` を実行します。

Codex と Claude Code への初回インストール、既存設定の再同期、詳細な検証、`doctor` は `agent-skills` 側で行います。
Git、Python 3.9 以降、macOS 標準の `lockf` が必要です。
`sudo` は使いません。

#### 設定

初回クローン前のアクセス確認に失敗した場合は、既定で警告してスキップします。
以下の環境変数で動作を変更できます。

- `AGENT_SKILLS_STRICT=1`: アクセス失敗時に `bootstrap.sh` も失敗させる
- `AGENT_SKILLS_SKIP=1`: 導入をスキップする
- `AGENT_SKILLS_REPO_URL`: クローン元を上書きする
- `AGENT_SKILLS_REPO_DIR`: 保存先を絶対パスで上書きする

#### 更新と初期導入

既存のチェックアウトは `bootstrap.sh` から自動更新しません。
更新と再同期には、チェックアウト内で Agent Skills 自身のコマンドを実行します。

```sh
cd "$HOME/src/pych/agent-skills"
./bin/agent-skills update
```

Agent Skills リポジトリは dotfiles に依存せず、単体でも初期導入できます。

```sh
git clone https://github.com/pych-ky/agent-skills.git "$HOME/src/pych/agent-skills"
cd "$HOME/src/pych/agent-skills"
./bin/agent-skills sync
```

## 手動セットアップ

### システムとアプリ

- システム設定
  - プライバシーとセキュリティ > フルディスクアクセス / アクセシビリティ（Claude など必要なものだけ）
  - 一般 > ログイン項目と拡張機能 > 拡張機能（ログイン項目は `macos/defaults.sh` が登録する）
  - サウンド > 入出力デバイスの指定
  - キーボード > テキスト入力 > テキスト置換（ユーザー辞書）
    - `しかく` → `■` / `やじるし` → `→` / `かっこ` → `「」`
- Finder > 設定 > サイドバー > ホームにチェック
- Brewfile でコメントアウトしているアプリ（ブラウザ、エディタなど）を、端末に応じた方法で導入
- Rancher Desktop: Preferences > Application > PATH を Manual にする（`~/.rd/bin` の PATH は `.zshrc` / `.bashrc` 側で管理し、rc ファイルへの自動追記を防ぐ）
- VS Code: Settings Sync にサインイン（設定と拡張はこのリポジトリでは管理しない）。
  コマンドパレットから「Shell Command: Install 'code' command in PATH」を実行
- 各種アカウントにサインイン（1Password、Slack、Notion など）
- GitHub の通常の認証を `gh auth login` で用意する。
  URL 限定の ghtkn helper を使う端末では、非公開側の設定に従って `ghtkn init` / `ghtkn auth` も実行する。AI エージェントから実行する場合は確認を経る
- 個別インストーラからプリンタドライバを導入

## 非公開設定（dotfiles-private）

**このリポジトリは公開リポジトリです。** 所属組織に固有の設定と個人情報は置きません。

組織固有の設定（組織名を含む Git の `includeIf`、認証ヘルパー、組織専用のシェル関数）と、公開したくない個人情報（Git の `user.name` / `user.email`）は、非公開の `dotfiles-private` リポジトリで管理します。
公開側は「その名前のファイルがあれば読む」という受け皿だけを持ち、非公開側のファイル名や内容を参照しません。

- 受け皿: `.zshrc` / `.bashrc` が末尾で `~/.zshrc.local` / `~/.bashrc.local` を読み込み、`scripts/setup-git.sh` が `include.path` に `~/.gitconfig.local` を設定する
- 受け皿: `git-hooks/deny-private-strings` が `~/.config/dotfiles/denylist.txt` と `~/.config/dotfiles/work-remotes.txt` を読み、公開リポジトリへの混入を止める（「[公開リポジトリへの混入防止（denylist）](#公開リポジトリへの混入防止denylist)」を参照）
- `$HOME` へのリンクは `dotfiles-private` 側の `setup.sh` が行う
- `bootstrap.sh` はアクセス可能な場合のみ `dotfiles-private` を取得し、その `setup.sh` を実行する
- 認証情報そのもの（トークン・秘密鍵）は `dotfiles-private` にも置かない
- 以下の環境変数で動作を変更できる
  - `DOTFILES_PRIVATE_SKIP=1`: 導入をスキップする
  - `DOTFILES_PRIVATE_REPO_URL`: クローン元を上書きする
  - `DOTFILES_PRIVATE_DIR`: 保存先を絶対パスで上書きする

## AI エージェントからの機密情報遮断

AI エージェント（Claude Code / Codex）に対する方針は次の一点です。設計と判断の記録は [SECURITY.md](SECURITY.md) を参照してください。

> 認証情報の平文を、モデル・会話コンテキスト・tool output・ログ・AI が読めるファイル・環境変数・引数・標準入力へ渡さない。
> 一方で、credential helper・認証エージェント・署名ブローカーが内部で認証する通常の Git・AWS・コンテナ操作は制限しない。

そのため、コマンド名だけで一律に拒否せず、秘密値を出力するサブコマンドとそうでないサブコマンドを分けています。

- `.config/agents/AGENTS.md`: 共通の規約。行わないこと・行ってよいこと・確認してから行うことを分けて定義する
- `.claude/settings.json`: 秘密値を出力する操作の deny と通常の開発操作の allow（`ask` は置かず allow / deny に二分する）、認証情報ファイルの読み取り禁止（`Read` の deny とサンドボックスの `denyRead`）
- `.claude/hooks/pre-bash-guard.py`: 同じ判断を Bash 実行前フックでも強制し、さらに検査の迂回経路（設定注入・インタプリタ経由の実行・ラッパー経由の実行・コンテナへの受け渡し）と、認証情報ファイルを引数に取る操作を拒否する。
  不可逆な操作とサンドボックス外の状態変更は、文字列規則では表記を網羅できないため、ここで `ask` を返して確認へ回す（`bypassPermissions` では deny になる）
- `.config/codex/config.toml` / `.codex/browser/config.toml`: `:workspace` を継承した権限プロファイルで認証情報の読み取りを拒否し、環境変数の除外とブラウザ操作の常時承認を設定

### AI エージェントの起動

新しいターミナルセッションを開き、通常どおり起動します。

```sh
claude
codex
```

- AI エージェントを起動する前に新しいターミナルセッションを開く
- shell の起動ファイルと端末ローカル設定で、認証情報の平文を環境変数へ設定しない
- 認証情報を一時的に `export` したターミナルからは起動しない
- 認証は credential helper・キーチェーン・認証エージェントへ委譲する
- Codex の shell snapshot は無効化済み。Claude Code が内部利用する snapshot と、両エージェントの履歴・file history・paste cache はモデルから直接読めないよう保護する
- Claude Code の `permissions.defaultMode` は `auto` のまま運用する。
  `permissions.ask` は空とし、settings は allow / deny に二分する。確認が要る操作はフックが `ask` を返して扱う。
  `bypassPermissions` を明示的に選んだ場合もフックは hard deny を維持し、`ask` を返すはずだった操作は通常のインタプリタコードを除いて拒否する
  `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` は既定以外の permission mode と競合するため使わない

## このリポジトリで管理しないもの

- Git の共通設定以外（認証情報など）と gh（GitHub CLI）: 端末ごとに個別設定する
- 組織固有・個人の設定（`~/.gitconfig.local`、`~/.zshrc.local` など）: 非公開の dotfiles-private で管理する
- Codex のローカルユーザー設定（`~/.codex/config.toml`）: 端末ごとに個別設定する（旧 `sandbox_mode` は置かず、公開側の `default_permissions` を継承する）
- Claude Code のユーザースコープ MCP 登録（`~/.claude.json`）: 端末ごとに個別設定する
- Brewfile でコメントアウトしているアプリ: 導入手段を端末ごとに選ぶ
- 非公開 Agent Skills の内容: 非公開リポジトリで管理する
- 非公開 Codex Custom Pets の内容: 非公開リポジトリで管理する
- 認証情報（`~/.ssh`、`~/.aws` のクレデンシャル、GitHub のトークン、ROSA/OCM・Helm・uv の認証設定など）: 1Password などで別途移行する。
  GitHub の通常の認証は端末ごとに `gh auth login`、URL 限定の認証は必要に応じて `ghtkn auth` で取り直す
- 機密または端末固有のディレクトリ（`~/.kube`、`~/.docker`、`~/.terraform.d`、`~/.rd`）
- VS Code の設定と拡張: VS Code Settings Sync で同期する
