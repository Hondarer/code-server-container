#!/bin/bash

# Manage isolated, single-user code-server instances on Azure Container Apps.

set -euo pipefail

echo "Started: $(date +'%Y-%m-%dT%H:%M:%S.%3N%:z')"

# Azure CLIのPreview/extension通知は通常運用では抑制し、実際のエラーは表示する。
# 診断時は AZURE_CORE_ONLY_SHOW_ERRORS=false を指定すると警告を再表示できる。
export AZURE_CORE_ONLY_SHOW_ERRORS="${AZURE_CORE_ONLY_SHOW_ERRORS:-true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CODE_SERVER_ACA_CONFIG:-${HOME}/.azure/code-server-aca.env}"
TEMPLATE_FILE="${SCRIPT_DIR}/docs/azure-container-apps-persistent.yaml.template"
JOB_TEMPLATE_FILE="${SCRIPT_DIR}/docs/azure-container-apps-init-job.yaml.template"

usage() {
    cat <<'EOF'
Usage: ./aca-instance.sh [--config FILE] COMMAND [INSTANCE]

Commands:
  doctor                     Validate CLI access and shared Azure resources
  create INSTANCE [--scaling-mode disabled|enabled]
                  [--min-replicas 0|1] [--cooldown-period SECONDS]
                             Create one persistent instance
  update INSTANCE            Deploy the configured image to one instance
  suspend INSTANCE           Stop compute while keeping data and configuration
  resume INSTANCE            Start a suspended instance and verify its health
  list                       Print every managed URL/password pair
  show INSTANCE              Print one URL/password pair
  rotate-password INSTANCE   Replace the instance password and restart it
  download INSTANCE [PATH]   Archive the instance's home and workspace data
  reset INSTANCE             Empty home and workspace while the instance is stopped
  delete INSTANCE            Delete the app, storage mapping, share and password

INSTANCE is a lowercase DNS slug, for example alice or team-1.
WARNING: list and show intentionally print passwords in plaintext.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

warn() {
    echo "Warning: $*" >&2
}

if [ "${1:-}" = "--config" ]; then
    [ "$#" -ge 3 ] || die "--config requires a file and a command."
    CONFIG_FILE="$2"
    shift 2
fi

COMMAND="${1:-}"
[ -n "$COMMAND" ] || {
    usage
    exit 1
}
shift

[ -f "$CONFIG_FILE" ] || die "Config file not found: ${CONFIG_FILE}"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${RESOURCE_GROUP:?RESOURCE_GROUP is required in ${CONFIG_FILE}}"
: "${LOCATION:?LOCATION is required in ${CONFIG_FILE}}"
: "${ENVIRONMENT_NAME:?ENVIRONMENT_NAME is required in ${CONFIG_FILE}}"
: "${IDENTITY_NAME:?IDENTITY_NAME is required in ${CONFIG_FILE}}"
: "${ACR_NAME:?ACR_NAME is required in ${CONFIG_FILE}}"
: "${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is required in ${CONFIG_FILE}}"
: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required in ${CONFIG_FILE}}"

APP_NAME_PREFIX="${APP_NAME_PREFIX:-code-server-ol8}"
FILE_SHARE_PREFIX="${FILE_SHARE_PREFIX:-code-server}"
ENV_STORAGE_PREFIX="${ENV_STORAGE_PREFIX:-code-server}"
PASSWORD_DIR="${PASSWORD_DIR:-${HOME}/.azure/code-server-aca/instances}"
FILE_SHARE_QUOTA_GIB="${FILE_SHARE_QUOTA_GIB:-40}"
CONTAINER_APP_CPU="${CONTAINER_APP_CPU:-4.0}"
CONTAINER_APP_MEMORY="${CONTAINER_APP_MEMORY:-8Gi}"
SCALING_MODE="${SCALING_MODE:-disabled}"
SCALING_MIN_REPLICAS="${SCALING_MIN_REPLICAS:-0}"
SCALING_COOLDOWN_PERIOD="${SCALING_COOLDOWN_PERIOD:-3600}"
CONTAINER_APP_LIFECYCLE_API_VERSION="2025-07-01"
LIFECYCLE_WAIT_ATTEMPTS=60
LIFECYCLE_WAIT_INTERVAL_SECONDS=5
# init Jobの拡張機能再展開はAzure Files(SMB)のI/O遅延で数分〜十数分かかることがあるため、
# App自体のRunning/Stopped遷移より大幅に長い猶予を用意する。Jobのreplica-timeout(1800秒)
# と揃える。
JOB_WAIT_ATTEMPTS=120
JOB_WAIT_INTERVAL_SECONDS=15

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_container_app_resources() {
    local cpu="$1" memory="$2"
    case "${cpu}:${memory}" in
        0.25:0.5Gi|0.5:1Gi|0.75:1.5Gi|1.0:2Gi|1.25:2.5Gi|1.5:3Gi|1.75:3.5Gi|\
        2.0:4Gi|2.25:4.5Gi|2.5:5Gi|2.75:5.5Gi|3.0:6Gi|3.25:6.5Gi|3.5:7Gi|\
        3.75:7.5Gi|4.0:8Gi) ;;
        *)
            die "Invalid Container App resources '${cpu} / ${memory}'; use a Consumption CPU/memory pair from 0.25/0.5Gi through 4.0/8Gi."
            ;;
    esac
}

validate_scaling_values() {
    local mode="$1" min_replicas="$2" cooldown_period="$3"
    case "$mode" in
        disabled|enabled) ;;
        *) die "Invalid scaling mode '${mode}'; use disabled or enabled." ;;
    esac
    case "$min_replicas" in
        0|1) ;;
        *) die "Invalid min replicas '${min_replicas}'; use 0 or 1." ;;
    esac
    [[ "$cooldown_period" =~ ^[0-9]+$ ]] && [ "$cooldown_period" -le 2147483647 ] ||
        die "Invalid cooldown period '${cooldown_period}'; use 0-2147483647 seconds."
}

