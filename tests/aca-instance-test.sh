#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/passwords"
export MOCK_STATE="$TEST_DIR/app-exists"
export MOCK_JOB_STATE="$TEST_DIR/job-exists"
export MOCK_JOB_EXECUTION_STATUS=Succeeded
export MOCK_SHARE="$TEST_DIR/share-exists"
export MOCK_LOG="$TEST_DIR/az.log"
export MOCK_RUNNING="$TEST_DIR/running-status"
export MOCK_PROVISIONING="$TEST_DIR/provisioning-state"
export MOCK_CURL_LOG="$TEST_DIR/curl.log"
export MOCK_DOWNLOAD_LAYOUT=complete
export MOCK_HOME_DIR="$TEST_DIR/home-directory-exists"
export MOCK_WORKSPACE_DIR="$TEST_DIR/workspace-directory-exists"
export MOCK_REMOVE_FAILURE=false
export MOCK_KEY_FAILURE=false
export MOCK_CREATE_FAILURE=''
export MOCK_MIN="$TEST_DIR/min-replicas"
export MOCK_MAX="$TEST_DIR/max-replicas"
export MOCK_COOLDOWN="$TEST_DIR/cooldown-period"
export MOCK_RULE="$TEST_DIR/scale-rule"
export MOCK_REPLICAS="$TEST_DIR/replicas"
export MOCK_CPU="$TEST_DIR/container-cpu"
export MOCK_MEMORY="$TEST_DIR/container-memory"
printf 'Succeeded\n' > "$MOCK_PROVISIONING"
printf 'Running\n' > "$MOCK_RUNNING"
printf '1\n' > "$MOCK_MIN"
printf '1\n' > "$MOCK_MAX"
: > "$MOCK_COOLDOWN"
: > "$MOCK_RULE"
printf '1\n' > "$MOCK_REPLICAS"
printf '1.0\n' > "$MOCK_CPU"
printf '2Gi\n' > "$MOCK_MEMORY"

cat > "$TEST_DIR/config.env" <<EOF
RESOURCE_GROUP=rg-test
LOCATION=japaneast
ENVIRONMENT_NAME=cae-test
IDENTITY_NAME=id-test
IMAGE_REPOSITORY=code-server-ol8
APP_NAME_PREFIX=code-server-ol8
FILE_SHARE_PREFIX=code-server
ENV_STORAGE_PREFIX=code-server
PASSWORD_DIR=$TEST_DIR/passwords
FILE_SHARE_QUOTA_GIB=10
ACR_NAME=acrtest
STORAGE_ACCOUNT=sttest
REMOTE_IMAGE=acrtest.azurecr.io/code-server-ol8:test
EOF

cat > "$TEST_DIR/bin/az" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_LOG"

