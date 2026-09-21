#!/bin/bash

# Verify image-bundled code-server defaults without touching ./storage.

set -euo pipefail

IMAGE="${1:-code-server-ol8}"
TEST_DIR="$(mktemp -d)"
CONTAINER_NAME="code-server-defaults-test-$$"
TEST_HOME="${TEST_DIR}/home"
TEST_WORKSPACE="${TEST_DIR}/workspace"

cleanup() {
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    # keep-idコンテナが作成した中間ディレクトリは、ホストからnobody所有に
    # 見える場合があるため、rootless Podmanと同じuser namespaceで削除する。
    podman unshare rm -rf "$TEST_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$TEST_HOME" "$TEST_WORKSPACE"

start_test_container() {
    podman run -d \
        --name "$CONTAINER_NAME" \
        --network none \
        --userns=keep-id \
        --user root \
        -v "${TEST_HOME}:/home/user:Z" \
        -v "${TEST_WORKSPACE}:/workspace:Z" \
        --env HOST_USER=user \
        --env HOST_UID=1000 \
        --env HOST_GID=1000 \
        --env PASSWORD=defaults-test-password \
        "$IMAGE" >/dev/null

    for attempt in $(seq 1 30); do
        if podman exec "$CONTAINER_NAME" curl -fsS http://127.0.0.1:8080/healthz \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    podman logs "$CONTAINER_NAME" >&2
    echo 'Error: test container did not become healthy.' >&2
    exit 1
}

list_extensions() {
    podman exec "$CONTAINER_NAME" runuser -u user -- env \
        HOME=/home/user USER=user LOGNAME=user \
        code-server \
        --user-data-dir /home/user/.local/share/code-server \
        --extensions-dir /home/user/.local/share/code-server/extensions \
        --list-extensions --show-versions
}

podman image exists "$IMAGE"
base_name="$(podman image inspect "$IMAGE" \
    --format '{{index .Labels "org.opencontainers.image.base.name"}}')"
base_digest="$(podman image inspect "$IMAGE" \
    --format '{{index .Labels "org.opencontainers.image.base.digest"}}')"
[[ "$base_name" == ghcr.io/hondarer/oracle-linux-container/oracle-linux-8-dev@sha256:* ]]
[[ "$base_digest" =~ ^sha256:[a-f0-9]{64}$ ]]
[[ "$base_name" == *"@${base_digest}" ]]
start_test_container

podman exec "$CONTAINER_NAME" \
    test -f /home/user/.local/share/code-server/User/settings.json
podman exec "$CONTAINER_NAME" \
    test -f /home/user/.local/share/code-server/Machine/settings.json
podman exec "$CONTAINER_NAME" cmp \
    /opt/code-server-defaults/User/settings.json \
    /home/user/.local/share/code-server/User/settings.json
podman exec "$CONTAINER_NAME" cmp \
    /opt/code-server-defaults/Machine/settings.json \
    /home/user/.local/share/code-server/Machine/settings.json
podman exec "$CONTAINER_NAME" grep -Fq \
    '"plantuml.jar": "/usr/local/bin/plantuml.jar"' \
    /home/user/.local/share/code-server/Machine/settings.json
if podman exec "$CONTAINER_NAME" grep -Fq '"plantuml.jar"' \
    /home/user/.local/share/code-server/User/settings.json; then
    echo 'Error: plantuml.jar must be stored in Machine settings only.' >&2
    exit 1
fi
podman exec "$CONTAINER_NAME" grep -Fq \
    '"markdown-preview-enhanced.plantumlJarPath"' \
    /home/user/.local/share/code-server/User/settings.json

extensions="$(list_extensions)"
resolved_extensions="$(podman exec "$CONTAINER_NAME" \
    cat /opt/code-server-defaults/vsix/resolved-extensions.txt)"
language_pack="$(printf '%s\n' "$resolved_extensions" |
    grep -Ei '^MS-CEINTL\.vscode-language-pack-ja@[A-Za-z0-9._-]+$')"
clangd_extension="$(printf '%s\n' "$resolved_extensions" |
    grep -Ei '^llvm-vs-code-extensions\.vscode-clangd@[A-Za-z0-9._-]+$')"
debug_extension="$(printf '%s\n' "$resolved_extensions" |
    grep -Ei '^webfreak\.debug@[A-Za-z0-9._-]+$')"
[ "$(printf '%s\n' "$language_pack" | wc -l)" -eq 1 ]
[ "$(printf '%s\n' "$clangd_extension" | wc -l)" -eq 1 ]
[ "$(printf '%s\n' "$debug_extension" | wc -l)" -eq 1 ]
printf '%s\n' "$extensions" | grep -Fqix "$language_pack"
printf '%s\n' "$extensions" | grep -Fqix "$clangd_extension"
printf '%s\n' "$extensions" | grep -Fqix "$debug_extension"
printf '%s\n' "$extensions" | grep -Fqix 'ms-vscode.cpptools-themes@2.0.0'
printf '%s\n' "$resolved_extensions" | grep -Fqix 'ms-vscode.cpptools-themes@2.0.0'
podman exec "$CONTAINER_NAME" sh -lc \
    'cd /opt/code-server-defaults/vsix && sha256sum -c SHA256SUMS >/dev/null'

podman exec "$CONTAINER_NAME" sh -lc '
    for package_file in /home/user/.local/share/code-server/extensions/*/package.json; do
        jq -e '\''any(.contributes.themes[]?; .id == "Visual Studio Dark - C++")'\'' \
            "$package_file" >/dev/null 2>&1 && exit 0
    done
    exit 1
'
if podman exec "$CONTAINER_NAME" sh -lc \
    "ps -ef | grep '[c]ode-server .*--locale' >/dev/null"; then
    echo 'Error: code-server was started with a forced locale.' >&2
    exit 1
fi
podman exec "$CONTAINER_NAME" sh -lc \
    "clang-format --version | grep -F 'clang-format version 23.1.1' >/dev/null"
podman exec "$CONTAINER_NAME" command -v git-clang-format >/dev/null
podman exec "$CONTAINER_NAME" sh -lc '
    [ "$(command -v clangd)" = /usr/local/bin/clangd ]
    clangd --version | grep -F "clangd version 22.1.0" >/dev/null
    printf "int main(void) { return 0; }\n" > /tmp/clangd-smoke.c
    clangd --check=/tmp/clangd-smoke.c >/tmp/clangd-smoke.log 2>&1
'

echo 'code-server defaults verification: PASS'