set_desired_scaling() {
    validate_scaling_values "$1" "$2" "$3"
    DESIRED_SCALING_MODE="$1"
    if [ "$DESIRED_SCALING_MODE" = enabled ]; then
        DESIRED_MIN_REPLICAS="$2"
        DESIRED_COOLDOWN_PERIOD="$3"
        DESIRED_SCALE_RULES='[{"name":"code-server-http","http":{"metadata":{"concurrentRequests":"10"}}}]'
        [ "$DESIRED_MIN_REPLICAS" != 1 ] ||
            warn "Scaling is enabled with min replicas 1; the App will not scale to zero."
    else
        DESIRED_MIN_REPLICAS=1
        DESIRED_COOLDOWN_PERIOD=null
        DESIRED_SCALE_RULES='[]'
    fi
}

render_app_yaml() {
    local output_file="$1"
    sed \
        -e "s|__IDENTITY_ID__|${IDENTITY_ID}|g" \
        -e "s|__LOCATION__|${LOCATION}|g" \
        -e "s|__APP_NAME__|${APP_NAME}|g" \
        -e "s|__RESOURCE_GROUP__|${RESOURCE_GROUP}|g" \
        -e "s|__ENVIRONMENT_ID__|${ENVIRONMENT_ID}|g" \
        -e "s|__ACR_LOGIN_SERVER__|${ACR_LOGIN_SERVER}|g" \
        -e "s|__REMOTE_IMAGE__|${REMOTE_IMAGE}|g" \
        -e "s|__ENV_STORAGE_NAME__|${ENV_STORAGE_NAME}|g" \
        -e "s|__CONTAINER_APP_CPU__|${CONTAINER_APP_CPU}|g" \
        -e "s|__CONTAINER_APP_MEMORY__|${CONTAINER_APP_MEMORY}|g" \
        -e "s|__MIN_REPLICAS__|${DESIRED_MIN_REPLICAS}|g" \
        -e "s|__COOLDOWN_PERIOD__|${DESIRED_COOLDOWN_PERIOD}|g" \
        -e "s|__SCALE_RULES__|${DESIRED_SCALE_RULES}|g" \
        "$TEMPLATE_FILE" > "$output_file"
    if grep -qE '__[A-Z_]+__' "$output_file"; then
        die "Unresolved placeholder in rendered YAML: ${output_file}"
    fi
}

validate_slug() {
    local slug="$1" app_name share_name storage_name job_name
    [[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
        die "Invalid instance slug '${slug}'; use lowercase letters, numbers and single hyphens."
    app_name="${APP_NAME_PREFIX}-${slug}"
    share_name="${FILE_SHARE_PREFIX}-${slug}"
    storage_name="${ENV_STORAGE_PREFIX}-${slug}-storage"
    job_name="${app_name}-init"
    [ "${#app_name}" -le 32 ] || die "Container App name exceeds 32 characters: ${app_name}"
    [ "${#share_name}" -ge 3 ] && [ "${#share_name}" -le 63 ] ||
        die "Azure Files share name must contain 3-63 characters: ${share_name}"
    [ "${#storage_name}" -le 63 ] || die "Environment storage name is too long: ${storage_name}"
    [ "${#job_name}" -le 32 ] || die "init Job name exceeds 32 characters: ${job_name}"
}

set_instance_vars() {
    INSTANCE_SLUG="$1"
    validate_slug "$INSTANCE_SLUG"
    APP_NAME="${APP_NAME_PREFIX}-${INSTANCE_SLUG}"
    FILE_SHARE="${FILE_SHARE_PREFIX}-${INSTANCE_SLUG}"
    ENV_STORAGE_NAME="${ENV_STORAGE_PREFIX}-${INSTANCE_SLUG}-storage"
    JOB_NAME="${APP_NAME}-init"
    INSTANCE_PASSWORD_DIR="${PASSWORD_DIR}/${INSTANCE_SLUG}"
    PASSWORD_FILE="${INSTANCE_PASSWORD_DIR}/password"
    if [ "$INSTANCE_SLUG" = "1" ] && [ ! -s "$PASSWORD_FILE" ] &&
        [ -s "${HOME}/.azure/code-server-aca-password" ]; then
        PASSWORD_FILE="${HOME}/.azure/code-server-aca-password"
    fi
}

load_shared_values() {
    ACR_LOGIN_SERVER="$(az acr show -g "$RESOURCE_GROUP" -n "$ACR_NAME" --query loginServer -o tsv)"
    IDENTITY_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" --query id -o tsv)"
    ENVIRONMENT_ID="$(az containerapp env show -g "$RESOURCE_GROUP" -n "$ENVIRONMENT_NAME" --query id -o tsv)"

    if [ -n "${REMOTE_IMAGE:-}" ]; then
        return
    fi
    if [ -n "${IMAGE_TAG:-}" ] && [ "$IMAGE_TAG" != "replace_with_immutable_tag" ]; then
        REMOTE_IMAGE="${ACR_LOGIN_SERVER}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"
        return
    fi
    REMOTE_IMAGE="$(az containerapp show -g "$RESOURCE_GROUP" -n "${APP_NAME_PREFIX}-1" \
        --query 'properties.template.containers[0].image' -o tsv 2>/dev/null || true)"
    if [ -z "$REMOTE_IMAGE" ]; then
        local latest_tag
        latest_tag="$(az acr repository show-tags -n "$ACR_NAME" --repository "$IMAGE_REPOSITORY" \
            --orderby time_desc --top 1 -o tsv)"
        [ -n "$latest_tag" ] || die "No image tag found in ACR repository ${IMAGE_REPOSITORY}."
        REMOTE_IMAGE="${ACR_LOGIN_SERVER}/${IMAGE_REPOSITORY}:${latest_tag}"
    fi
}

password_for_instance() {
    [ -s "$PASSWORD_FILE" ] || die "Password file not found: ${PASSWORD_FILE}"
    sed -n '1p' "$PASSWORD_FILE"
}

password_is_unique() {
    local candidate="$1" file
    while IFS= read -r -d '' file; do
        [ "$file" = "$PASSWORD_FILE" ] && continue
        [ "$(sed -n '1p' "$file")" != "$candidate" ] || return 1
    done < <(find "$PASSWORD_DIR" -type f -name password -print0 2>/dev/null || true)
    return 0
}

generate_password_file() {
    local candidate
    install -d -m 700 "$INSTANCE_PASSWORD_DIR"
    if [ -s "$PASSWORD_FILE" ]; then
        return
    fi
    umask 077
    while :; do
        candidate="$(openssl rand -hex 32)"
        password_is_unique "$candidate" && break
    done
    printf '%s\n' "$candidate" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    unset candidate
}

read_lifecycle_state() {
    PROVISIONING_STATE="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
        --query properties.provisioningState -o tsv)"
    RUNNING_STATUS="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
        --query properties.runningStatus -o tsv)"
    PROVISIONING_STATE="${PROVISIONING_STATE:-Unknown}"
    RUNNING_STATUS="${RUNNING_STATUS:-Unknown}"
}