case "$1 $2" in
    "acr show") echo 'acrtest.azurecr.io' ;;
    "identity show") echo '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test' ;;
    "containerapp env")
        case "$3" in
            show) echo '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/cae-test' ;;
        esac
        ;;
    "storage account")
        if [ "$3" = "keys" ] && [ "$MOCK_KEY_FAILURE" != true ]; then echo 'test-key'; fi
        ;;
    "storage share-rm")
        case "$3" in
            show) [ -f "$MOCK_SHARE" ] || exit 1 ;;
            create) touch "$MOCK_SHARE" ;;
            delete) rm -f "$MOCK_SHARE" ;;
        esac
        ;;
    "storage file")
        [ "$3" = "download-batch" ] || exit 1
        destination=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--destination" ]; then
                destination="$2"
                break
            fi
            shift
        done
        [ -n "$destination" ] || exit 1
        case "${MOCK_DOWNLOAD_LAYOUT:-complete}" in
            complete)
                mkdir -p "$destination/home" "$destination/workspace"
                printf 'home-data\n' > "$destination/home/marker.txt"
                printf 'workspace-data\n' > "$destination/workspace/marker.txt"
                ;;
            home-only) mkdir -p "$destination/home" ;;
            workspace-only) mkdir -p "$destination/workspace" ;;
            empty) ;;
            *) exit 1 ;;
        esac
        ;;
    "storage directory")
        operation="$3"
        directory=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--name" ]; then
                directory="$2"
                break
            fi
            shift
        done
        case "$directory" in
            home) marker="$MOCK_HOME_DIR" ;;
            workspace) marker="$MOCK_WORKSPACE_DIR" ;;
            *) exit 1 ;;
        esac
        case "$operation" in
            exists) [ -f "$marker" ] && echo true || echo false ;;
            create)
                [ "$MOCK_CREATE_FAILURE" != "$directory" ] || exit 1
                touch "$marker"
                ;;
            *) exit 1 ;;
        esac
        ;;
    "storage share")
        [ "$3" = generate-sas ] || exit 1
        [ -n "${AZURE_STORAGE_KEY:-}" ] || exit 1
        echo 'sv=test&sig=test'
        ;;
    "containerapp show")
        [ -f "$MOCK_STATE" ] || exit 1
        case "$*" in
            *"properties.configuration.ingress.fqdn"*) echo 'code-server-ol8-alice.test.azurecontainerapps.io' ;;
            *"properties.provisioningState"*) cat "$MOCK_PROVISIONING" ;;
            *"properties.runningStatus"*) cat "$MOCK_RUNNING" ;;
            *"properties.template.volumes[0].storageName"*) echo 'code-server-alice-storage' ;;
            *"properties.template.scale.minReplicas"*) cat "$MOCK_MIN" ;;
            *"properties.template.scale.maxReplicas"*) cat "$MOCK_MAX" ;;
            *"properties.template.scale.cooldownPeriod"*) cat "$MOCK_COOLDOWN" ;;
            *"properties.template.scale.rules[0].name"*) cat "$MOCK_RULE" ;;
            *"properties.template.containers[0].resources.cpu"*) cat "$MOCK_CPU" ;;
            *"properties.template.containers[0].resources.memory"*) cat "$MOCK_MEMORY" ;;
            *"properties.template.containers[0].image"*) echo 'acrtest.azurecr.io/code-server-ol8:test' ;;
            *"--query id"*) echo '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.App/containerApps/code-server-ol8-alice' ;;
            *) echo '{}' ;;
        esac
        ;;
    "containerapp create") touch "$MOCK_STATE" ;;
    "containerapp delete") rm -f "$MOCK_STATE" ;;
    "containerapp update")
        yaml=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--yaml" ]; then yaml="$2"; break; fi
            shift
        done
        if [ -n "$yaml" ]; then
            sed -n 's/^          cpu: //p' "$yaml" > "$MOCK_CPU"
            sed -n 's/^          memory: //p' "$yaml" > "$MOCK_MEMORY"
            sed -n 's/^      minReplicas: //p' "$yaml" > "$MOCK_MIN"
            sed -n 's/^      maxReplicas: //p' "$yaml" > "$MOCK_MAX"
            cooldown="$(sed -n 's/^      cooldownPeriod: //p' "$yaml")"
            [ "$cooldown" != null ] && printf '%s\n' "$cooldown" > "$MOCK_COOLDOWN" || : > "$MOCK_COOLDOWN"
            grep -q 'code-server-http' "$yaml" && printf 'code-server-http\n' > "$MOCK_RULE" || : > "$MOCK_RULE"
        fi
        ;;
    "containerapp job")
        case "$3" in
            show) [ -f "$MOCK_JOB_STATE" ] || exit 1 ;;
            create) touch "$MOCK_JOB_STATE" ;;
            update) [ -f "$MOCK_JOB_STATE" ] || exit 1 ;;
            secret)
                [ "$4" = "set" ] || exit 1
                [ -f "$MOCK_JOB_STATE" ] || exit 1
                ;;
            start)
                [ -f "$MOCK_JOB_STATE" ] || exit 1
                echo 'code-server-ol8-alice-init-exec1'
                ;;
            execution)
                [ "$4" = "show" ] || exit 1
                printf '%s\n' "$MOCK_JOB_EXECUTION_STATUS"
                ;;
            delete) rm -f "$MOCK_JOB_STATE" ;;
            *) exit 1 ;;
        esac
        ;;
    "containerapp list")
        cooldown="$(cat "$MOCK_COOLDOWN")"
        rule="$(cat "$MOCK_RULE")"
        printf 'code-server-ol8-alice\tcode-server-ol8-alice.test.azurecontainerapps.io\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(cat "$MOCK_PROVISIONING")" "$(cat "$MOCK_RUNNING")" "$(cat "$MOCK_MIN")" \
            "$(cat "$MOCK_MAX")" "${cooldown:--}" "${rule:--}"
        ;;
    "containerapp replica") cat "$MOCK_REPLICAS" ;;
    "containerapp revision")
        if [ "$3" = "list" ]; then echo 'code-server-ol8-alice--active'; fi
        ;;
    "rest --method")
        case "$*" in
            *"/stop?api-version=2025-07-01"*) printf 'Stopped\n' > "$MOCK_RUNNING" ;;
            *"/start?api-version=2025-07-01"*) printf 'Running\n' > "$MOCK_RUNNING" ;;
            *) exit 1 ;;
        esac
        ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/az"

cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_CURL_LOG"
exit 0
EOF
chmod +x "$TEST_DIR/bin/curl"

cat > "$TEST_DIR/bin/azcopy" <<'EOF'
#!/bin/bash
printf 'azcopy %s\n' "$*" >> "$MOCK_LOG"
[ "$MOCK_REMOVE_FAILURE" != true ] || exit 1
case "$1:$2" in
    remove:*/code-server-alice/home\?*) rm -f "$MOCK_HOME_DIR" ;;
    remove:*/code-server-alice/workspace\?*) rm -f "$MOCK_WORKSPACE_DIR" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TEST_DIR/bin/azcopy"

export PATH="$TEST_DIR/bin:$PATH"

if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" create 'Bad_Name' >/dev/null 2>&1; then
    echo 'invalid slug was accepted' >&2
    exit 1
fi
if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" create alice \
    --scaling-mode disabled --min-replicas 0 >/dev/null 2>&1; then
    echo 'create accepted min replicas with disabled scaling' >&2
    exit 1
fi
test ! -e "$MOCK_STATE"

cp "$TEST_DIR/config.env" "$TEST_DIR/invalid-resources.env"
printf '\nCONTAINER_APP_CPU=4.0\nCONTAINER_APP_MEMORY=4Gi\n' >> "$TEST_DIR/invalid-resources.env"
if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/invalid-resources.env" create alice \
    >/dev/null 2>&1; then
    echo 'create accepted an invalid Container App resource pair' >&2
    exit 1
fi
test ! -e "$MOCK_STATE"
if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" create alice \
    --scaling-mode enabled --cooldown-period invalid >/dev/null 2>&1; then
    echo 'create accepted an invalid cooldown period' >&2
    exit 1
fi
test ! -e "$MOCK_STATE"

create_output="$($REPO_DIR/aca-instance.sh --config "$TEST_DIR/config.env" create alice)"
grep -q $'alice\thttps://code-server-ol8-alice.test.azurecontainerapps.io/' <<< "$create_output"
test -s "$TEST_DIR/passwords/alice/password"
test "$(stat -c '%a' "$TEST_DIR/passwords/alice/password")" = 600
grep -q 'containerapp create.*code-server-ol8-alice' "$MOCK_LOG"
grep -q 'storage-name code-server-alice-storage' "$MOCK_LOG"
grep -q 'share-rm create.*-n code-server-alice' "$MOCK_LOG"
grep -q 'containerapp job create.*code-server-ol8-alice-init' "$MOCK_LOG"
grep -q '^containerapp job start -g rg-test -n code-server-ol8-alice-init' "$MOCK_LOG"
grep -q 'containerapp job secret set.*code-server-ol8-alice-init' "$MOCK_LOG"
test -f "$MOCK_JOB_STATE"
test "$(cat "$MOCK_CPU")" = 4.0
test "$(cat "$MOCK_MEMORY")" = 8Gi
grep -A2 '^        resources:' "$REPO_DIR/docs/azure-container-apps-init-job.yaml.template" | \
    grep -q 'cpu: 1.0'
