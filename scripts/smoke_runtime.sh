#!/usr/bin/env bash
# Validate real app startup with a Supervisor-style root-owned /data bind mount.
set -euo pipefail
: "${IMAGE:?Set IMAGE to the freshly built image tag}"
container="velbus-app-ci-smoke-$$"
data="$(mktemp -d)"
cleanup() {
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
# App must be able to write its persistent data with its unprivileged UID.
docker exec -u app "$container" sh -ceu '
    test -w /data/velbus
    test -r /data/options.json
    echo verified > /data/velbus/.ci-persistence-test
    test "$(cat /data/velbus/.ci-persistence-test)" = verified
'
# No external backend listener and no unrestricted nginx access.
docker exec "$container" sh -ceu '
    test "$(ss -H -ltn | awk '\''$4 ~ /:4201$/ { print $4 }'\'')" = "127.0.0.1:4201"
    code=$(curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:8099/velbus-ui/index.html)
    test "$code" = 403
'
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
echo "PASS root-owned Supervisor /data repaired; Manager + nginx are unprivileged; loopback and Ingress access limited"