require_running_instance() {
    local operation="$1"
    read_lifecycle_state
    if [ "$PROVISIONING_STATE" = "Succeeded" ] && [ "$RUNNING_STATUS" = "Running" ]; then
        return
    fi
    if [ "$RUNNING_STATUS" = "Stopped" ]; then
        warn "${APP_NAME} is stopped; run './aca-instance.sh resume ${INSTANCE_SLUG}' before ${operation}."
    else
        warn "${APP_NAME} cannot accept ${operation} while provisioning=${PROVISIONING_STATE}, running=${RUNNING_STATUS}."
    fi
    die "Instance lifecycle state does not permit ${operation}."
}

require_readable_instance() {
    local operation="$1"
    read_lifecycle_state
    if [ "$PROVISIONING_STATE" = "Succeeded" ]; then
        case "$RUNNING_STATUS" in
            Running|Stopped) return ;;
        esac
    fi
    warn "${APP_NAME} cannot accept ${operation} while provisioning=${PROVISIONING_STATE}, running=${RUNNING_STATUS}."
    die "Instance lifecycle state does not permit ${operation}."
}

require_stopped_instance() {
    local operation="$1"
    read_lifecycle_state
    if [ "$PROVISIONING_STATE" = "Succeeded" ] && [ "$RUNNING_STATUS" = "Stopped" ]; then
        return
    fi
    if [ "$RUNNING_STATUS" = "Running" ]; then
        warn "${APP_NAME} is running; run './aca-instance.sh suspend ${INSTANCE_SLUG}' before ${operation}."
    else
        warn "${APP_NAME} cannot accept ${operation} while provisioning=${PROVISIONING_STATE}, running=${RUNNING_STATUS}."
    fi
    die "Instance lifecycle state does not permit ${operation}."
}

show_pair() {
    local fqdn password
    fqdn="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
        --query properties.configuration.ingress.fqdn -o tsv)"
    read_lifecycle_state
    password="$(password_for_instance)"
    printf 'INSTANCE\tURL\tPASSWORD\tPROVISIONING\tRUNNING\n'
    printf '%s\thttps://%s/\t%s\t%s\t%s\n' \
        "$INSTANCE_SLUG" "$fqdn" "$password" "$PROVISIONING_STATE" "$RUNNING_STATUS"
}

show_lifecycle_status() {
    local fqdn
    fqdn="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
        --query properties.configuration.ingress.fqdn -o tsv)"
    read_lifecycle_state
    printf 'INSTANCE\tURL\tPROVISIONING\tRUNNING\n'
    printf '%s\thttps://%s/\t%s\t%s\n' \
        "$INSTANCE_SLUG" "$fqdn" "$PROVISIONING_STATE" "$RUNNING_STATUS"
}

wait_for_running_status() {
    local expected="$1" attempt last_status=Unknown
    for attempt in $(seq 1 "$LIFECYCLE_WAIT_ATTEMPTS"); do
        last_status="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
            --query properties.runningStatus -o tsv)"
        last_status="${last_status:-Unknown}"
        if [ "$last_status" = "$expected" ]; then
            return 0
        fi
        sleep "$LIFECYCLE_WAIT_INTERVAL_SECONDS"
    done
    die "Timed out waiting for ${APP_NAME} to become ${expected}; last running status: ${last_status}."
}

wait_for_health() {
    local fqdn="$1" attempt
    for attempt in $(seq 1 24); do
        if curl -fsS "https://${fqdn}/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    die "Health check failed after 120 seconds: https://${fqdn}/healthz"
}

wait_for_job_execution() {
    local execution_name="$1" attempt status=Unknown
    for attempt in $(seq 1 "$JOB_WAIT_ATTEMPTS"); do
        status="$(az containerapp job execution show -g "$RESOURCE_GROUP" -n "$JOB_NAME" \
            --job-execution-name "$execution_name" --query properties.status -o tsv)"
        status="${status:-Unknown}"
        case "$status" in
            Succeeded) return 0 ;;
            Failed) die "init Job execution ${execution_name} failed for ${JOB_NAME}." ;;
        esac
        sleep "$JOB_WAIT_INTERVAL_SECONDS"
    done
    die "Timed out waiting for init Job execution ${execution_name} to finish; last status: ${status}."
}

