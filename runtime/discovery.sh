#!/bin/sh
# Discovery/auth contract for the isolated Home Assistant Supervisor app.
# Sourced by launch.sh AFTER its privileged data-directory bootstrap has
# re-executed the process as the unprivileged app user.
# No Manager source files, bus scan endpoints or UI pages are modified.

discovery_token_file=/data/manager-discovery-token
manager_id_file=/data/manager-discovery-id
discovery_message_file=/data/manager-supervisor-discovery-uuid
nginx_config=/tmp/velbus-manager-nginx.conf

valid_manager_id() {
    printf '%s' "$1" | LC_ALL=C grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

valid_discovery_uuid() {
    printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9-]{8,128}$'
}

setup_discovery_identity() {
    # Do not follow symlinks or overwrite existing credentials/identity.
    for file in "$discovery_token_file" "$manager_id_file" "$discovery_message_file"; do
        if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
            echo 'Refusing unexpected discovery file type' >&2
            return 1
        fi
    done
    if [ ! -e "$discovery_token_file" ]; then
        temp=$(mktemp "${discovery_token_file}.XXXXXX")
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$temp"
        chmod 600 "$temp"
        mv -n "$temp" "$discovery_token_file"
        rm -f "$temp"
    fi
    if [ ! -e "$manager_id_file" ]; then
        temp=$(mktemp "${manager_id_file}.XXXXXX")
        cat /proc/sys/kernel/random/uuid > "$temp"
        chmod 600 "$temp"
        mv -n "$temp" "$manager_id_file"
        rm -f "$temp"
    fi
    chmod 600 "$discovery_token_file" "$manager_id_file"
    [ ! -e "$discovery_message_file" ] || chmod 600 "$discovery_message_file"
    manager_api_token=$(tr -d '\r\n' < "$discovery_token_file")
    manager_id=$(tr -d '\r\n' < "$manager_id_file")
    if ! printf '%s' "$manager_api_token" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'; then
        echo 'Invalid persisted Manager API token (refusing insecure startup)' >&2
        return 1
    fi
    if ! valid_manager_id "$manager_id"; then
        echo 'Invalid persisted Manager discovery ID' >&2
        return 1
    fi
}

render_discovery_nginx_config() {
    # The token is valid lowercase hex, so literal replacement cannot
    # introduce nginx directives or escape sed. Keep config private.
    [ ! -L "$nginx_config" ] || return 1
    temp=$(mktemp "${nginx_config}.XXXXXX")
    sed "s/__VELBUS_API_BEARER__/$manager_api_token/g" /app/ha-app/nginx.conf > "$temp"
    chmod 600 "$temp"
    mv -f "$temp" "$nginx_config"
}

check_discovery_api_ready() {
    # Ingress on 8099 is still protected by Supervisor. The only additional
    # entry point (8098) is on the internal Docker network and MUST demand a
    # token for both REST and WebSocket handshakes.
    i=0
    while [ "$i" -lt 15 ]; do
        if ! kill -0 "$nginx_pid" 2>/dev/null; then
            echo 'Manager API proxy stopped before readiness' >&2
            return 1
        fi
        status=$(curl --silent --max-time 2 -o /dev/null -w '%{http_code}' \
            http://127.0.0.1:8098/velbus/api/v2/gateways || true)
        if [ "$status" = 401 ]; then
            status=$(curl --silent --max-time 2 -o /dev/null -w '%{http_code}' \
                -H "Authorization: Bearer $manager_api_token" \
                http://127.0.0.1:8098/velbus/api/v2/gateways || true)
            if [ "$status" = 200 ]; then
                echo 'Manager internal API authenticated and ready'
                return 0
            fi
        fi
        i=$((i+1))
        sleep 1
    done
    echo 'Manager internal API failed authentication readiness; refusing startup' >&2
    return 1
}

unregister_supervisor_discovery() {
    [ -r "$discovery_message_file" ] || return 0
    [ -n "${SUPERVISOR_TOKEN:-}" ] || return 1
    message_uuid=$(tr -d '\r\n' < "$discovery_message_file")
    if ! valid_discovery_uuid "$message_uuid"; then
        echo 'Invalid stored Supervisor discovery message ID; refusing deletion' >&2
        return 1
    fi
    code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 3 \
        -X DELETE -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
        "http://supervisor/discovery/$message_uuid" 2>/dev/null || true)
    case "$code" in
        200|204|404)
            rm -f "$discovery_message_file"
            echo 'Supervisor discovery registration cleaned up'
            return 0
            ;;
    esac
    echo 'Supervisor discovery deregistration deferred until next start' >&2
    return 1
}

register_supervisor_discovery() {
    # CI/standalone Docker runs without Supervisor token: still enforce API
    # authentication, but do not register externally.
    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        echo 'Supervisor discovery not registered (no Supervisor environment)'
        return 0
    fi
    if [ -r "$discovery_message_file" ]; then
        if ! unregister_supervisor_discovery; then
            echo 'Supervisor discovery skipped to avoid duplicate registration' >&2
            return 0
        fi
    fi
    app_host=$(hostname)
    case "$app_host" in
        *[!A-Za-z0-9-]*|'')
            echo 'Supervisor discovery skipped: unexpected container hostname' >&2
            return 0
            ;;
    esac
    payload=$(jq -cn --arg host "$app_host" --arg id "$manager_id" \
        --arg token "$manager_api_token" \
        '{service:"velbus",config:{host:$host,port:8098,manager_id:$id,api_version:"v2",access_token:$token}}')
    response=$(printf '%s' "$payload" | curl --silent --show-error --fail \
        --connect-timeout 2 --max-time 9 -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
        -H 'Content-Type: application/json' --data-binary @- \
        http://supervisor/discovery 2>/dev/null) || {
        echo 'Supervisor discovery registration failed; Manager remains available' >&2
        return 0
    }
    message_uuid=$(printf '%s' "$response" | jq -r '.data.uuid // .uuid // empty' 2>/dev/null || true)
    if ! valid_discovery_uuid "$message_uuid"; then
        echo 'Supervisor discovery returned no valid message ID' >&2
        return 0
    fi
    temp=$(mktemp "${discovery_message_file}.XXXXXX")
    printf '%s\n' "$message_uuid" > "$temp"
    chmod 600 "$temp"
    mv -f "$temp" "$discovery_message_file"
    echo 'Supervisor Velbus discovery registered (token kept private)'
}
