# Velbus Manager 2.0 Beta

## Getting started

Use **Settings → Apps → Velbus Manager 2.0 Beta → Start → Open web interface**.
Use **Busverbindingen** to configure TCP/IP, a local Signum, simulator, or USB.

## USB

In the App's **Configuration** tab, choose the required serial devices under
`serial_devices`. The Supervisor passes only those devices to the app. Restart
the app after selecting a new adapter, then choose the adapter in the Manager.
Use stable `/dev/serial/by-id/...` entries when available.

## Network and security

The container entrypoint runs a narrowly scoped root bootstrap to make the
Supervisor-owned `/data/velbus` directory writable. It then re-executes the
whole start script as the unprivileged `app` user, including its process health
checks, Manager service and nginx. Updates retain existing `/data`.

The Manager backend listens on `127.0.0.1:4201` only. An nginx proxy on port
8099 accepts Supervisor Ingress requests only and does not publish a host port.
Home Assistant handles user login; this panel is available only to HA admins.
The internal Manager authentication is disabled **only** behind this strictly
private loopback listener. Do not expose the container port or use this build
outside Home Assistant Supervisor Ingress.

The Home Assistant Velbus integration (`velbus-aio`) is a separate component.
This beta does not make `manager://` available directly to Home Assistant Core.

## Data and updates

Settings are saved under `/data`. Back up the app before updating; cold backup
and restore, Ingress/API/WebSocket access and physical serial devices require
acceptance tests on your test Home Assistant OS instance.

## Scope

Only compiled runtime files are included in the public image. The source code
for Velbus Manager remains private. This is a beta, not production software.