# home/workspace の初期化 (既定設定・拡張機能の導入) を、ingress・startup probe付きの
# App起動より前に、専用のinit Jobとして完了させる。Azure Filesは拡張機能の再展開に
# ローカルディスクより時間がかかり、Container Appsの既定startup probe猶予を超えると
# CrashLoopBackOffになるため、Appを起動する前にここで初期化を終わらせておく。
run_init_job() {
    local password rendered_yaml execution_name
    [ -f "$JOB_TEMPLATE_FILE" ] || die "init Job template not found: ${JOB_TEMPLATE_FILE}"
    password="$(password_for_instance)"

    rendered_yaml="$(mktemp "/tmp/${JOB_NAME}.XXXXXX.yaml")"
    trap 'rm -f "${rendered_yaml:-}"' RETURN
    sed \
        -e "s|__IDENTITY_ID__|${IDENTITY_ID}|g" \
        -e "s|__LOCATION__|${LOCATION}|g" \
        -e "s|__JOB_NAME__|${JOB_NAME}|g" \
        -e "s|__RESOURCE_GROUP__|${RESOURCE_GROUP}|g" \
        -e "s|__ENVIRONMENT_ID__|${ENVIRONMENT_ID}|g" \
        -e "s|__ACR_LOGIN_SERVER__|${ACR_LOGIN_SERVER}|g" \
        -e "s|__REMOTE_IMAGE__|${REMOTE_IMAGE}|g" \
        -e "s|__ENV_STORAGE_NAME__|${ENV_STORAGE_NAME}|g" \
        "$JOB_TEMPLATE_FILE" > "$rendered_yaml"
    if grep -qE '__[A-Z_]+__' "$rendered_yaml"; then
        die "Unresolved placeholder in rendered init Job YAML: ${rendered_yaml}"
    fi

    if ! az containerapp job show -g "$RESOURCE_GROUP" -n "$JOB_NAME" >/dev/null 2>&1; then
        # secretsブロックは値を持たないため(Secretの値をtemplateへ含めない方針)、
        # 新規作成時はまずCLI引数で値付きのSecretを確立してから、YAMLで残りの構成
        # (volumes/command/registries等)を適用する。App作成と同じ二段階パターン。
        az containerapp job create -g "$RESOURCE_GROUP" -n "$JOB_NAME" \
            --environment "$ENVIRONMENT_NAME" --trigger-type Manual \
            --replica-timeout 1800 --replica-retry-limit 0 \
            --replica-completion-count 1 --parallelism 1 \
            --image "$REMOTE_IMAGE" --mi-user-assigned "$IDENTITY_ID" \
            --registry-server "$ACR_LOGIN_SERVER" --registry-identity "$IDENTITY_ID" \
            --secrets "code-server-password=${password}" \
            -o none
    fi
    az containerapp job update -g "$RESOURCE_GROUP" -n "$JOB_NAME" --yaml "$rendered_yaml" -o none
    az containerapp job secret set -g "$RESOURCE_GROUP" -n "$JOB_NAME" \
        --secrets "code-server-password=${password}" -o none
    unset password

    echo "Running init Job ${JOB_NAME} to pre-populate home/workspace..." >&2
    execution_name="$(az containerapp job start -g "$RESOURCE_GROUP" -n "$JOB_NAME" \
        --query name -o tsv)"
    [ -n "$execution_name" ] || die "Could not determine execution name for ${JOB_NAME}."
    wait_for_job_execution "$execution_name"
    echo "init Job ${JOB_NAME} completed successfully." >&2
}

tag_app() {
    local app_id
    app_id="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" --query id -o tsv)"
    az tag create --resource-id "$app_id" --tags \
        application=code-server environment=production managed-by=aca-instance.sh -o none
}

doctor() {
    require_command az
    require_command openssl
    require_command sed
    require_command curl
    az account show --query '{subscription:name,subscriptionId:id,tenantId:tenantId}' -o table
    load_shared_values
    az storage account show -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" \
        --query '{name:name,state:provisioningState,location:location}' -o table
    printf 'Environment: %s\nRegistry: %s\nIdentity: %s\nImage: %s\n' \
        "$ENVIRONMENT_NAME" "$ACR_LOGIN_SERVER" "$IDENTITY_NAME" "$REMOTE_IMAGE"
}

