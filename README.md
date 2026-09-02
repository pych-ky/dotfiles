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
5. 不足する CLI・GUI アプリをインストールし、ログイン項目を追加・削除する
6. `mise install` でグローバル開発ツール（node、go、terraform など）を導入する
7. `scripts/setup-git.sh` で Git 共通設定を適用する
8. `zsh-autosuggestions` と `fast-syntax-highlighting` を取得する
9. 未導入の Claude Code CLI と Codex CLI を導入し、公式 Claude Code プラグインを設定に合わせて整理する
10. アクセス可能な非公開 Codex Custom Pets を取得し、収録されている全ペットをインストールする
11. アクセス可能な非公開 Agent Skills を取得し、リポジトリ直下の `setup.sh` で symlink を配置する
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
- Codex の hooks / permissions は起動時に読み込まれるため、リンク後は Codex を終了して新しいセッションを開始する
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

表示された URL を先に手動で開くと、後から Enter による CLI 自身のブラウザ起動が重なって同じ認証画面が別タブに開く。コードをコピーした後は URL をクリックせず Enter を押す。

URL 限定の ghtkn helper を使う端末では、非公開側の設定に従って追加で認証します。

```sh
ghtkn init   # ~/.config/ghtkn/ghtkn.yaml を作成し、対象の GitHub App の Client ID を書く
ghtkn auth   # デバイスフローで認証する
```

`ghtkn auth` も URL の手動クリック、Enter、10 秒後の自動起動を重ねない。手動で開く運用へ固定する場合だけ、端末固有設定で `open_browser.enable: false` にする。

- `gh auth token` / `gh auth git-credential` / `ghtkn get` / `ghtkn exec` / `ghtkn git-credential` の直接実行はトークンの取り出しになるため、AI エージェントには許可しない
- `gh` を `ghtkn exec` で包む端末固有 wrapper は `auth` サブコマンドを対象外にする。`GH_TOKEN` が注入された状態では、`gh auth login` が通常の保存済み認証を更新できない
- Git / `gh` / `aws` は個別の allow rule を使わず、ほかのコマンドと同じ既定 Allow の実行経路で動かす。
  Codex は「保護付きフルアクセス」、Claude Code は `auto` の classifier を使い、filesystem sandbox を無効化して credential helper、CLI 設定、認証キャッシュを通常どおり利用できるようにする。Auto 以外のモードでは bare `Bash` allow が有効になる
  - `gh` は gh 自身が保管先からトークンを読む。
    トークンはエージェントへ渡らないため、`gh pr list` などは通常どおり使える。
    ただしこれは `gh auth login` が保管した**別系統のトークン**であり、ghtkn 経由ではない。
    認証を ghtkn へ一本化するには `gh` 用の broker か wrapper が別途要る（未実装）
  - AI エージェントから AWS プロファイルを選ぶときは `aws --profile <name> ...` と明示する。`aws-use` は利用者の対話シェルでログインと既定プロファイルの永続化を行うための関数とする
  - AWS の設定と認証キャッシュは AWS CLI 自身から読み書きできる。ログインや設定変更は認証・外部状態の変更として事前確認する
- CodeCommit のプロファイル固有設定は公開側に置かない。AWS CLI 同梱の `codecommit credential-helper` は Git の子プロセスとして同じ認証経路を利用できるが、直接実行は認証情報の出力になるため拒否する。`git-remote-codecommit` はこのリポジトリでは導入していない
- 共通の PreToolUse ガードは、認証ファイルの直接読み取り、秘密値の出力、既知の検査迂回を拒否する。
  `terraform console` と、`--` 以降を git / ssh へ素通しする `gh repo clone` / `gh codespace ssh` は拒否するが、未知のサブコマンドを一律には拒否しない

### グローバルフック

`core.hooksPath` を設定すると、Git は各リポジトリの `.git/hooks` を参照しなくなります。
個別のフックを直接指定するとリポジトリ固有フックと Git LFS のフックが動かなくなるため、`scripts/setup-git.sh` が振り分け用のディレクトリ `~/.local/share/dotfiles/git-hooks` を作り、そこを参照させます。

