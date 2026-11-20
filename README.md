# Velbus APP

Official-format Home Assistant App repository for **Velbus Manager 2.0 Beta**.

This public repository contains the Home Assistant installation manifest, the
runtime packaging recipe and release automation. **The Manager source code is
kept in a separate private repository.** Releases contain only compiled runtime
artifacts. This is experimental software, not suitable for production systems.

## Add to Home Assistant

When a tested beta image has been published publicly, open **Settings → Apps →
Install app → ⋮ → Repositories**, add:

`https://github.com/dj-jam/velbus-app`

Then install **Velbus Manager 2.0 Beta** and open it using Home Assistant Ingress.
The app does not open a host port or provide Home Assistant Core's Velbus
integration automatically. Physical bus access is optional and must be assigned
in the app's Configuration tab.

## Controlled releases

1. Build and validate the Manager runtime in the **private** development tree.
2. Publish the compiled runtime archives as assets of a `vX.Y.Z-beta.N`
   release in this repository (no source files).
3. The `Publish beta image` workflow publishes tagged AMD64 and ARM64 images
   to `ghcr.io/dj-jam/velbus-manager2-ha`, then assembles a multiarch image.
4. After the image is *public* and anonymously pullable, run the
   `Promote tested image to App Store` workflow with the approved version.
   This updates only the app's `config.yaml` and changelog, causing Home
   Assistant to offer an update when its app repository refreshes.

**Never expose a new app version before its image exists and can be pulled
without credentials.** A release does not deploy to any user or change any
running Manager. The app uses an admin-only, Ingress-only UI and saves its
configuration under `/data`.

## Testing and limitations

Initial HA OS ingress, persistent storage, serial hardware passthrough, backup,
upgrade and rollback must be verified on an isolated Home Assistant test system.
The Manager API intentionally remains inaccessible to Home Assistant Core from
outside the app container until separate authentication is developed.

## Supervisor discovery (experimental)

App builds with `discovery: [velbus]` register the Manager address and a
persistent, per-installation API token through the Supervisor discovery API.
The network API is **only** available on Docker-internal port 8098 and is
protected with a bearer token, including the WebSocket handshake. Ingress
remains admin-only; port 4201 is never published. Official Home Assistant Core
support for the discovery message must be implemented upstream separately.