create_instance() {
    local password storage_key rendered_yaml fqdn app_exists=false
    local existing_storage existing_min existing_max existing_image existing_cooldown existing_rule
    local existing_cpu existing_memory
    set_instance_vars "$1"
    validate_container_app_resources "$CONTAINER_APP_CPU" "$CONTAINER_APP_MEMORY"
    set_desired_scaling "$2" "$3" "$4"
    require_command az
    require_command openssl
    require_command sed
    require_command curl
    [ -f "$TEMPLATE_FILE" ] || die "Template not found: ${TEMPLATE_FILE}"
    load_shared_values

    if az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" >/dev/null 2>&1; then
        [ -s "$PASSWORD_FILE" ] || die "${APP_NAME} exists but its local password file is missing."
        app_exists=true
        require_running_instance create
        existing_storage="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
            --query 'properties.template.volumes[0].storageName' -o tsv)"
        existing_min="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
            --query 'properties.template.scale.minReplicas' -o tsv)"
        existing_max="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
            --query 'properties.template.scale.maxReplicas' -o tsv)"
        existing_cooldown="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
            --query 'properties.template.scale.cooldownPeriod' -o tsv)"
        existing_rule="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
            --query 'properties.template.scale.rules[0].name' -o tsv)"
        existing_cpu="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
            --query 'properties.template.containers[0].resources.cpu' -o tsv)"
        existing_memory="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
            --query 'properties.template.containers[0].resources.memory' -o tsv)"
        existing_image="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
            --query 'properties.template.containers[0].image' -o tsv)"
        [ "$existing_image" = "$REMOTE_IMAGE" ] ||
            die "${APP_NAME} uses an unexpected image: ${existing_image}"
        if [ -n "$existing_storage" ] && [ "$existing_storage" != "$ENV_STORAGE_NAME" ]; then
            die "${APP_NAME} uses unexpected storage: ${existing_storage}"
        fi
        if [ "$existing_storage" = "$ENV_STORAGE_NAME" ] &&
            [ "$existing_cpu" = "$CONTAINER_APP_CPU" ] &&
            [ "$existing_memory" = "$CONTAINER_APP_MEMORY" ] && [ "$existing_max" = 1 ] &&
            { { [ "$DESIRED_SCALING_MODE" = disabled ] && [ "$existing_min" = 1 ] &&
                [ -z "$existing_rule" ]; } ||
              { [ "$DESIRED_SCALING_MODE" = enabled ] &&
                [ "$existing_min" = "$DESIRED_MIN_REPLICAS" ] &&
                [ "$existing_cooldown" = "$DESIRED_COOLDOWN_PERIOD" ] &&
                [ "$existing_rule" = code-server-http ]; }; }; then
            echo "Instance already exists; validating the recorded pair." >&2
            tag_app
            fqdn="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
                --query properties.configuration.ingress.fqdn -o tsv)"
            wait_for_health "$fqdn"
            show_pair
            return
        fi
        if [ "$existing_storage" = "$ENV_STORAGE_NAME" ]; then
            die "${APP_NAME} configuration differs from the requested resources or scaling; run './aca-instance.sh update ${INSTANCE_SLUG}'."
        fi
        echo "Resuming incomplete instance ${INSTANCE_SLUG}." >&2
    else
        generate_password_file
    fi

    password="$(password_for_instance)"

    if ! az storage share-rm show -g "$RESOURCE_GROUP" --storage-account "$STORAGE_ACCOUNT" \
        -n "$FILE_SHARE" >/dev/null 2>&1; then
        az storage share-rm create -g "$RESOURCE_GROUP" --storage-account "$STORAGE_ACCOUNT" \
            -n "$FILE_SHARE" --quota "$FILE_SHARE_QUOTA_GIB" --enabled-protocols SMB -o none
    fi
    storage_key="$(az storage account keys list -g "$RESOURCE_GROUP" --account-name "$STORAGE_ACCOUNT" \
        --query '[0].value' -o tsv)"
    az storage directory create --account-name "$STORAGE_ACCOUNT" --account-key "$storage_key" \
        --share-name "$FILE_SHARE" --name home -o none
    az storage directory create --account-name "$STORAGE_ACCOUNT" --account-key "$storage_key" \
        --share-name "$FILE_SHARE" --name workspace -o none
    az containerapp env storage set -g "$RESOURCE_GROUP" -n "$ENVIRONMENT_NAME" \
        --storage-name "$ENV_STORAGE_NAME" --storage-type AzureFile \
        --azure-file-account-name "$STORAGE_ACCOUNT" --azure-file-account-key "$storage_key" \
        --azure-file-share-name "$FILE_SHARE" --access-mode ReadWrite -o none
    unset storage_key

    run_init_job

    if [ "$app_exists" = false ]; then
        az containerapp create -g "$RESOURCE_GROUP" -n "$APP_NAME" --environment "$ENVIRONMENT_NAME" \
            --image "$REMOTE_IMAGE" --user-assigned "$IDENTITY_ID" \
            --registry-server "$ACR_LOGIN_SERVER" --registry-identity "$IDENTITY_ID" \
            --target-port 8080 --ingress external --transport auto --allow-insecure false \
            --min-replicas 0 --max-replicas 1 --cpu 1.0 --memory 2.0Gi \
            --tags application=code-server environment=production managed-by=aca-instance.sh \
            --secrets "code-server-password=${password}" \
            --env-vars HOST_USER=user HOST_UID=1000 HOST_GID=1000 PASSWORD=secretref:code-server-password \
            -o none
    fi
    unset password

    rendered_yaml="$(mktemp "/tmp/${APP_NAME}.XXXXXX.yaml")"
    trap 'rm -f "${rendered_yaml:-}"' RETURN
    render_app_yaml "$rendered_yaml"
    az containerapp update -g "$RESOURCE_GROUP" -n "$APP_NAME" --yaml "$rendered_yaml" -o none
    tag_app
    az containerapp revision set-mode -g "$RESOURCE_GROUP" -n "$APP_NAME" --mode single -o none

    fqdn="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
        --query properties.configuration.ingress.fqdn -o tsv)"
    wait_for_running_status Running
    wait_for_health "$fqdn"
    show_pair
}

update_instance() {
    local fqdn rendered_yaml
    set_instance_vars "$1"
    validate_container_app_resources "$CONTAINER_APP_CPU" "$CONTAINER_APP_MEMORY"
    require_command az
    require_command curl
    az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" >/dev/null
    require_running_instance update
    [ -s "$PASSWORD_FILE" ] || die "Password file not found: ${PASSWORD_FILE}"
    load_shared_values
    set_desired_scaling "$SCALING_MODE" "$SCALING_MIN_REPLICAS" "$SCALING_COOLDOWN_PERIOD"
    rendered_yaml="$(mktemp "/tmp/${APP_NAME}.XXXXXX.yaml")"
    trap 'rm -f "${rendered_yaml:-}"' RETURN
    render_app_yaml "$rendered_yaml"
    az containerapp update -g "$RESOURCE_GROUP" -n "$APP_NAME" --yaml "$rendered_yaml" -o none
    tag_app
    az containerapp revision set-mode -g "$RESOURCE_GROUP" -n "$APP_NAME" --mode single -o none
    fqdn="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
        --query properties.configuration.ingress.fqdn -o tsv)"
    wait_for_running_status Running
    wait_for_health "$fqdn"
    show_pair
}

