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
export HOME=/data
# Supervisor mounts persistent /data as root-owned, overriding Dockerfile ownership.
# Bootstrap only this app-owned directory, then drop ALL service privileges.
if [ "$(id -u)" -eq 0 ]; then
    if [ -L /data ] || [ -L /data/velbus ]; then
        echo "Refusing startup: unsafe data mount" >&2
        exit 1
    fi
    mkdir -p /data/velbus
    chown app:app /data
    chown -R app:app /data/velbus
    chmod 0700 /data/velbus
    # Make ASP.NET data-protection keys persistent across Supervisor app updates.
    # These keys are app-private; they must never be written into the image.
    if [ -L /data/.aspnet ] || [ -L /data/.aspnet/DataProtection-Keys ]; then
        echo "Refusing unexpected ASP.NET key directory symlink" >&2
        exit 1
    fi
    mkdir -p /data/.aspnet/DataProtection-Keys
    chown -R app:app /data/.aspnet
    chmod 0700 /data/.aspnet /data/.aspnet/DataProtection-Keys
    if [ -e /data/options.json ]; then
        if [ -L /data/options.json ] || [ ! -f /data/options.json ]; then
            echo "Refusing unexpected /data/options.json type" >&2
            exit 1
        fi
        chown app:app /data/options.json
        chmod 0640 /data/options.json
    fi
    if ! command -v gosu >/dev/null 2>&1; then
        echo "Missing privilege-drop helper" >&2
        exit 1
    fi
    # Run the health checks, service processes and signal cleanup as one UID.
    # Otherwise a cap-restricted root shell cannot send kill -0 to app processes.
    exec gosu app "$0" "$@"
fi
if [ "$(id -u)" -ne "$(id -u app)" ] || [ ! -w /data/velbus ]; then
    echo "Refusing startup: runtime must run as app with writable data" >&2
    exit 1
fi
manager_pid="" nginx_pid="" error_log_pid="" access_log_pid=""
cleanup() {
    trap - EXIT INT TERM
    [ -z "$nginx_pid" ] || kill "$nginx_pid" 2>/dev/null || true
    [ -z "$manager_pid" ] || kill "$manager_pid" 2>/dev/null || true
    [ -z "$error_log_pid" ] || kill "$error_log_pid" 2>/dev/null || true
    [ -z "$access_log_pid" ] || kill "$access_log_pid" 2>/dev/null || true
    [ -z "$nginx_pid" ] || wait "$nginx_pid" 2>/dev/null || true
    [ -z "$manager_pid" ] || wait "$manager_pid" 2>/dev/null || true
    [ -z "$error_log_pid" ] || wait "$error_log_pid" 2>/dev/null || true
    [ -z "$access_log_pid" ] || wait "$access_log_pid" 2>/dev/null || true
}
# Supervisor sends SIGTERM for a normal stop, upgrade or restart.
# Handle it explicitly, wait for children, and exit 0 instead of 128+SIGTERM.
shutdown_gracefully() {
    trap - INT TERM
    echo "Stopping Velbus Manager after Supervisor SIGTERM"
    cleanup
    exit 0
}
trap cleanup EXIT
trap shutdown_gracefully INT TERM
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
    if curl -fsS --max-time 2 -o /dev/null http://127.0.0.1:4201/velbus-ui/index.html 2>/dev/null; then
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
# /dev/stderr and /dev/stdout cannot be reopened by a different UID on a
# restrictive Docker pipe. Write as app to protected temporary files and forward
# logs over the already-inherited stdout/stderr file descriptors.
touch /tmp/velbus-nginx-error.log /tmp/velbus-nginx-access.log
chmod 0600 /tmp/velbus-nginx-error.log /tmp/velbus-nginx-access.log
tail -n +1 -F /tmp/velbus-nginx-error.log >&2 &
error_log_pid=$!
tail -n +1 -F /tmp/velbus-nginx-access.log &
access_log_pid=$!
nginx -t -c /app/ha-app/nginx.conf
nginx -c /app/ha-app/nginx.conf -g 'daemon off;' &
nginx_pid=$!
while kill -0 "$manager_pid" 2>/dev/null && kill -0 "$nginx_pid" 2>/dev/null; do sleep 2; done
echo "Manager or nginx exited" >&2
exit 1