| フック | 実行内容 |
| --- | --- |
| すべて | `git-hooks/dispatch`（secretlint 検査 → denylist 検査 → リポジトリ固有フック → Git LFS のフック） |

- `pre-commit` は変更されたファイルの index 上の内容全体を secretlint に標準入力で渡す。
  作業ツリーを読まないため部分ステージにも対応し、改名・型変更後の内容も検査する。
  削除と submodule のコミット参照は除外し、symlink はリンク先ではなくリンク文字列を検査する
- 推奨 preset（`@secretlint/secretlint-rule-preset-recommend`）をフック内の `--secretlintrcJSON` で明示する。
  リポジトリの `.secretlintrc*`・`.secretlintignore`・`.gitignore` はこの共通検査には使わない
- 秘密情報の検出、未導入、設定・ルール読み込み不備、index の取得・検査失敗はコミットを中断する。
  空コミットや削除のみでも事前にツールと設定を検査する。
  `--maskSecrets` を明示し、Git と secretlint の検査出力はエラー・デバッグ出力も含めて抑止する。
  失敗時は秘密値やパスを含まない固定メッセージだけを表示する
- リポジトリ固有フックが失敗した場合は、その終了状態を伝播してコミットや push を中断する
- Git LFS が扱うフック（`pre-push`、`post-checkout`、`post-commit`、`post-merge`）は `git lfs <フック名>` を呼ぶ。
  そのため各リポジトリでの `git lfs install` は不要
- `pre-push` と `post-rewrite` は標準入力で情報を受け取るため、内容を保持して各実行先へ渡す
- 特定のリポジトリでグローバルな検査（secretlint と下記の denylist）を止める場合は、`~/.local/share/dotfiles/IGNORE_GLOBAL_HOOKS` にそのリポジトリのパスを記載する（上流と同じ仕組み）。
  リポジトリ固有フックと Git LFS のフックは、そのリポジトリの動作そのものに必要なため止めない