grep -A2 '^        resources:' "$REPO_DIR/docs/azure-container-apps-init-job.yaml.template" | \
    grep -q 'memory: 2Gi'

before_count="$(grep -c '^containerapp create' "$MOCK_LOG")"
before_job_create_count="$(grep -c '^containerapp job create' "$MOCK_LOG")"
second_output="$($REPO_DIR/aca-instance.sh --config "$TEST_DIR/config.env" create alice 2>/dev/null)"
after_count="$(grep -c '^containerapp create' "$MOCK_LOG")"
test "$before_count" = "$after_count"
test "$before_job_create_count" = "$(grep -c '^containerapp job create' "$MOCK_LOG")"
grep -q $'alice\thttps://code-server-ol8-alice.test.azurecontainerapps.io/' <<< "$second_output"

cp "$TEST_DIR/config.env" "$TEST_DIR/custom-resources.env"
printf '\nCONTAINER_APP_CPU=2.0\nCONTAINER_APP_MEMORY=4Gi\n' >> "$TEST_DIR/custom-resources.env"
"$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/custom-resources.env" update alice >/dev/null
test "$(cat "$MOCK_CPU")" = 2.0
test "$(cat "$MOCK_MEMORY")" = 4Gi
"$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" update alice >/dev/null
test "$(cat "$MOCK_CPU")" = 4.0
test "$(cat "$MOCK_MEMORY")" = 8Gi

list_output="$($REPO_DIR/aca-instance.sh --config "$TEST_DIR/config.env" list)"
grep -q $'INSTANCE\tURL\tPASSWORD\tPROVISIONING\tRUNNING\tSCALING\tMIN\tMAX\tCOOLDOWN\tREPLICAS' <<< "$list_output"
grep -q $'alice\thttps://code-server-ol8-alice.test.azurecontainerapps.io/' <<< "$list_output"
grep -q $'Succeeded\tRunning\tDisabled\t1\t1\t-\t1' <<< "$list_output"

printf '\nSCALING_MODE=enabled\nSCALING_MIN_REPLICAS=0\nSCALING_COOLDOWN_PERIOD=3600\n' >> "$TEST_DIR/config.env"
"$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" update alice >/dev/null
grep -q 'containerapp update.*code-server-ol8-alice' "$MOCK_LOG"
test "$(cat "$MOCK_MIN")" = 0
test "$(cat "$MOCK_COOLDOWN")" = 3600
test "$(cat "$MOCK_RULE")" = code-server-http
printf '0\n' > "$MOCK_REPLICAS"
scaled_list_output="$($REPO_DIR/aca-instance.sh --config "$TEST_DIR/config.env" list)"
grep -q $'Succeeded\tRunning\tEnabled\t0\t1\t3600\t0' <<< "$scaled_list_output"

before_stop_count="$(grep -c '/stop?api-version=2025-07-01' "$MOCK_LOG" || true)"
suspend_output="$($REPO_DIR/aca-instance.sh --config "$TEST_DIR/config.env" suspend alice)"
after_stop_count="$(grep -c '/stop?api-version=2025-07-01' "$MOCK_LOG")"
test "$after_stop_count" -eq $((before_stop_count + 1))
grep -q $'INSTANCE\tURL\tPROVISIONING\tRUNNING' <<< "$suspend_output"
grep -q $'Succeeded\tStopped' <<< "$suspend_output"

"$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" suspend alice >/dev/null 2>&1
test "$(grep -c '/stop?api-version=2025-07-01' "$MOCK_LOG")" = "$after_stop_count"

before_reset_mutations="$(grep -Ec '^(azcopy remove|storage directory (create|delete)|rest --method)' "$MOCK_LOG" || true)"
if printf 'alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
    reset alice >/dev/null 2>"$TEST_DIR/reset-confirmation.err"; then
    echo 'reset accepted an incomplete confirmation' >&2
    exit 1
