# Stacks headless server on Linux

`bookmanager` is the headless server for Stacks libraries: it serves one
library over HTTP (sync protocol + OPDS) and is the single writer for it.
Clients — the macOS Stacks app or other `bookmanager`/`RemoteLibrary`
instances — push commands and pull records; the server serializes them and
never merges.

Same Swift codebase as the app. The root `Package.swift` builds only the
server-facing subset (Journal, Library, Persistence, Server), so a plain
`swift build` works on macOS, Linux arm64 (Raspberry Pi 4/5, 64-bit OS), and
Linux x86_64.

## Prerequisites

- **Swift 6.x toolchain** from [swift.org](https://www.swift.org/install/linux/)
  (the same toolchain used to build the app; `swift-tools-version: 6.0`
  requires Swift 6.0 or newer). Verify: `swift --version`.
- No other system packages: GRDB bundles SQLite, swift-crypto vendors
  BoringSSL, Hummingbird/NIO and swift-argument-parser are pure Swift.
- Raspberry Pi: arm64 only — use the 64-bit Raspberry Pi OS image (Pi 3's
  32-bit armv7 is not supported).

## Build

```bash
git clone <repository-url> "Book manager"
cd "Book manager"          # the path contains a space — quote it
swift build -c release
```

The first build resolves and fetches dependencies (needs network). The
executable lands at `.build/release/bookmanager`.

## Create a library

```bash
./.build/release/bookmanager create /srv/stacks/library
```

Prints the library ID (used by clients and the Bonjour TXT record) and the
format version.

## Run

```bash
./.build/release/bookmanager serve /srv/stacks/library
```

Options (see `bookmanager serve --help`):

| Flag | Default | Meaning |
|---|---|---|
| `--port <port>` | `8080` | Listen port |
| `--user <user>` | — | Require this username (with `--password`) |
| `--password <pass>` | — | Password for `--user` |
| `--name <name>` | folder name | Display name (Bonjour/diagnostics) |
| `--indexes <dir>` | see below | Catalog indexes directory |
| `--no-bonjour` | off | Do not advertise (see Bonjour note) |

Notes:

- **Indexes**: defaults to `~/Library/Application Support/StacksServer`
  when that resolves; otherwise (typical on Linux) a sibling
  `.stacks-server-indexes/` next to the library. Never point two writers at
  the same index directory.
- **Auth**: `--user alice --password secret` gates every endpoint with HTTP
  basic auth. The macOS app prompts for credentials and remembers them.
- **Firewall**: open the port (`sudo ufw allow 8080`).
- **Bonjour**: advertising uses Network.framework and is **macOS-only**. On
  Linux pass `--no-bonjour` (otherwise the flag is a silent no-op). Clients
  reach the server by host:port; see "Connect from the macOS app" below.
- **One writer per library**: never run a second server (or the macOS app
  with the same library open) against the same library directory — the
  journal supports exactly one writer.

### systemd (optional)

```
# /etc/systemd/system/stacks-server.service
[Unit]
Description=Stacks library server
After=network.target

[Service]
User=stacks
ExecStart=/opt/stacks/bookmanager serve /srv/stacks/library --no-bonjour
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now stacks-server
```

## Verify

```bash
# Server-side state
./.build/release/bookmanager status /srv/stacks/library
# → Library ID, format version, journal seq, book counts

# Protocol check (anonymous)
curl http://<host>:8080/api/sync?after=0
# → {"seq":0,"commands":[]}

# Protocol check (auth required)
curl -u alice:secret http://<host>:8080/api/sync?after=0
```

### Connect from the macOS app

The app's Shared sidebar section discovers libraries over Bonjour
(`_bookmanager._tcp`). A Linux server cannot advertise (macOS-only API), and
manual host:port entry in the app is not wired yet — so until that lands,
verify the server with `curl` (above) or connect it to another client that
takes a URL. The protocol itself is identical on every platform.

## Update

```bash
git pull && swift build -c release
# restart the service if installed
```

## Troubleshooting

- `swift build` fails with toolchain errors — install Swift 6.0+ from
  swift.org; distro-packaged Swift versions are often too old.
- "Address already in use" — another server (or app instance) holds the
  port; `--port` is per-library and only one writer per library is allowed.
- Permission errors on create/serve — the service user needs read/write on
  the library directory (the server is the writer).
- Clients get 401 — the server was started with `--user`/`--password`;
  supply credentials or restart it anonymous.