suspend_instance() {
    local app_id
    set_instance_vars "$1"
    require_command az
    az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" >/dev/null
    read_lifecycle_state
    [ "$PROVISIONING_STATE" = "Succeeded" ] || {
        warn "${APP_NAME} cannot be suspended while provisioning=${PROVISIONING_STATE}."
        die "Instance lifecycle state does not permit suspend."
    }
    case "$RUNNING_STATUS" in
        Stopped)
            echo "Instance ${INSTANCE_SLUG} is already suspended." >&2
            show_lifecycle_status
            return
            ;;
        Running) ;;
        *)
            warn "${APP_NAME} cannot be suspended while running=${RUNNING_STATUS}."
            die "Instance lifecycle state does not permit suspend."
            ;;
    esac
    app_id="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" --query id -o tsv)"
    az rest --method post \
        --url "${app_id}/stop?api-version=${CONTAINER_APP_LIFECYCLE_API_VERSION}" -o none
    wait_for_running_status Stopped
    show_lifecycle_status
}

resume_instance() {
    local app_id fqdn
    set_instance_vars "$1"
    require_command az
    require_command curl
    az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" >/dev/null
    read_lifecycle_state
    [ "$PROVISIONING_STATE" = "Succeeded" ] || {
        warn "${APP_NAME} cannot be resumed while provisioning=${PROVISIONING_STATE}."
        die "Instance lifecycle state does not permit resume."
    }
    case "$RUNNING_STATUS" in
        Running)
            echo "Instance ${INSTANCE_SLUG} is already running; validating health." >&2
            ;;
        Stopped)
            app_id="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" --query id -o tsv)"
            az rest --method post \
                --url "${app_id}/start?api-version=${CONTAINER_APP_LIFECYCLE_API_VERSION}" -o none
            wait_for_running_status Running
            ;;
        *)
            warn "${APP_NAME} cannot be resumed while running=${RUNNING_STATUS}."
            die "Instance lifecycle state does not permit resume."
            ;;
    esac
    fqdn="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" \
        --query properties.configuration.ingress.fqdn -o tsv)"
    wait_for_health "$fqdn"
    show_lifecycle_status
}

list_instances() {
    local name fqdn provisioning running min_replicas max_replicas cooldown rule
    local slug password_file password scaling replicas
    printf 'INSTANCE\tURL\tPASSWORD\tPROVISIONING\tRUNNING\tSCALING\tMIN\tMAX\tCOOLDOWN\tREPLICAS\n'
    while IFS=$'\t' read -r name fqdn provisioning running min_replicas max_replicas cooldown rule; do
        [ -n "$name" ] || continue
        case "$name" in
            "${APP_NAME_PREFIX}-"*) ;;
            *) continue ;;
        esac
        slug="${name#${APP_NAME_PREFIX}-}"
        password_file="${PASSWORD_DIR}/${slug}/password"
        if [ "$slug" = "1" ] && [ ! -s "$password_file" ] &&
            [ -s "${HOME}/.azure/code-server-aca-password" ]; then
            password_file="${HOME}/.azure/code-server-aca-password"
        fi
        password='<PASSWORD_FILE_MISSING>'
        [ ! -s "$password_file" ] || password="$(sed -n '1p' "$password_file")"
        provisioning="${provisioning:-Unknown}"
        running="${running:-Unknown}"
        min_replicas="${min_replicas:-Unknown}"
        max_replicas="${max_replicas:-Unknown}"
        case "$rule" in
            code-server-http)
                scaling=Enabled
                cooldown="${cooldown:-Unknown}"
                ;;
            ''|-|None|null)
                if [ "$min_replicas" = 1 ] && [ "$max_replicas" = 1 ]; then
                    scaling=Disabled
                    cooldown=-
                else
                    scaling=Custom
                    cooldown="${cooldown:-Unknown}"
                fi
                ;;
            *) scaling=Custom; cooldown="${cooldown:-Unknown}" ;;
        esac
        replicas="$(az containerapp replica list -g "$RESOURCE_GROUP" -n "$name" \
            --query 'length(@)' -o tsv 2>/dev/null || true)"
        if [ -z "$replicas" ]; then
            [ "$running" = Stopped ] && replicas=0 || replicas=Unknown
        fi
        printf '%s\thttps://%s/\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$slug" "$fqdn" "$password" "$provisioning" "$running" "$scaling" \
            "$min_replicas" "$max_replicas" "$cooldown" "$replicas"
    done < <(az containerapp list -g "$RESOURCE_GROUP" \
        --query "[].{name:name,fqdn:properties.configuration.ingress.fqdn,provisioning:properties.provisioningState,running:properties.runningStatus,min:not_null(properties.template.scale.minReplicas, '-'),max:not_null(properties.template.scale.maxReplicas, '-'),cooldown:not_null(properties.template.scale.cooldownPeriod, '-'),rule:not_null(properties.template.scale.rules[0].name, '-')}" \
        -o tsv)
}

rotate_password() {
    local candidate_file candidate revision
    set_instance_vars "$1"
    az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" >/dev/null
    require_running_instance rotate-password
    install -d -m 700 "$INSTANCE_PASSWORD_DIR"
    candidate_file="${INSTANCE_PASSWORD_DIR}/.password.new"
    umask 077
    while :; do
        candidate="$(openssl rand -hex 32)"
        password_is_unique "$candidate" && break
    done
    printf '%s\n' "$candidate" > "$candidate_file"
    chmod 600 "$candidate_file"
    az containerapp secret set -g "$RESOURCE_GROUP" -n "$APP_NAME" \
        --secrets "code-server-password=${candidate}" -o none
    if az containerapp job show -g "$RESOURCE_GROUP" -n "$JOB_NAME" >/dev/null 2>&1; then
        az containerapp job secret set -g "$RESOURCE_GROUP" -n "$JOB_NAME" \
            --secrets "code-server-password=${candidate}" -o none
    fi
    mv -f "$candidate_file" "${INSTANCE_PASSWORD_DIR}/password"
    PASSWORD_FILE="${INSTANCE_PASSWORD_DIR}/password"
    revision="$(az containerapp revision list -g "$RESOURCE_GROUP" -n "$APP_NAME" \
        --query '[?properties.active].name | [0]' -o tsv)"
    [ -n "$revision" ] || die "No active revision found for ${APP_NAME}."
    az containerapp revision restart -g "$RESOURCE_GROUP" -n "$APP_NAME" --revision "$revision" -o none
    unset candidate
    show_pair
}

