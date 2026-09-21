ARG BASE_IMAGE=ghcr.io/hondarer/oracle-linux-container/oracle-linux-8-dev:latest
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG BASE_IMAGE_DIGEST=unknown
ARG CODE_SERVER_VERSION=4.138.0
ARG CLANGD_VERSION=22.1.0
ARG CLANGD_SHA256=c54e57dbff3ccc9e8352367ddb7030ad3f624073ec58c7477424e7919f578572

# メタデータラベル
LABEL org.opencontainers.image.title="Oracle Linux 8 + code-server"
LABEL org.opencontainers.image.description="oracle-linux-8 development container extended with code-server for browser-based VS Code access"
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"
LABEL org.opencontainers.image.base.digest="${BASE_IMAGE_DIGEST}"

# code-server の Web UI ポートを公開する宣言
EXPOSE 8080

# code-server のインストール
# Oracle Linux 向けの公式 RPM/COPR リポジトリが存在せず、install.sh の
# 自動検出 rpm 経路も動作保証がないため、Node 込みで自己完結する
# standalone 方式を採用する (systemd にも依存しない)。
# バージョンは再現性のため固定する。
RUN curl -fsSL https://code-server.dev/install.sh | sh -s -- \
        --method=standalone \
        --prefix=/usr/local \
        --version=${CODE_SERVER_VERSION}

# clangdの公式standalone archiveをversionとSHA-256で固定して同梱する。
# Linux版standalone archiveはx86_64専用。展開先を保つことでclangdが
# 同梱resource headersを/opt/clangd-${CLANGD_VERSION}/libから解決できる。
RUN [ "$(uname -m)" = x86_64 ] || { \
        echo 'Error: the bundled clangd standalone release supports x86_64 only.' >&2; \
        exit 1; \
    }; \
    clangd_archive="/tmp/clangd-linux-${CLANGD_VERSION}.zip"; \
    curl -fsSL \
        "https://github.com/clangd/clangd/releases/download/${CLANGD_VERSION}/clangd-linux-${CLANGD_VERSION}.zip" \
        -o "$clangd_archive"; \
    printf '%s  %s\n' "$CLANGD_SHA256" "$clangd_archive" | sha256sum -c -; \
    python3 -m zipfile -e "$clangd_archive" /tmp; \
    mv "/tmp/clangd_${CLANGD_VERSION}" "/opt/clangd-${CLANGD_VERSION}"; \
    chmod 0755 "/opt/clangd-${CLANGD_VERSION}/bin/clangd"; \
    ln -s "/opt/clangd-${CLANGD_VERSION}/bin/clangd" /usr/local/bin/clangd; \
    rm -f "$clangd_archive"; \
    clangd --version | grep -F "clangd version ${CLANGD_VERSION}" >/dev/null

# code-serverの既定設定と解決済みversionの拡張機能をイメージへ同梱する。
# 拡張はbuild時にOpen VSXから取得・インストール検証し、runtimeでは
# イメージ内のVSIXだけを使用する。
ADD code-server-defaults /opt/code-server-defaults
ADD install-default-extensions.sh /usr/local/bin
RUN chown -R root:root /opt/code-server-defaults \
        /usr/local/bin/install-default-extensions.sh && \
    chmod 0755 /usr/local/bin/install-default-extensions.sh && \
    /usr/local/bin/install-default-extensions.sh && \
    rm -f /root/.config/code-server/config.yaml

# エントリーポイント用スクリプトの配置
# code-server-init-home.sh は home/workspace 初期化のみを行う独立スクリプトで、
# エントリーポイントから呼ばれるほか、Azure Container Apps の init Job からも
# 単独で実行される (docs/azure-container-apps-multi-instance.md 参照)。
ADD code-server-entrypoint.sh code-server-init-home.sh code-server-bootstrap-defaults.sh /usr/local/bin/
RUN chown root:root /usr/local/bin/code-server-entrypoint.sh \
        /usr/local/bin/code-server-init-home.sh \
        /usr/local/bin/code-server-bootstrap-defaults.sh && \
    chmod 0755 /usr/local/bin/code-server-entrypoint.sh \
        /usr/local/bin/code-server-init-home.sh \
        /usr/local/bin/code-server-bootstrap-defaults.sh

# エントリーポイントの設定 (ベースイメージの sshd 起動用 ENTRYPOINT を上書きする)
# ログはコンテナの標準出力へ送り、Podman / Container Apps 側で収集する。
# パイプを介さないことで、終了コードと停止シグナルを正しく伝播させる。
ENTRYPOINT ["/usr/local/bin/code-server-entrypoint.sh"]
