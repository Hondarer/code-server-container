# code-serverの既定設定と拡張機能

初回のcode-serverプロセス起動時に、コンテナイメージへ同梱した設定と拡張機能を展開
します。コンテナ起動時のMarketplace接続は必要ありません。

## 既定設定

設定の適用先に合わせ、次の2ファイルで管理します。

- User settings: `src/code-server-defaults/User/settings.json`
- Remote settingsとして扱われるMachine settings:
  `src/code-server-defaults/Machine/settings.json`

```jsonc
{
  // 初回起動時のカラーテーマにC/C++向けVisual Studio Darkを使用する。
  "workbench.colorTheme": "Visual Studio Dark - C++",
  // ワークスペース信頼確認を無効化し、開いた直後から全機能を利用可能にする。
  "security.workspace.trust.enabled": false
}
```

PlantUML拡張の`plantuml.jar`はcode-serverではRemote settingsとして扱われるため、
Machine settingsへ配置します。Markdown Preview Enhancedの
`markdown-preview-enhanced.plantumlJarPath`など、その他の既定値はUser settingsへ配置します。

code-serverのlocaleは起動引数で強制しません。日本語Language Packは初期拡張として
同梱しますが、表示言語は利用者がcode-serverの表示言語選択機能から変更します。選択内容
は利用者ごとの永続ホームへ保存されます。

## 拡張機能マニフェスト

`src/code-server-defaults/extensions.txt`へ1行に1拡張を記載します。空行と`#`以降は
無視されます。

```text
# build時点の互換最新版
MS-CEINTL.vscode-language-pack-ja

# 指定した版
ms-vscode.cpptools-themes@2.0.0
```

指定形式は次の2種類です。

| 形式 | 動作 |
|---|---|
| `publisher.extension` | code-serverがbuild時点の最新安定・互換版を解決する |
| `publisher.extension@version` | 指定版を解決し、版が一致しなければbuildを失敗させる |

バージョン未指定のエントリは、同じソースから将来buildした場合に解決版が変わる可能性が
あります。一方、完成したイメージには`resolved-extensions.txt`、VSIX、`SHA256SUMS`が
保存されるため、コンテナ起動時の内容は固定されます。

`Visual Studio Dark - C++`は`ms-vscode.cpptools-themes`が提供します。

## clangd

C/C++の補完、診断、定義参照を提供するため、次の2要素をイメージへ同梱します。

- x86_64向け公式standalone版`clangd 22.1.0`
- 初期拡張`llvm-vs-code-extensions.vscode-clangd`

clangd archiveはversionとSHA-256を`src/Dockerfile`で固定し、
`/opt/clangd-22.1.0`へ展開します。`/usr/local/bin/clangd`から実行でき、拡張機能が起動時に
clangdをダウンロードする必要はありません。公式Linux standalone版の対象に合わせ、完成
イメージはx86_64限定です。

ベースイメージの`clang-format 23.1.1`と`git-clang-format`はそのまま維持します。clangdは
公式standalone版の22.1.0を独立して固定しているため、clang-formatとはversion系列が異なります。

clangdに実際のbuild optionを認識させるには、対象プロジェクトで`compile_commands.json`を
生成します。CMakeでは、例えば次のように生成できます。