fi
grep -q 'nothing was reset' "$TEST_DIR/reset-confirmation.err"
test "$before_reset_mutations" = "$(grep -Ec '^(azcopy remove|storage directory (create|delete)|rest --method)' "$MOCK_LOG" || true)"

before_reset_rest_count="$(grep -c '^rest --method' "$MOCK_LOG" || true)"
before_reset_job_start_count="$(grep -c '^containerapp job start' "$MOCK_LOG" || true)"
reset_output="$(printf 'reset alice\n' | "$REPO_DIR/aca-instance.sh" \
    --config "$TEST_DIR/config.env" reset alice)"
grep -q 'instance remains stopped' <<< "$reset_output"
grep -q 'resume alice' <<< "$reset_output"
test -f "$MOCK_HOME_DIR"
test -f "$MOCK_WORKSPACE_DIR"
grep -q '^azcopy remove .*/home?.*--recursive --force-if-read-only' "$MOCK_LOG"
grep -q '^azcopy remove .*/workspace?.*--recursive --force-if-read-only' "$MOCK_LOG"
test "$before_reset_rest_count" = "$(grep -c '^rest --method' "$MOCK_LOG" || true)"
test "$(grep -c '^containerapp job start' "$MOCK_LOG")" -eq $((before_reset_job_start_count + 1))
grep -q '^containerapp job execution show.*code-server-ol8-alice-init' "$MOCK_LOG"

export MOCK_JOB_EXECUTION_STATUS=Failed
if printf 'reset alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
    reset alice >/dev/null 2>"$TEST_DIR/reset-job-failure.err"; then
    echo 'reset ignored a failed init Job execution' >&2
    exit 1
fi
grep -q 'init Job execution' "$TEST_DIR/reset-job-failure.err"
export MOCK_JOB_EXECUTION_STATUS=Succeeded
if grep -E '^(azcopy remove|storage (share generate-sas|directory exists))' "$MOCK_LOG" | grep -q -- 'test-key'; then
    echo 'reset exposed the storage key in command arguments' >&2
    exit 1
fi

rm -f "$MOCK_HOME_DIR" "$MOCK_WORKSPACE_DIR"
printf 'reset alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
    reset alice >/dev/null
test -f "$MOCK_HOME_DIR"
test -f "$MOCK_WORKSPACE_DIR"

export MOCK_REMOVE_FAILURE=true
if printf 'reset alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
    reset alice >/dev/null 2>&1; then
    echo 'reset ignored an Azure Files removal failure' >&2
    exit 1
fi
export MOCK_REMOVE_FAILURE=false

rm -f "$MOCK_SHARE"
if printf 'reset alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
    reset alice >/dev/null 2>&1; then
    echo 'reset accepted a missing share' >&2
    exit 1
fi
touch "$MOCK_SHARE"

export MOCK_KEY_FAILURE=true
before_key_failure_count="$(grep -c '^azcopy remove' "$MOCK_LOG")"
if printf 'reset alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
    reset alice >/dev/null 2>&1; then
    echo 'reset accepted a missing storage key' >&2
    exit 1
fi
test "$before_key_failure_count" = "$(grep -c '^azcopy remove' "$MOCK_LOG")"
export MOCK_KEY_FAILURE=false

export MOCK_CREATE_FAILURE=home
if printf 'reset alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
    reset alice >/dev/null 2>&1; then
    echo 'reset ignored an Azure Files recreation failure' >&2
    exit 1
fi
export MOCK_CREATE_FAILURE=''
printf 'reset alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
    reset alice >/dev/null