download_instance() {
    local output_arg="${2:-}" timestamp output_path output_dir output_name
    local download_dir='' archive_tmp='' storage_key=''
    set_instance_vars "$1"
    require_command az
    require_command tar
    az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" >/dev/null
    require_readable_instance download
    az storage share-rm show -g "$RESOURCE_GROUP" --storage-account "$STORAGE_ACCOUNT" \
        -n "$FILE_SHARE" >/dev/null 2>&1 || die "Azure Files share not found: ${FILE_SHARE}"

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    if [ -z "$output_arg" ]; then
        output_path="./${INSTANCE_SLUG}-${timestamp}.tar.gz"
    elif [ -d "$output_arg" ]; then
        output_path="${output_arg%/}/${INSTANCE_SLUG}-${timestamp}.tar.gz"
    else
        output_path="$output_arg"
    fi
    output_dir="$(dirname -- "$output_path")"
    output_name="$(basename -- "$output_path")"
    [ -d "$output_dir" ] || die "Output directory not found: ${output_dir}"
    if [ -e "$output_path" ] || [ -L "$output_path" ]; then
        die "Output file already exists: ${output_path}"
    fi

    umask 077
    download_dir="$(mktemp -d -t "code-server-${INSTANCE_SLUG}-download.XXXXXX")"
    archive_tmp="$(mktemp "${output_dir}/.${output_name}.tmp.XXXXXX")"
    trap 'rm -rf -- "${download_dir:-}"; rm -f -- "${archive_tmp:-}"' EXIT
    storage_key="$(az storage account keys list -g "$RESOURCE_GROUP" \
        --account-name "$STORAGE_ACCOUNT" --query '[0].value' -o tsv)"
    [ -n "$storage_key" ] || die "Could not retrieve a key for storage account ${STORAGE_ACCOUNT}."
    AZURE_STORAGE_KEY="$storage_key" az storage file download-batch \
        --account-name "$STORAGE_ACCOUNT" --source "$FILE_SHARE" \
        --destination "$download_dir" --no-progress -o none
    unset storage_key

    [ -d "$download_dir/home" ] || die "Downloaded share does not contain the home directory."
    [ -d "$download_dir/workspace" ] || die "Downloaded share does not contain the workspace directory."
    tar -czf "$archive_tmp" -C "$download_dir" home workspace
    chmod 600 "$archive_tmp"
    mv -n -- "$archive_tmp" "$output_path"
    [ ! -e "$archive_tmp" ] || die "Output file already exists: ${output_path}"
    rm -rf -- "$download_dir"
    download_dir=''
    trap - EXIT
    printf 'Saved instance data: %s\n' "$output_path"
}

# Git object files carry the read-only attribute, which `az storage remove` cannot
# override. Call AzCopy directly with a short-lived share SAS instead of the key.
remove_share_directory() {
    local storage_key="$1" directory="$2" azcopy_bin sas expiry
    azcopy_bin="$(command -v azcopy || true)"
    [ -n "$azcopy_bin" ] || azcopy_bin="${AZURE_CONFIG_DIR:-$HOME/.azure}/bin/azcopy"
    [ -x "$azcopy_bin" ] || die "AzCopy not found; run any 'az storage copy' command once to install it."
    expiry="$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%MZ')"
    sas="$(AZURE_STORAGE_KEY="$storage_key" az storage share generate-sas \
        --account-name "$STORAGE_ACCOUNT" --name "$FILE_SHARE" --permissions rwdl \
        --expiry "$expiry" --https-only -o tsv)"
    [ -n "$sas" ] || die "Could not create a SAS for share ${FILE_SHARE}."
    "$azcopy_bin" remove \
        "https://${STORAGE_ACCOUNT}.file.core.windows.net/${FILE_SHARE}/${directory}?${sas}" \
        --recursive --force-if-read-only >&2
}

reset_instance() {
    local confirmation storage_key directory exists
    set_instance_vars "$1"
    require_command az
    require_command sed
    az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" >/dev/null
    require_stopped_instance reset
    [ -s "$PASSWORD_FILE" ] || die "Password file not found: ${PASSWORD_FILE}"
    load_shared_values
    az storage share-rm show -g "$RESOURCE_GROUP" --storage-account "$STORAGE_ACCOUNT" \
        -n "$FILE_SHARE" >/dev/null 2>&1 || die "Azure Files share not found: ${FILE_SHARE}"

    echo "This permanently deletes all files under:" >&2
    printf '  Share: %s\n  Directories: home, workspace\n' "$FILE_SHARE" >&2
    printf "Run './aca-instance.sh download %s' first if a backup is required.\n" \
        "$INSTANCE_SLUG" >&2
    printf "Type 'reset %s' to continue: " "$INSTANCE_SLUG" >&2
    IFS= read -r confirmation
    [ "$confirmation" = "reset ${INSTANCE_SLUG}" ] || die "Confirmation did not match; nothing was reset."

    storage_key="$(az storage account keys list -g "$RESOURCE_GROUP" \
        --account-name "$STORAGE_ACCOUNT" --query '[0].value' -o tsv)"
    [ -n "$storage_key" ] || die "Could not retrieve a key for storage account ${STORAGE_ACCOUNT}."
    for directory in home workspace; do
        exists="$(AZURE_STORAGE_KEY="$storage_key" az storage directory exists \
            --account-name "$STORAGE_ACCOUNT" --share-name "$FILE_SHARE" \
            --name "$directory" --query exists -o tsv)"
        if [ "$exists" = "true" ]; then
            remove_share_directory "$storage_key" "$directory"
        fi
    done
    for directory in home workspace; do
        AZURE_STORAGE_KEY="$storage_key" az storage directory create \
            --account-name "$STORAGE_ACCOUNT" --share-name "$FILE_SHARE" \
            --name "$directory" -o none
        exists="$(AZURE_STORAGE_KEY="$storage_key" az storage directory exists \
            --account-name "$STORAGE_ACCOUNT" --share-name "$FILE_SHARE" \
            --name "$directory" --query exists -o tsv)"
        [ "$exists" = "true" ] || die "Azure Files directory was not recreated: ${directory}"
    done
    unset storage_key

    run_init_job

    printf 'Reset instance data for %s; defaults are pre-installed and the instance remains stopped.\n' \
        "$INSTANCE_SLUG"
    printf "Run './aca-instance.sh resume %s' to start code-server.\n" "$INSTANCE_SLUG"
}

