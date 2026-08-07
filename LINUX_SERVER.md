# Stacks headless server on Linux

`stacks` is the headless server for Stacks libraries: it serves one library
over HTTP (sync protocol + OPDS) and is the single writer for it. Clients —
the macOS Stacks app or other `stacks`/`RemoteLibrary` instances — push
commands and pull records; the server serializes them and never merges.

Same Swift codebase as the app. The root `Package.swift` builds only the
server-facing subset (Journal, Library, Persistence, Server, Calibre import),
so a plain `swift build` works on macOS, Linux arm64 (Raspberry Pi 4/5,
64-bit OS), and Linux x86_64.

## Prerequisites

- **Swift 6.x toolchain** from [swift.org](https://www.swift.org/install/linux/)
  (`swift-tools-version: 6.0` requires Swift 6.0 or newer). Verify:
  `swift --version`.
- No other system packages to build: GRDB bundles SQLite, swift-crypto
  vendors BoringSSL, Hummingbird/NIO and swift-argument-parser are pure
  Swift.
- To advertise the library over the LAN: `sudo apt install avahi-daemon
  avahi-utils` (avahi-daemon usually runs by default on desktop distros;
  headless servers: `sudo systemctl enable --now avahi-daemon`). Without it
  the server runs fine — clients just reach it by host:port.
- Raspberry Pi: arm64 only — use the 64-bit Raspberry Pi OS image (Pi 3's
  32-bit armv7 is not supported).

## Build

```bash
git clone <repository-url> stacks
cd stacks
swift build -c release
```

The clone target folder is named explicitly so it doesn't depend on the
repository's name (`git clone <url>` without a target would use the repo
name). The first build resolves and fetches dependencies (needs network). The
executable lands at `.build/release/stacks`.

## Create a library

```bash
./.build/release/stacks create /srv/stacks/library
```

Prints the library ID (used by clients and the Bonjour TXT record) and the
format version.

## Import an existing Calibre library

`import-calibre` reads a Calibre library (read-only — it snapshots
`metadata.db` and never opens the original) and creates a Stacks library
from it. Run it once on the box that will serve the library:

```bash
./.build/release/stacks import-calibre \
    /path/to/Calibre\ Library \
    /srv/stacks/library
```

- Imports every book (title, authors, series, tags, ratings, publisher,
  identifiers, comments), all format files, and covers (fetched on demand
  from the Calibre database).
- The target is created if missing (an empty pre-made folder is adopted
  too); an existing library is imported into — format-hash duplicates are
  skipped, never overwritten.
- Progress goes to stderr; the final summary (imported / duplicates /
  failed / skipped) goes to stdout. Exit code 1 when any book failed.
- Re-running resumes: books already imported are skipped (per-source
  progress is tracked in the target's control directory).
- `--only <id>` (repeatable) imports a subset of Calibre book ids.

## Run

```bash
./.build/release/stacks serve /srv/stacks/library
```

Options (see `stacks serve --help`):

| Flag | Default | Meaning |
|---|---|---|
| `--port <port>` | `8080` | Listen port |
| `--user <user>` | — | Require this username (with `--password`) |
| `--password <pass>` | — | Password for `--user` |
| `--name <name>` | folder name | Display name (advertisement/diagnostics) |
| `--indexes <dir>` | see below | Catalog indexes directory |
| `--no-bonjour` | off | Do not advertise the library |

Notes:

- **Indexes**: defaults to the system application-support directory when
  that resolves; otherwise (typical on Linux) a sibling
  `.stacks-server-indexes/` next to the library. Never point two writers at
  the same index directory.
- **Advertising**: the server publishes `_stacks._tcp` via mDNS/DNS-SD —
  Network.framework on macOS, Avahi (`avahi-publish-service`) on Linux. The
  macOS app's Shared sidebar browses the same service type, so a Linux
  server appears exactly like a Mac one. On Linux this needs
  `avahi-daemon` + `avahi-utils` (see Prerequisites); without them pass
  `--no-bonjour` (otherwise it is a silent no-op) and reach the server by
  host:port.
- **Auth**: `--user alice --password secret` gates every endpoint with HTTP
  basic auth. The macOS app prompts for credentials and remembers them.
- **Firewall**: open the port (`sudo ufw allow 8080`).
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
ExecStart=/opt/stacks/stacks serve /srv/stacks/library
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
./.build/release/stacks status /srv/stacks/library
# → Library ID, format version, journal seq, book counts

# Protocol check (anonymous)
curl http://<host>:8080/api/sync?after=0
# → {"seq":0,"commands":[]}  (or the addBook commands after an import)

# Protocol check (auth required)
curl -u alice:secret http://<host>:8080/api/sync?after=0

# Download a book's format (id from a sync pull)
curl -o book.epub http://<host>:8080/api/books/<id>/download?format=EPUB
```

### Connect from the macOS app

The app's Shared sidebar discovers `_stacks._tcp` over mDNS — a Linux server
with Avahi running shows up there like any Mac host. For servers that can't
advertise (no Avahi, other subnets, containers), use **Connect to Server…**
at the bottom of the Shared section: type the host and port (optionally a
username/password) and the app validates the server via `/api/identity` and
connects. The protocol is identical on every platform.

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
- Permission errors on create/import/serve — the service user needs
  read/write on the library directory (the server is the writer); for
  `import-calibre` it needs read access to the Calibre library.
- Server is up but not visible in the app's Shared sidebar — is
  `avahi-daemon` running and `avahi-utils` installed? Same subnet as the
  Mac?
- Clients get 401 — the server was started with `--user`/`--password`;
  supply credentials or restart it anonymous.