for rejected_command in create update rotate-password; do
    before_mutation_count="$(grep -Ec '^(containerapp (create|update|secret)|containerapp revision|containerapp env storage set|storage share-rm create|rest --method)' "$MOCK_LOG")"
    if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
        "$rejected_command" alice >/dev/null 2>"$TEST_DIR/${rejected_command}.err"; then
        echo "${rejected_command} was accepted while stopped" >&2
        exit 1
    fi
    grep -q 'run.*aca-instance.sh resume alice' "$TEST_DIR/${rejected_command}.err"
    after_mutation_count="$(grep -Ec '^(containerapp (create|update|secret)|containerapp revision|containerapp env storage set|storage share-rm create|rest --method)' "$MOCK_LOG")"
    test "$before_mutation_count" = "$after_mutation_count"
done

stopped_list_output="$($REPO_DIR/aca-instance.sh --config "$TEST_DIR/config.env" list)"
grep -q $'Succeeded\tStopped' <<< "$stopped_list_output"

before_start_count="$(grep -c '/start?api-version=2025-07-01' "$MOCK_LOG" || true)"
resume_output="$($REPO_DIR/aca-instance.sh --config "$TEST_DIR/config.env" resume alice)"
after_start_count="$(grep -c '/start?api-version=2025-07-01' "$MOCK_LOG")"
test "$after_start_count" -eq $((before_start_count + 1))
grep -q $'Succeeded\tRunning' <<< "$resume_output"
grep -q '/healthz' "$MOCK_CURL_LOG"

"$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" resume alice >/dev/null 2>&1
test "$(grep -c '/start?api-version=2025-07-01' "$MOCK_LOG")" = "$after_start_count"

before_running_reset_count="$(grep -c '^azcopy remove' "$MOCK_LOG")"
if printf 'reset alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
    reset alice >/dev/null 2>"$TEST_DIR/running-reset.err"; then
    echo 'reset was accepted while running' >&2
    exit 1
fi
grep -q 'suspend alice' "$TEST_DIR/running-reset.err"
test "$before_running_reset_count" = "$(grep -c '^azcopy remove' "$MOCK_LOG")"

mkdir "$TEST_DIR/download-default"
(
    cd "$TEST_DIR/download-default"
    download_output="$($REPO_DIR/aca-instance.sh --config "$TEST_DIR/config.env" download alice)"
    archive_path="$(grep '^Saved instance data: ' <<< "$download_output")"
    archive_path="${archive_path#Saved instance data: }"
    test -f "$archive_path"
    test "$(stat -c '%a' "$archive_path")" = 600
    tar -tzf "$archive_path" | grep -qx 'home/marker.txt'
    tar -tzf "$archive_path" | grep -qx 'workspace/marker.txt'
)
grep -q '^storage file download-batch.*--source code-server-alice.*--no-progress' "$MOCK_LOG"
if grep '^storage file download-batch' "$MOCK_LOG" | grep -q -- '--account-key test-key'; then
    echo 'download exposed the storage key in command arguments' >&2
    exit 1
fi

explicit_archive="$TEST_DIR/alice-explicit.tar.gz"
"$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" download alice "$explicit_archive" >/dev/null
test -f "$explicit_archive"
mkdir "$TEST_DIR/download-directory"
directory_output="$($REPO_DIR/aca-instance.sh --config "$TEST_DIR/config.env" download alice "$TEST_DIR/download-directory")"
directory_archive="$(grep '^Saved instance data: ' <<< "$directory_output")"
directory_archive="${directory_archive#Saved instance data: }"
test -f "$directory_archive"

printf 'Stopped\n' > "$MOCK_RUNNING"
stopped_archive="$TEST_DIR/alice-stopped.tar.gz"
"$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" download alice "$stopped_archive" >/dev/null
test -f "$stopped_archive"

for state_pair in 'Succeeded Progressing' 'Failed Running' 'Succeeded Unknown'; do
    read -r provisioning running <<< "$state_pair"
    printf '%s\n' "$provisioning" > "$MOCK_PROVISIONING"
    printf '%s\n' "$running" > "$MOCK_RUNNING"
    before_download_count="$(grep -c '^storage file download-batch' "$MOCK_LOG")"
    if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" download alice \
        "$TEST_DIR/rejected-${provisioning}-${running}.tar.gz" >/dev/null 2>&1; then
        echo "download was accepted while provisioning=${provisioning}, running=${running}" >&2
        exit 1
    fi
    test "$before_download_count" = "$(grep -c '^storage file download-batch' "$MOCK_LOG")"
