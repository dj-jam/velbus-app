#!/bin/sh
# Fail closed: disable API auth only AFTER forcing a loopback-only API listener.
set -eu
umask 077
if [ -n "${CONFIG_FILE:-}" ]; then
    echo "Refusing CONFIG_FILE: can override enforced security settings" >&2
    exit 1
fi
export ASPNETCORE_ENVIRONMENT=Production
export MANAGER_USERDATA=/data SNAP_DATA=/data MANAGER_SERIAL_OPTIONS_FILE=/data/options.json
mkdir -p /data
manager_pid="" nginx_pid=""
cleanup() {
    trap - EXIT INT TERM
    [ -z "$nginx_pid" ] || kill "$nginx_pid" 2>/dev/null || true
    [ -z "$manager_pid" ] || kill "$manager_pid" 2>/dev/null || true
    [ -z "$nginx_pid" ] || wait "$nginx_pid" 2>/dev/null || true
    [ -z "$manager_pid" ] || wait "$manager_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' INT TERM
dotnet /app/Velbus.Signum.Release.dll \
    '--Kestrel:Endpoints:HaLoopback:Url=http://127.0.0.1:4201' \
    '--DefaultGateway:CreateLocal=false' \
    '--Authentication:Enabled=false' &
manager_pid=$!
ready=0 i=0
while [ "$i" -lt 60 ]; do
    if ! kill -0 "$manager_pid" 2>/dev/null; then
        echo "Manager exited during startup" >&2; exit 1
    fi
    if curl -fsS --max-time 2 -o /dev/null http://127.0.0.1:4201/velbus-ui/index.html; then
        ready=1; break
    fi
    i=$((i + 1)); sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "Manager startup timed out" >&2; exit 1
fi
listeners=$(ss -H -ltn | awk '$4 ~ /:4201$/ { print $4 }')
if [ "$listeners" != "127.0.0.1:4201" ]; then
    echo "Refusing ingress: Manager listener not loopback-only: $listeners" >&2; exit 1
fi
nginx -t -c /app/ha-app/nginx.conf
nginx -c /app/ha-app/nginx.conf -g 'daemon off;' &
nginx_pid=$!
while kill -0 "$manager_pid" 2>/dev/null && kill -0 "$nginx_pid" 2>/dev/null; do sleep 2; done
echo "Manager or nginx exited" >&2
exit 1
