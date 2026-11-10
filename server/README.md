# Docker collaboration server

## Start

On the Docker host, copy this repository and enter its `server` directory. Generate a secret:

```sh
python3 -c 'import secrets; print("CANVAS_TOKEN=" + secrets.token_urlsafe(32))' > .env
chmod 600 .env
docker compose up -d --build
```

`.env` is ignored by Git and excluded from the Docker build. Share the token only with intended participants. This initial service uses one shared deployment access token; everyone with it may create/join a named room. Room names are identifiers, not private authorization boundaries. Different groups needing isolation should use separate deployments/tokens until per-room invitations are added.

SQLite data is stored in the `canvas-data` named volume. Back up the database using SQLite's backup API or stop the service before copying its database files. Keep the volume when recreating containers.

## Cloudflare

Create a Cloudflare Tunnel with a published hostname, for example `canvas.your-domain.com`, routed to `http://localhost:8765` when `cloudflared` runs on the Docker host. WebSocket upgrades use that route. The default Compose file exposes the service only on the host loopback interface. If `cloudflared` runs in another container, attach it to the same Compose network and route to `http://canvas:8765` instead.

Use the Cloudflare-generated tunnel install command on your server. Keep its tunnel token on the server; it is separate from `CANVAS_TOKEN` and must never go in the iPad app.

Cloudflare references:
- [Publish a local service through a tunnel](https://developers.cloudflare.com/tunnel/get-started/)
- [WebSocket support and connection lifecycle](https://developers.cloudflare.com/network/websockets/)

## Connect the iPads

1. Tap the people button in the app.
2. Enter `wss://canvas.your-domain.com`, a room name (letters, digits, hyphens or underscores; 1–64 characters), the `CANVAS_TOKEN` value and your name.
3. Use the same endpoint, room and access token on every iPad.
4. The first participant becomes the room host and can resize. Every installation receives its own layer and may add more. Ownership is checked on every edit.

For a LAN-only development test, explicitly publish a LAN-facing port and use a trusted local TLS proxy. The default loopback binding is intended for Cloudflare Tunnel. Avoid sending the room token over unencrypted public `ws://` connections.

The participant secret is generated once per app installation and hashed to derive its author ID; reconnecting keeps layer ownership. Clearing/reinstalling app data creates a new identity. This prototype has no host-transfer or account-recovery UI. The room access token stays in memory in the app and must be entered again after relaunch.

## Protocol and recovery

Clients first send `join` with a room, access token, participant key, display name and pending operation IDs. The server replies with a snapshot and the subset of pending IDs already committed. Subsequent messages contain `operation` or ephemeral `presence` data. The server validates authorship, assigns a room revision, commits the document and deduplication record atomically, then broadcasts the accepted operation. Client receive queues are bounded; lagging clients reconnect to a fresh snapshot.

The app persists unacknowledged operations and replays them after reconnect. Estimated Pencil corrections replace samples by ID. Restart recovery finalizes the reconnecting author's interrupted strokes after queued edits, making them undoable. Undo/redo synchronize stroke visibility. Resize is a host-only shared operation; zoom/pan are never transmitted.

The Python server uses the [websockets asyncio server API](https://websockets.readthedocs.io/en/stable/reference/asyncio/server.html). The single-process SQLite implementation is an initial self-hosted service, with explicit document/connection limits documented in the repository README.
