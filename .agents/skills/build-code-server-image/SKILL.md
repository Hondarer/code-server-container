---
name: build-code-server-image
description: GHCR の Oracle Linux 8 latest を基に code-server イメージを rootless Podman で build・検証・ローカル起動する。ベース digest、初回の既定設定・拡張機能、利用者による表示言語選択を確認するときに使用する。
---

# Build code-server Image

## Workflow

1. リポジトリルートへ移動し、`AGENTS.md`、`docs/code-server-defaults.md`、`build-pod.sh`、`verify-defaults.sh`、`start-pod.sh` を読む。
2. `git status --short` で既存変更を把握して保全する。診断だけを依頼された場合は build や起動を行わない。
3. `podman info` と、GHCR・Open VSX へ接続できることを確認する。
4. `./build-pod.sh` を実行する。出力された `Resolved base image` の digest を記録する。
5. image の `org.opencontainers.image.base.name` と `org.opencontainers.image.base.digest` label が、解決したベースと一致することを確認する。
6. `./verify-defaults.sh` を実行し、全検証が PASS することを確認する。
7. ローカル動作確認が必要なら `./start-pod.sh 1` を実行し、HTTP 応答、初回設定、日本語 language pack、C/C++ theme、clang-format、clangdを確認する。表示言語は強制せず利用者が選択できる状態にする。

## Invariants

- sibling directory やローカルのベース image に依存させない。各 build で `ghcr.io/hondarer/oracle-linux-container/oracle-linux-8-dev:latest` を pull し、その build 内では digest 固定する。
- `src/code-server-defaults/extensions.txt` は `publisher.name` と `publisher.name@version` の両方を受理する。build 時に VSIX と SHA-256 を確定し、実行時はネットワークなしで導入できる状態にする。
- `User/settings.json` を初期化完了マーカーにする。存在時はUser・Machine設定、manifest、導入済み拡張を評価せず、欠落時だけ拡張導入後に`Machine/settings.json`、最後に`User/settings.json`を配置する。
- clang-format 23.1.1とgit-clang-formatを維持する。x86_64向け公式clangd 22.1.0をSHA-256固定で同梱し、初期拡張に`llvm-vs-code-extensions.vscode-clangd`を含める。runtimeでclangdをダウンロードしない。
- build が既存ローカルコンテナを停止し得るため、必要なら最後に `./start-pod.sh 1` で復旧する。永続 volume を削除しない。

## Completion Criteria

- ベース image label と解決 digest が一致する。
- `./verify-defaults.sh` が成功する。
- 必要なUser・Machine既定設定と拡張機能が image に包含され、初回初期化ゲートの単体テストが成功する。
- ローカル確認を実施した場合、code-server が正常応答する。
