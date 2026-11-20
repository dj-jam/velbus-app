#!/usr/bin/env bash
# Validate real app startup with a Supervisor-style root-owned /data bind mount.
set -euo pipefail
: "${IMAGE:?Set IMAGE to the freshly built image tag}"
container="velbus-app-ci-smoke-$$"
data="$(mktemp -d)"
cleanup() {
    result=$?
    if [ "$result" -ne 0 ]; then
        echo "Smoke failed with exit $result — capturing diagnostic logs" >&2
        docker logs "$container" 2>&1 | tail -55 >&2 || true
        docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' "$container" >&2 || true
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    sudo rm -rf -- "$data"
}
trap cleanup EXIT

chmod 0755 "$data"
printf '{"serial_devices":[]}\n' > "$data/options.json"
chmod 0600 "$data/options.json"
docker run -d --name "$container" --network bridge \
    --cap-drop=ALL --cap-add=CHOWN --cap-add=DAC_OVERRIDE \
    --cap-add=FOWNER --cap-add=SETUID --cap-add=SETGID \
    --security-opt=no-new-privileges \
    --read-only --tmpfs /tmp:rw,nosuid,nodev,size=32m \
    --mount "type=bind,source=$data,target=/data" \
    "$IMAGE" >/dev/null
ready=no
for attempt in $(seq 1 65); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != true ]; then
        docker logs "$container" >&2
        echo 'App exited before readiness' >&2
        exit 1
    fi
    if docker exec "$container" curl -fsS --max-time 2 \
        http://127.0.0.1:4201/velbus-ui/index.html -o /dev/null 2>/dev/null; then
        ready=yes
        break
    fi
    sleep 1
done
if [ "$ready" != yes ]; then
    docker logs "$container" >&2
    echo 'App did not respond before startup timeout' >&2
    exit 1
fi
echo "Manager backend is serving API on loopback; checking unprivileged data access"
# App must be able to write its persistent data with its unprivileged UID.
docker exec -u app "$container" sh -ceu '
    test -w /data/velbus
    test -w /data/.aspnet/DataProtection-Keys
    test -r /data/options.json
    echo verified > /data/velbus/.ci-persistence-test
    test "$(cat /data/velbus/.ci-persistence-test)" = verified
'
# Exercise exact API endpoints that previously returned 404 under HA Ingress.
echo "Checking backend API endpoints without physical bus writes"
for path in     /velbus/api/v2/gateways     '/velbus/api/v2/actors?includeProperties=true'     /velbus/api/v2/workspace/connections     /velbus/config/velbus; do
    code=$(docker exec "$container" curl --path-as-is -sS --max-time 8       -o /dev/null -w "%{http_code}" "http://127.0.0.1:4201$path")
    # A configuration query without a selected/connected bus can return 400.
    # The endpoint must exist, however (never 404), and other endpoints must
    # return successful JSON even when no gateways are configured.
    if [ "$code" != 200 ] && ! { [ "$path" = /velbus/config/velbus ] && [ "$code" = 400 ]; }; then
        echo "Manager API failed: $path returned HTTP $code" >&2
        exit 1
    fi