secretlint は [公式の単一実行ファイル](https://github.com/secretlint/secretlint#using-single-executable-binary)を
[mise の aqua backend](https://mise.jdx.dev/dev-tools/backends/aqua.html) で管理する（`.config/mise/config.toml`、13.0.5 固定）。
推奨ルールを同梱しており、npm のグローバル導入や Homebrew への重複登録は行わない。
`bootstrap.sh` が設定のリンク後に `mise install` を実行し、secretlint も一括導入する。
bootstrap 全体を再実行せず、リンク済みの設定から secretlint だけ導入する場合は次を実行する。

```sh
mise install aqua:secretlint/secretlint
```

版とルールはこの dotfiles の既定であり、チーム標準を定義するものではない。
チーム指定がある場合は別途確認し、組織固有設定は公開リポジトリに置かない。
gitleaks の既定ルールと検出範囲は一致せず、汎用 API キーなどが同等に検出されるとは限らない。
既存端末の gitleaks は自動削除しないため、secretlint の導入・動作確認後に利用者が削除を判断する。

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

### macOS 設定

```sh
./macos/defaults.sh
```

- macOS の既定値から意図的に変える項目だけを `defaults write` で適用する。
  対象はキーボードのリピート速度、Dock、Finder、日本語入力など
- Rectangle の設定は、エクスポート済みの `macos/rectangle.plist` を読み込んで適用する
- `bootstrap.sh` は Rectangle と Typeless を「ログイン時に開く」へ登録し、Logi Options+ のメインアプリは同項目から除外する。
  Logi Options+ の機能は開発元のバックグラウンドサービスを使用する
- Karabiner のルール、メニューバー表示、Keychron K8 Pro のイベント変更は `.config/karabiner/karabiner.json` で管理する。
  DriverKit、入力監視、アクセシビリティ、バックグラウンド実行の許可は端末ごとに行う
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

`bootstrap.sh` は、未取得の Agent Skills リポジトリを `$HOME/src/pych/agent-skills` にクローンし、リポジトリ直下の `setup.sh` を実行します。
`setup.sh` は `$HOME/.agents/skills` と `$HOME/.claude/skills` に symlink を配置します。同名の未管理オブジェクトは上書きしません。

Agent Skills のセットアップだけを実行する場合:

```sh
./skills/setup.sh
```

#### 設定

初回クローン前のアクセス確認に失敗した場合は、既定で警告してスキップします。
以下の環境変数で動作を変更できます。

- `AGENT_SKILLS_STRICT=1`: アクセス失敗時に `bootstrap.sh` も失敗させる
- `AGENT_SKILLS_SKIP=1`: 導入をスキップする
- `AGENT_SKILLS_REPO_URL`: クローン元を上書きする
- `AGENT_SKILLS_REPO_DIR`: 保存先を絶対パスで上書きする

#### 更新と単体導入

既存のチェックアウトは自動更新しません。更新する場合は次を実行します。

```sh
repository_dir="${AGENT_SKILLS_REPO_DIR:-$HOME/src/pych/agent-skills}"
git -C "$repository_dir" pull --ff-only
"$repository_dir/setup.sh"
```

dotfiles を使わず単体で導入する場合:

```sh
git clone https://github.com/pych-ky/agent-skills.git "$HOME/src/pych/agent-skills"
cd "$HOME/src/pych/agent-skills"
./setup.sh
```

## 手動セットアップ

### システムとアプリ

- システム設定
  - プライバシーとセキュリティ > フルディスクアクセス / アクセシビリティ / 入力監視（Karabiner、Logi Options+、Claude など必要なものだけ）
  - プライバシーとセキュリティ > オートメーション（ログイン項目の登録時に System Events を許可）
  - 一般 > ログイン項目と拡張機能
    - 「ログイン時に開く」: Rectangle と Typeless があり、Logi Options+ がないことを確認
    - 「アプリのバックグラウンドでのアクティビティ」: Karabiner、Logi Options+、Logitech Inc をオン
    - 拡張機能 > Driver Extensions: Karabiner DriverKit VirtualHIDDevice をオン
  - サウンド > 入出力デバイスの指定
  - キーボード > テキスト入力 > テキスト置換（ユーザー辞書）
    - `しかく` → `■` / `やじるし` → `→` / `かっこ` → `「」`
- Finder > 設定 > サイドバー > ホームにチェック
- Brewfile でコメントアウトしているアプリ（ブラウザ、エディタなど）を、端末に応じた方法で導入
- Rancher Desktop: Preferences > Application > Environment > Configure PATH を Manual にする
- Typeless: サインインし、必要な権限を許可する。「ログイン時にアプリを起動」をオン、「ドックにアプリを表示」をオフにする
- VS Code: Settings Sync にサインイン（設定と拡張はこのリポジトリでは管理しない）。
  コマンドパレットから「Shell Command: Install 'code' command in PATH」を実行
- 各種アカウントにサインイン（1Password、Slack、Notion など）
- GitHub の通常の認証を `gh auth login` で用意する。
  URL 限定の ghtkn helper を使う端末では、非公開側の設定に従って `ghtkn init` / `ghtkn auth` も実行する。AI エージェントから実行する場合は確認を経る
- 個別インストーラからプリンタドライバを導入

### AI エージェントの外部サービス

- Claude.ai の Settings > Connectors で GitHub を接続する。この接続は、この環境では Claude Code の MCP として自動提供されない
- Claude Code からの GitHub 操作には、キーチェーン経由で認証済みの `gh` CLI を使う。
  `bootstrap.sh` は公式 GitHub プラグインも導入するが、PAT の環境変数を要求するため無効化したままにする
- Claude Code の Linear と Microsoft Docs の公式プラグインは `bootstrap.sh` が導入して有効化する。Linear は端末ごとに OAuth 認証する
- ChatGPT の Settings > Plugins で Linear と GitHub を Install し、それぞれ Connect する。
  `.config/codex/config.toml` は両方の canonical plugin ID を有効化するが、アカウントへの導入と接続は行わない

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
- `.claude/settings.json`: `auto` の利用、Auto 以外での Bash の既定 Allow、filesystem sandbox の無効化、秘密値を出力する操作の deny、ホーム以下にある既知名の認証情報ファイルに対する組み込み `Read` の禁止
- `.claude/hooks/pre-bash-guard.py`: Claude Code と Codex の Bash 実行前に同じ判断を強制し、さらに検査の迂回経路（設定注入・インタプリタ経由の実行・ラッパー経由の実行・コンテナへの受け渡し）と、認証情報ファイルを引数に取る操作を拒否する。
  不可逆な操作と外部・ホストの状態変更は、Claude Code では `ask` を返して確認へ回す（`bypassPermissions` では deny になる）。Codex の PreToolUse は `ask` 非対応のため、hard deny だけをフックで強制し、操作前の確認は共通規約に従う
- `.config/codex/config.toml` / `.codex/browser/config.toml`: ルート全体の読み書きを既定 Allow とし、CLI が内部利用する設定・認証ストア、秘密鍵、keystore、service-account、環境ファイルは filesystem deny の対象外にする。Codex / Claude Code 自身の認証・履歴と shell 履歴だけを固定 deny にし、通常の CLI 設定環境変数を継承して秘密値だけを除外する。ブラウザ操作・履歴・ファイル転送は常時確認とし、CDP フルアクセスは無効にする
  CLI 設定や認証ストアの直接取得は共通規約と PreToolUse で拒否する
  ワークスペース内の任意階層にある認証情報は `.config/agents/AGENTS.md` の禁止規約で扱う

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
- Claude Code の `permissions.defaultMode` は `auto` のまま運用する。Auto では任意コード実行になる bare `Bash` allow が一時的に外れ、通常操作は classifier が承認する。Auto 以外のモードへ切り替えると bare `Bash` allow が再び有効になる。filesystem sandbox は CLI の設定・認証ストアの内部利用を妨げないよう、明示的に無効化する。
  `permissions.ask` は空とし、settings は allow / deny に二分する。確認が要る操作はフックが `ask` を返して扱う。
  `bypassPermissions` を明示的に選んだ場合もフックは hard deny を維持し、`ask` を返すはずだった操作は通常のインタプリタコードを除いて拒否する
  `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` は既定以外の permission mode と競合するため使わない

## このリポジトリで管理しないもの

- Git と GitHub CLI の認証: 端末ごとに設定する
- 組織固有・個人の設定（`~/.gitconfig.local`、`~/.zshrc.local` など）: 非公開の dotfiles-private で管理する
- Codex のローカルユーザー設定（`~/.codex/config.toml`）: 端末ごとに個別設定する（旧 `sandbox_mode` は置かず、公開側の `default_permissions` を継承する）
- Claude Code の生のユーザースコープ MCP 登録（`~/.claude.json`）と claude.ai コネクタ: 端末・アカウントごとに設定する。公式プラグインで安全に代替できる共通 MCP は `.claude/settings.json` の `enabledPlugins` で管理する
- Brewfile でコメントアウトしているアプリ: 導入手段を端末ごとに選ぶ
- 非公開 Agent Skills の内容: 非公開リポジトリで管理する
- 非公開 Codex Custom Pets の内容: 非公開リポジトリで管理する
- 認証情報（`~/.ssh`、`~/.aws` のクレデンシャル、GitHub のトークン、ROSA/OCM・Helm・uv の認証設定など）: 1Password などで別途移行する。
  GitHub の通常の認証は端末ごとに `gh auth login`、URL 限定の認証は必要に応じて `ghtkn auth` で取り直す
- 機密または端末固有のディレクトリ（`~/.kube`、`~/.docker`、`~/.terraform.d`、`~/.rd`）
- VS Code の設定と拡張: VS Code Settings Sync で同期する