```bash
cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

## デバッグ実行 (gdb)

`ms-vscode.cpptools`本体(および付属の`cppdbg`デバッグアダプタ)はMicrosoft Visual Studio
Marketplace限定配布のためOpen VSXから取得できません。代わりに初期拡張`webfreak.debug`
(Native Debug)を同梱します。ネイティブバイナリを含まない拡張で、GDB/MIプロトコル経由で
システムの`gdb`を直接起動します。ベースイメージには`gdb`・`gcc`/`g++`・`make`・`cmake`が
既に含まれており、追加のインストールは不要です。

デバッグ対象は`-g`付きでコンパイルします。CMakeプロジェクトでは
`-DCMAKE_BUILD_TYPE=Debug`を指定します。

ワークスペースの`.vscode/launch.json`に次のような設定を追加します(`code-server-defaults`は
ユーザー全体設定のみを同梱するため、`launch.json`はワークスペースごとに用意します)。

```jsonc
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "gdbで実行",
      "type": "gdb",
      "request": "launch",
      "target": "${workspaceFolder}/build/app",
      "cwd": "${workspaceFolder}"
    }
  ]
}
```

## buildと起動

`build-pod.sh`は公開ベースイメージ
`ghcr.io/hondarer/oracle-linux-container/oracle-linux-8-dev:latest`を毎回pullします。
取得時のdigestからbuildするため、処理中に`latest`が移動しても同じbuild内ではベースが
変わりません。完成イメージには次のOCIラベルを記録します。

- `org.opencontainers.image.base.name`: digest付きの完全なimage参照
- `org.opencontainers.image.base.digest`: 解決済みの`sha256` digest

ベースの`latest`はbuild間で変化します。完成したcode-serverイメージは不変tag、image
digest、上記base digestの組み合わせで追跡します。

Docker buildでは次を行います。

1. ID、任意のversion、重複を検証する。
2. code-server自身の拡張機能resolverで互換版を決定する。
3. Open VSXから解決済み版のVSIXを取得し、メタデータとSHA-256を記録する。
4. 一時領域へVSIXを再インストールし、IDとversionを検証する。
5. 解決済みマニフェストとVSIXを`/opt/code-server-defaults`へ同梱する。

## 初回初期化

利用者の
`/home/user/.local/share/code-server/User/settings.json`を初期化完了マーカーとして扱います。

| 起動時の状態 | 動作 |
|---|---|
| User settingsが存在する | User・Machine設定、拡張manifest、導入済み拡張を確認せず、初期化処理全体をスキップする |
| User settingsが存在しない | イメージ内VSIXから不足拡張を導入・検証し、Machine settings、最後にUser settingsを配置する |

User settingsを最後に配置するため、拡張機能の導入・検証やMachine settingsの配置に
失敗した場合は未初期化状態のままとなり、次回のcode-serverプロセス起動で再試行します。
初期化完了後は、利用者が既定拡張を削除しても自動では再導入しません。また、manifestから
拡張を削除して新しいイメージを配布しても、既存利用者の拡張を自動アンインストールしません。

既定値の内容を変更する場合の通常の変更スコープは次の3ファイルです。

- User settings: `src/code-server-defaults/User/settings.json`
- Machine settings: `src/code-server-defaults/Machine/settings.json`
- 初期拡張の追加・削除・version変更: `src/code-server-defaults/extensions.txt`

変更後はイメージを再buildします。初期化処理自体の仕様を変更しない限り、runtime scriptの
変更は不要です。clangdのように拡張機能が利用するOS toolを追加・更新する場合は、これに
加えて`src/Dockerfile`も変更します。

## 検証

```bash
./build-pod.sh
./verify-defaults.sh
```

検証用コンテナは一時ホームを使用し、`--network none`で起動します。次を確認します。

- User・Machine settings.jsonの初期配置と設定の振り分け
- 解決済みマニフェストとインストール版の一致
- VSIXのSHA-256
- 日本語Language Packとテーマの提供、およびlocaleを起動引数で強制していないこと
- clang-format 23.1.1とgit-clang-formatを維持していること
- clangd 22.1.0が起動し、簡単なCソースを解析できること
- clangd拡張の解決済みversionと導入済みversionが一致すること
- webfreak.debug(Native Debug)拡張の解決済みversionと導入済みversionが一致すること
- GHCRベース名とdigestラベルが一致すること

初期化を一度だけ実行するゲートは、次の単体テストで検証します。

```bash
./tests/code-server-bootstrap-defaults-test.sh
```

通常のローカル環境は次のコマンドで確認します。

```bash
./start-pod.sh 1
```

既存環境へ既定設定と不足する初期拡張を再適用する場合は、利用者自身がUser・Machine設定を
バックアップしてからUser settingsを削除し、code-serverプロセスを起動し直します。
ローカルではコンテナ再起動、AzureではRunning中なら`suspend`から`resume`、Stoppedなら
`resume`、またはRevision再起動が該当します。ブラウザの再接続だけでは初期化処理は
実行されません。

既存環境でPlantUML設定だけを移行する場合は、
`/home/user/.local/share/code-server/User/settings.json`から`plantuml.jar`を削除し、既存内容を
上書きしないよう`/home/user/.local/share/code-server/Machine/settings.json`へ次の設定を
マージします。イメージ更新だけでは、初期化済みホームの設定は自動変更されません。

```jsonc
{
  "plantuml.jar": "/usr/local/bin/plantuml.jar"
}
```

clangdを含む新しいイメージへ更新した場合、clangdコマンド自体は全ホームから利用できます。
一方、初期化済みホームでは初回初期化を再評価しないため、clangd拡張は自動追加されません。
既存利用者は必要に応じて、code-serverのterminalからイメージ同梱VSIXを手動導入します。
この操作は`settings.json`を変更せず、Marketplace接続も必要としません。

```bash
code-server \
  --user-data-dir /home/user/.local/share/code-server \
  --extensions-dir /home/user/.local/share/code-server/extensions \
  --install-extension \
  /opt/code-server-defaults/vsix/llvm-vs-code-extensions.vscode-clangd-*.vsix \
  --force
```

Azure上で`home`と`workspace`を含む利用者環境全体を空にする場合は、Stopped状態で
`./aca-instance.sh reset <slug>`を実行します。resetは空ディレクトリの再作成までを行い、
Appを起動しません。次回`resume`時に、Appへ現在割り当てられているイメージ内のVSIXと
設定を使ってこの初回初期化処理が実行されます。