done
# A normal WebSocket upgrade must reach the real Manager endpoint.
ws_code=$(docker exec "$container" curl -sS --max-time 3 -o /dev/null     -w "%{http_code}" -H 'Upgrade: websocket' -H 'Connection: Upgrade'     -H 'Sec-WebSocket-Version: 13'     -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='     'http://127.0.0.1:4201/velbus/api/v2/ws' 2>/dev/null || true)
if [ "$ws_code" != 101 ]; then
    echo "Manager WebSocket upgrade failed: HTTP $ws_code" >&2
    exit 1
fi
echo "Checking internal API isolation, bearer token and WebSocket"
docker exec "$container" sh -ceu '
    token=$(cat /data/manager-discovery-token)
    id=$(cat /data/manager-discovery-id)
    printf "%s" "$token" | LC_ALL=C grep -Eq "^[0-9a-f]{64}$"
    printf "%s" "$id" | LC_ALL=C grep -Eq "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    test "$(stat -c %a /data/manager-discovery-token)" = 600
    test "$(stat -c %a /data/manager-discovery-id)" = 600
    test "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8098/velbus/api/v2/gateways)" = 401
    test "$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer invalid" http://127.0.0.1:8098/velbus/api/v2/gateways)" = 401
    test "$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $token" http://127.0.0.1:8098/velbus/api/v2/gateways)" = 200
    test "$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $token" http://127.0.0.1:8098/velbus-ui/index.html)" = 404
    test "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8098/velbus/api/v2/ws)" = 401
    upgrade() {
        curl --silent --max-time 2 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $token" -H "Upgrade: websocket" -H "Connection: Upgrade" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" http://127.0.0.1:8098/velbus/api/v2/ws || true
    }
    status=$(upgrade)
    [ "$status" = 101 ] || { echo "Internal WebSocket upgrade expected 101, got HTTP $status" >&2; exit 1; }
    test -z "$(cat /data/manager-supervisor-discovery-uuid 2>/dev/null || true)"
'
# Verify ports are not mapped onto the HAOS host, regardless of EXPOSE metadata.
if [ -n "$(docker port "$container" 8098/tcp 2>/dev/null)" ]; then
    echo 'Internal API was unexpectedly published as a host port' >&2
    exit 1
fi
echo "App data is writable; waiting for admin-only Ingress proxy to start"
# No external backend listener and no unrestricted nginx access.
nginx_ready=no
for attempt in $(seq 1 20); do
    code="$(docker exec "$container" curl -s -o /dev/null -w '%{http_code}' \
      http://127.0.0.1:8099/velbus-ui/index.html 2>/dev/null || true)"
    if [ "$code" = 403 ]; then nginx_ready=yes; break; fi
    sleep 1
done
if [ "$nginx_ready" != yes ]; then
    echo "Ingress proxy did not deny unauthenticated loopback: $code" >&2
    exit 1
fi
docker exec "$container" sh -ceu '
    test "$(ss -H -ltn | awk '\''$4 ~ /:4201$/ { print $4 }'\'')" = "127.0.0.1:4201"
    code=$(curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:8099/velbus-ui/index.html)
    test "$code" = 403
'
echo "Ingress denied unauthorized access; inspecting process identities"
docker exec "$container" sh -ceu '
    appuid="$(id -u app)"
    found_dotnet=no
    found_nginx=no
    for proc in /proc/[0-9]*/comm; do
        comm="$(cat "$proc" 2>/dev/null || true)"
        case "$comm" in
            dotnet) found_dotnet=yes ;;
            nginx) found_nginx=yes ;;
            *) continue ;;
        esac
        pid="$(basename "$(dirname "$proc")")"
        uid="$(awk '\''$1=="Uid:" {print $2}'\'' "/proc/$pid/status")"
        [ "$uid" = "$appuid" ] || exit 1
    done
    [ "$found_dotnet" = yes ] && [ "$found_nginx" = yes ]
'
# Keep private IDs across a full container restart; never display the token.
first_token_sha=$(docker exec "$container" sha256sum /data/manager-discovery-token | cut -d ' ' -f 1)
first_manager_id=$(docker exec "$container" cat /data/manager-discovery-id)
echo "Testing graceful Supervisor SIGTERM with Docker stop"
docker stop --time 20 "$container" >/dev/null
stopped_code=$(docker inspect -f '{{.State.ExitCode}}' "$container")
if [ "$stopped_code" != 0 ]; then
    echo "SIGTERM shutdown failed: Docker exit code $stopped_code (expected 0)" >&2
    exit 1
fi
if ! docker logs "$container" 2>&1 | grep -q 'Stopping Velbus Manager after Supervisor SIGTERM'; then
    echo "SIGTERM was not handled by the app entrypoint" >&2
    exit 1
fi
echo "Checking restart and persisted app data after clean stop"
docker start "$container" >/dev/null
restarted=no
for attempt in $(seq 1 65); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != true ]; then
        echo 'App exited unexpectedly after restart' >&2
        exit 1
    fi
    if docker exec "$container" curl -fsS --max-time 2 \
        http://127.0.0.1:4201/velbus-ui/index.html -o /dev/null 2>/dev/null; then
        restarted=yes
        break
    fi
    sleep 1
done
if [ "$restarted" != yes ]; then
    echo 'App did not become ready after restart' >&2
    exit 1
fi
test "$first_token_sha" = "$(docker exec "$container" sha256sum /data/manager-discovery-token | cut -d ' ' -f 1)"
test "$first_manager_id" = "$(docker exec "$container" cat /data/manager-discovery-id)"
docker exec -u app "$container" sh -ceu '
    test "$(cat /data/velbus/.ci-persistence-test)" = verified
    printf "%s" "$(cat /data/manager-discovery-token)" | LC_ALL=C grep -Eq "^[0-9a-f]{64}$"
    printf "%s" "$(cat /data/manager-discovery-id)" | LC_ALL=C grep -Eq "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    test -w /data/velbus
'
docker stop --time 20 "$container" >/dev/null
final_code=$(docker inspect -f '{{.State.ExitCode}}' "$container")
if [ "$final_code" != 0 ]; then
    echo "Second clean shutdown failed with exit code $final_code" >&2
    exit 1
fi
echo "PASS Supervisor-style SIGTERM and restart: exit 0 twice, persistent settings retained, Manager + nginx unprivileged"
