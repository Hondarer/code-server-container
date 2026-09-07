# code-server-container

[oracle-linux-container](https://github.com/hondarer/oracle-linux-container)のOracle Linux 8
開発環境を、ブラウザから利用できる[code-server](https://github.com/coder/code-server)
コンテナとして提供します。rootless Podmanによるローカル実行と、利用者ごとに分離した
Azure Container Apps環境をサポートします。

## 構成

- ローカル: インスタンス番号ごとにポート、ホーム、ワークスペースを分離する。
- Azure: 利用者ごとにContainer App、URL、パスワード、Azure Files Shareを分離する。
- コンテナ: 日本語Language Pack、`Visual Studio Dark - C++`テーマ、clangdと既定拡張をイメージへ同梱する。表示言語は利用者が選択する。
- 認証: code-serverのパスワード認証を使用し、SSHは起動しない。

## 前提条件

- rootless Podman
- OpenSSL、curl、jq
- `ghcr.io`から公開ベースイメージをpullできるネットワーク接続
- Azureへ公開する場合はAzure CLIとContainer Appsを作成できる権限

## ローカル利用

```bash
./build-pod.sh
./verify-defaults.sh
./start-pod.sh 1
```

buildは`ghcr.io/hondarer/oracle-linux-container/oracle-linux-8-dev:latest`を毎回pullし、
その時点のdigestを固定してcode-serverイメージを生成します。ローカルに
`oracle-linux-container`をcloneまたはbuildする必要はありません。

`http://localhost:8080`へ接続します。インスタンス番号を2にすると、ポートは8081、
永続領域は`./storage/2`になります。

パスワードは初回起動時に生成されます。

```bash
podman exec code-server-ol8_1 \
    cat /home/$USER/.config/code-server/config.yaml
./stop-pod.sh 1
```

## Azure利用

共有基盤を作成してイメージを公開した後、利用者単位でAppを作成します。

```bash
./aca-environment.sh init
./aca-environment.sh create
./aca-environment.sh publish --scaling-mode enabled --cooldown-period 3600
./aca-instance.sh create alice
./aca-instance.sh create bob
./aca-instance.sh list
./aca-instance.sh suspend alice
./aca-instance.sh resume alice
./aca-instance.sh download alice ./backups/
./aca-instance.sh reset alice
```

認証情報、Azure設定、利用者パスワードは`$HOME/.azure`へ保存され、リポジトリには
含まれません。

`suspend`はURL、Secret、Azure Filesを維持したままレプリカを停止します。状態遷移と
各状態で受付可能なコマンドは[複数利用者の管理](docs/azure-container-apps-multi-instance.md#ライフサイクルと受付可能な操作)
を参照してください。`download`は利用者別の`home`と`workspace`をローカルのtar.gzへ
書き出します。`reset`は停止中の永続データを空にし、次回`resume`時に既定設定と拡張機能を
再初期化します。

`publish`で選んだスケーリング設定は後続の`create`と利用者別`update`へ適用されます。
スケーリング有効時は既定で60分無通信の後に0 replicaとなり、次のHTTPアクセスで
自動的に起動します。これはAppを`Stopped`にする`suspend`とは異なります。

利用者インスタンスを完全に削除する場合は、破壊操作として個別に実行します。

```bash
./aca-instance.sh delete alice
# 確認プロンプトへ: alice
```

`delete`は対象のContainer App、環境ストレージ登録、Azure Files Share、ローカルの
パスワードファイルを削除します。必要な永続データは、実行前に`download`で退避してください。

## コンテナ内の開発サーバー

> [!TIP]
> MkDocsなどをコンテナ内の8000番ポートで起動しても、現在の構成では
> `http://<ホスト名>:8000`として外部へ直接公開されません。code-serverへログインした
> ブラウザから、次のポートプロキシURLでアクセスできます。
>
> - ローカル: `http://localhost:8080/proxy/8000/`
> - Azure Container Apps: `https://<利用者のFQDN>/proxy/8000/`
>
> 例えば、code-serverのターミナルで次のように起動します。
>
> ```bash
> mkdocs serve --dev-addr 127.0.0.1:8000
> ```
>
> ローカルのインスタンス番号が2以降の場合は、URLの8080を対応するcode-serverポート
> （インスタンス2なら8081）へ読み替えてください。

## ドキュメント

- [ドキュメント一覧](docs/README.md)
- [Azure CLIセットアップ](docs/azure-cli-setup.md)
- [Azure Container Apps公開・運用](docs/azure-container-apps-publish.md)
- [複数利用者の管理](docs/azure-container-apps-multi-instance.md)
- [code-serverの既定設定と拡張機能](docs/code-server-defaults.md)

## Agent Skills

リポジトリ固有の操作手順は`.agents/skills`へ目的別に収録しています。

- `build-code-server-image`: GHCRベースのローカルbuildと検証
- `manage-aca-environment`: Azure共有基盤の作成・監査・削除
- `manage-aca-instances`: 利用者別App、URL、パスワード、永続領域の管理
- `release-code-server-aca`: build、publish、利用者別Appの順次更新、旧image整理

Agentは共通の不変条件と安全規則を`AGENTS.md`で確認してから操作します。

## 制約

- ベースイメージはOracle Linux 8のみを対象とする。
- clangdを包含する完成イメージはx86_64のみを対象とする。
- code-serverは1 Appにつき1利用者、1 replicaで運用する。
- ローカル接続はHTTP、Azure接続はContainer Apps ingressによるHTTPSを使用する。
- Microsoft Entra ID、カスタムドメイン、CI/CDはこのリポジトリでは構成しない。
