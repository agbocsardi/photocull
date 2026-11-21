# PhotoCull on a home server

`photocull-serve` (contract: [REMOTE-CULL.md §6](REMOTE-CULL.md#6-home-server-photocull-serve))
in Docker behind `tailscale serve`. The server binds `127.0.0.1` only and the
container uses the host network, so the API is on the host's loopback where
Tailscale picks it up — never on the LAN, never on `0.0.0.0`.

Files: `deploy/Dockerfile` (multi-stage — `swift:6.2-noble` builds a statically
linked release binary, `ubuntu:noble` runs it as a non-root user) and
`deploy/compose.yaml`. Build context is the repository root; `.dockerignore`
keeps the checkout out of it.

## 1. Build the image

```bash
docker build -f deploy/Dockerfile -t photocull-serve:dev .
```

Dependencies come from `Package.resolved` only; a toolchain that would
re-resolve them fails the build instead of shipping other versions.

## 2. Settings

Set these once in the shell; the steps below use them:

```bash
export PHOTOCULL_DATA=/srv/photocull
export PHOTOCULL_TOKEN="$HOME/.config/photocull-serve/token"
export PHOTOCULL_UID=$(id -u) PHOTOCULL_GID=$(id -g)   # defaults: 1000:1000
export PORT=8723                                       # default
```

## 3. Data root

A folder of its own, **not** inside another app's data (e.g. Immich's upload
library — its stack must never see foreign folders). For example `/srv/photocull`:

```bash
mkdir -p "$PHOTOCULL_DATA/inbox"
touch "$PHOTOCULL_DATA/.photocull-serve-root"            # the marker that opts a folder in
chown -R "$PHOTOCULL_UID:$PHOTOCULL_GID" "$PHOTOCULL_DATA"
```

The server never creates the root, the marker or the inbox. Session folders are
`inbox/<YYYY-MM-DD>/`, holding photos plus the `.photocull.json` sidecar;
`archive/` and `dump/` appear under the root when Finalize runs (a later phase).

## 4. Token file

```bash
mkdir -p "$(dirname "$PHOTOCULL_TOKEN")"
(umask 077; openssl rand -base64 32 | tr '+/' '-_' | tr -d '=' > "$PHOTOCULL_TOKEN")
chmod 600 "$PHOTOCULL_TOKEN"
chown "$PHOTOCULL_UID:$PHOTOCULL_GID" "$PHOTOCULL_TOKEN"
```

`photocull-serve` reads a regular file (no symlink), refuses one that group or
others can access, and needs at least 32 characters. The file is bind-mounted
read-only, so the host's owner and mode are exactly what the server checks: mode
`600` and owned by the container's user.

## 5. Start

Check §6 first: on a box where a `tailscale serve` handler already points at
`127.0.0.1:$PORT`, the server is reachable on the tailnet the moment it starts.

```bash
docker compose -f deploy/compose.yaml up -d
docker compose -f deploy/compose.yaml logs -f
```

Compose refuses to start when `PHOTOCULL_DATA` or `PHOTOCULL_TOKEN` is unset
instead of guessing a path. The service runs as `PHOTOCULL_UID:GID` — the owner
of the data root and the token file — with a read-only root filesystem, `init`,
`restart: unless-stopped`, and only the data root writable. Startup logs the
mode (`REAL`), the data root, `127.0.0.1:<port>` and the PWA folder.

Sanity check from the server itself:

```bash
curl -s -H "Authorization: Bearer $(cat "$PHOTOCULL_TOKEN")" "http://127.0.0.1:$PORT/api/health"
```

## 6. HTTPS on the tailnet

The contract reserves tailnet port 8443. Never replace another app's handler —
read the current ones first:

```bash
tailscale serve status
```

- If a handler already proxies `http://127.0.0.1:$PORT`, either reuse it
  deliberately (skip the next command and pair on its port) or pick another `PORT`.
- If 8443 already carries something else, use the next free tailnet port
  (`--https=8444`, …) and that number in the pairing URL.

```bash
tailscale serve --bg --https=8443 "http://127.0.0.1:$PORT"
```

Pair once on the phone, with the MagicDNS name `tailscale status` reports:

```
https://<magicdns>:8443/#token=<token>
```

The PWA stores the token and removes the fragment from the address bar.

## 7. Stop, update, and what does not work yet

```bash
docker compose -f deploy/compose.yaml down        # stop and remove the container
git pull && docker compose -f deploy/compose.yaml build \
  && docker compose -f deploy/compose.yaml up -d  # update
```

A startup refusal (missing marker, bad token file) is permanent, so with
`restart: unless-stopped` the container restarts in a loop; `logs` shows why.

Until Mac → server sync lands the server has no previews: there is no image
decoding on Linux, so preview requests answer 404 ("this host cannot generate
one") and the PWA shows placeholders. Photos have to be placed in
`inbox/<YYYY-MM-DD>/` by hand, JPG and RAW sharing the stem (e.g.
`IMG1.JPG` + `IMG1.RAF`). Culling (keep/reject/rotation) works and writes the
session sidecar.