delete_instance() {
    local confirmation failed=0
    set_instance_vars "$1"
    echo "This permanently deletes:" >&2
    printf '  Container App: %s\n  init Job: %s\n  Environment storage: %s\n  File Share: %s\n  Password: %s\n' \
        "$APP_NAME" "$JOB_NAME" "$ENV_STORAGE_NAME" "$FILE_SHARE" "$PASSWORD_FILE" >&2
    printf "Type '%s' to continue: " "$INSTANCE_SLUG" >&2
    IFS= read -r confirmation
    [ "$confirmation" = "$INSTANCE_SLUG" ] || die "Confirmation did not match; nothing was deleted."

    if az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" >/dev/null 2>&1; then
        az containerapp delete -g "$RESOURCE_GROUP" -n "$APP_NAME" --yes -o none || failed=1
    fi
    if az containerapp job show -g "$RESOURCE_GROUP" -n "$JOB_NAME" >/dev/null 2>&1; then
        az containerapp job delete -g "$RESOURCE_GROUP" -n "$JOB_NAME" --yes -o none || failed=1
    fi
    if az containerapp env storage show -g "$RESOURCE_GROUP" -n "$ENVIRONMENT_NAME" \
        --storage-name "$ENV_STORAGE_NAME" >/dev/null 2>&1; then
        az containerapp env storage remove -g "$RESOURCE_GROUP" -n "$ENVIRONMENT_NAME" \
            --storage-name "$ENV_STORAGE_NAME" --yes -o none || failed=1
    fi
    if az storage share-rm show -g "$RESOURCE_GROUP" --storage-account "$STORAGE_ACCOUNT" \
        -n "$FILE_SHARE" >/dev/null 2>&1; then
        az storage share-rm delete -g "$RESOURCE_GROUP" --storage-account "$STORAGE_ACCOUNT" \
            -n "$FILE_SHARE" --yes -o none || failed=1
    fi
    [ "$failed" -eq 0 ] || die "One or more Azure resources could not be deleted; password retained."
    rm -f "$PASSWORD_FILE"
    if [ "$PASSWORD_FILE" != "${INSTANCE_PASSWORD_DIR}/password" ]; then
        rm -f "${INSTANCE_PASSWORD_DIR}/password"
    fi
    rmdir "$INSTANCE_PASSWORD_DIR" 2>/dev/null || true
    echo "Deleted instance ${INSTANCE_SLUG}."
}

case "$COMMAND" in
    doctor)
        [ "$#" -eq 0 ] || die "doctor takes no instance."
        doctor
        ;;
    create)
        [ "$#" -ge 1 ] || die "create requires an instance slug."
        instance_slug="$1"
        shift
        create_mode="$SCALING_MODE"
        create_min="$SCALING_MIN_REPLICAS"
        create_cooldown="$SCALING_COOLDOWN_PERIOD"
        create_min_was_set=false
        create_cooldown_was_set=false
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --scaling-mode)
                    [ "$#" -ge 2 ] || die "--scaling-mode requires disabled or enabled."
                    create_mode="$2"
                    shift 2
                    ;;
                --min-replicas)
                    [ "$#" -ge 2 ] || die "--min-replicas requires 0 or 1."
                    create_min="$2"
                    create_min_was_set=true
                    shift 2
                    ;;
                --cooldown-period)
                    [ "$#" -ge 2 ] || die "--cooldown-period requires seconds."
                    create_cooldown="$2"
                    create_cooldown_was_set=true
                    shift 2
                    ;;
                *) die "Unknown create option: $1" ;;
            esac
        done
        validate_scaling_values "$create_mode" "$create_min" "$create_cooldown"
        if [ "$create_mode" = disabled ] &&
            { [ "$create_min_was_set" = true ] || [ "$create_cooldown_was_set" = true ]; }; then
            die "--min-replicas and --cooldown-period require --scaling-mode enabled."
        fi
        create_instance "$instance_slug" "$create_mode" "$create_min" "$create_cooldown"
        ;;
    update)
        [ "$#" -eq 1 ] || die "update requires exactly one instance slug."
        update_instance "$1"
        ;;
    suspend)
        [ "$#" -eq 1 ] || die "suspend requires exactly one instance slug."
        suspend_instance "$1"
        ;;
    resume)
        [ "$#" -eq 1 ] || die "resume requires exactly one instance slug."
        resume_instance "$1"
        ;;
    list)
        [ "$#" -eq 0 ] || die "list takes no instance."
        list_instances
        ;;
    show)
        [ "$#" -eq 1 ] || die "show requires exactly one instance slug."
        set_instance_vars "$1"
        show_pair
        ;;
    rotate-password)
        [ "$#" -eq 1 ] || die "rotate-password requires exactly one instance slug."
        rotate_password "$1"
        ;;
    download)
        [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "download requires an instance slug and optional output path."
        download_instance "$@"
        ;;
    reset)
        [ "$#" -eq 1 ] || die "reset requires exactly one instance slug."
        reset_instance "$1"
        ;;
    delete)
        [ "$#" -eq 1 ] || die "delete requires exactly one instance slug."
        delete_instance "$1"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        die "Unknown command: ${COMMAND}"
        ;;
esac
