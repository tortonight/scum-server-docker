# SCUM Dedicated Server Docker

Docker project for running a **SCUM dedicated server** on Linux with:

- **Debian Trixie slim**
- **Wine 11.0**
- pre-configured **64-bit Wine prefix**
- startup automation for **SteamCMD install/update**
- startup automation for **SCUM dedicated server install/update**
- a **memory watchdog** to reduce crash risk on low-memory hosts
- **scheduled in-container restarts** via `RESTART_SCHEDULE=4,10,16,22`

This project follows the same overall pattern as the reference repo at <https://github.com/EvilOlaf/scum>, with the requested additions for `GAME_UPDATE` and scheduled restarts.

## Quick start

1. Open this folder.
2. Build and start the container:

```bash
   docker compose up -d --build
```

3. Watch the first install:

```bash
   docker compose logs -f
```

The first run can take a while because the container may need to install SteamCMD, update itself, and download the full SCUM dedicated server.

## Files

- `Dockerfile` - Debian Trixie image with Wine 11.0 and a prepared 64-bit Wine prefix
- `start-server.sh` - installs or updates SteamCMD, optionally updates SCUM, starts the server, watches memory, and restarts on schedule
- `docker-compose.yml` - ready-to-run local deployment example

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `GAMEPORT` | `7777` | Base SCUM game port. SCUM also uses the next two ports automatically. |
| `QUERYPORT` | `27015` | Query port for server discovery and status traffic. |
| `MAXPLAYERS` | `32` | Maximum player count passed to the SCUM server. |
| `ADDITIONALFLAGS` | empty | Extra command-line flags, for example `-nobattleye`. |
| `GAME_UPDATE` | `true` | `true` updates SCUM with SteamCMD during startup; `false` reuses existing files in `/opt/scumserver`. |
| `RESTART_SCHEDULE` | `4,10,16,22` | Comma-separated 24-hour values. The container sends a graceful restart at each listed hour. Leave empty to disable. |
| `UPDATE_MIN_INTERVAL_MINUTES` | `30` | Minimum minutes between successful SCUM update attempts when `GAME_UPDATE=true`. Prevents update loops if the container restarts repeatedly. Set `0` to always try. |
| `MEMORY_THRESHOLD_PERCENT` | `95` | If system memory usage reaches this percentage, the watchdog triggers a graceful restart. Set `0` to disable. |
| `MEMORY_CHECK_INTERVAL` | `60` | Seconds between watchdog checks. |
| `MEMORY_WATCHDOG_DEBUG` | `false` | When `true`, logs each watchdog reading. |

## Volumes

The compose file persists data in two local folders:

- `./scumserver-data` -> `/opt/scumserver`
- `./steamcmd` -> `/opt/steamcmd`

This keeps the SCUM installation, saves, and SteamCMD files across container restarts.

## Port notes

The compose file exposes the same ports commonly used by SCUM:

- `7777`, `7778`, `7779` for game traffic
- `27015` for query traffic

Players typically connect on the **third** game port, so with the defaults that is **7779**.

If you change `GAMEPORT` or `QUERYPORT`, update the published ports in `docker-compose.yml` to match.

## Behavior notes

- SteamCMD is installed automatically if it is missing.
- SteamCMD is self-updated on every container start.
- If `GAME_UPDATE=false`, the script skips the SCUM download/update step and uses the existing files already stored in `./scumserver-data`.
- If `GAME_UPDATE=true`, failed SteamCMD update attempts now fall back to existing server files (if present) instead of forcing a startup crash loop.
- Scheduled restarts happen inside the container without needing host cron jobs.
- Low-memory protection attempts a graceful restart before the process crashes hard.

## Credits

- Base project inspiration and original Dockerized SCUM server approach: [EvilOlaf/scum](https://github.com/EvilOlaf/scum)