done
printf 'Succeeded\n' > "$MOCK_PROVISIONING"
printf 'Running\n' > "$MOCK_RUNNING"

touch "$TEST_DIR/existing.tar.gz"
if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" download alice \
    "$TEST_DIR/existing.tar.gz" >/dev/null 2>&1; then
    echo 'download overwrote an existing file' >&2
    exit 1
fi
ln -s "$TEST_DIR/missing-target" "$TEST_DIR/dangling.tar.gz"
if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" download alice \
    "$TEST_DIR/dangling.tar.gz" >/dev/null 2>&1; then
    echo 'download accepted a dangling output symlink' >&2
    exit 1
fi
if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" download alice \
    "$TEST_DIR/missing/output.tar.gz" >/dev/null 2>&1; then
    echo 'download accepted a missing output directory' >&2
    exit 1
fi

export MOCK_DOWNLOAD_LAYOUT=home-only
incomplete_archive="$TEST_DIR/incomplete.tar.gz"
if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" download alice \
    "$incomplete_archive" >/dev/null 2>&1; then
    echo 'download accepted an incomplete share layout' >&2
    exit 1
fi
test ! -e "$incomplete_archive"
export MOCK_DOWNLOAD_LAYOUT=complete

rm -f "$MOCK_SHARE"
if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" download alice \
    "$TEST_DIR/no-share.tar.gz" >/dev/null 2>&1; then
    echo 'download accepted a missing share' >&2
    exit 1
fi
touch "$MOCK_SHARE"

printf 'Progressing\n' > "$MOCK_RUNNING"
if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" suspend alice \
    >/dev/null 2>"$TEST_DIR/progressing.err"; then
    echo 'suspend was accepted while progressing' >&2
    exit 1
fi
grep -q 'running=Progressing' "$TEST_DIR/progressing.err"
printf '' > "$MOCK_RUNNING"
if "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" update alice \
    >/dev/null 2>"$TEST_DIR/unknown.err"; then
    echo 'update was accepted with unknown running status' >&2
    exit 1
fi
grep -q 'running=Unknown' "$TEST_DIR/unknown.err"
for state_pair in 'Succeeded Progressing' 'Failed Running' 'Succeeded Unknown'; do
    read -r provisioning running <<< "$state_pair"
    printf '%s\n' "$provisioning" > "$MOCK_PROVISIONING"
    printf '%s\n' "$running" > "$MOCK_RUNNING"
    before_reset_count="$(grep -c '^azcopy remove' "$MOCK_LOG")"
    if printf 'reset alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" \
        reset alice >/dev/null 2>&1; then
        echo "reset was accepted while provisioning=${provisioning}, running=${running}" >&2
        exit 1
    fi
    test "$before_reset_count" = "$(grep -c '^azcopy remove' "$MOCK_LOG")"
done
printf 'Succeeded\n' > "$MOCK_PROVISIONING"
printf 'Stopped\n' > "$MOCK_RUNNING"

printf 'alice\n' | "$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" delete alice >/dev/null
test ! -e "$TEST_DIR/passwords/alice/password"
grep -q 'containerapp delete.*code-server-ol8-alice' "$MOCK_LOG"
grep -q '^containerapp job delete.*code-server-ol8-alice-init' "$MOCK_LOG"
test ! -f "$MOCK_JOB_STATE"
grep -q 'share-rm delete.*code-server-alice' "$MOCK_LOG"

printf 'Running\n' > "$MOCK_RUNNING"
"$REPO_DIR/aca-instance.sh" --config "$TEST_DIR/config.env" create bob \
    --scaling-mode enabled --min-replicas 0 --cooldown-period 120 >/dev/null
test "$(cat "$MOCK_MIN")" = 0
test "$(cat "$MOCK_COOLDOWN")" = 120
test "$(cat "$MOCK_RULE")" = code-server-http

echo 'aca-instance tests: PASS'
