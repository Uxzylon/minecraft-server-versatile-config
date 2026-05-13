# Minecraft Server Toolkit

Generic Bash and Docker tooling for running a Minecraft server folder. It can run one main server jar, optional side-service jars such as Velocity, and maintenance helpers for manual updates, backups, and Dynmap.

Configuration lives in `.env`. The committed files are meant to stay generic; copy `.env.example` to `.env`, then uncomment only the values this server actually overrides.

## Files

| File | Purpose |
| --- | --- |
| `start.sh` | Runs the main server jar and service jars in one console, with shared logs and launcher commands. |
| `mc-common.sh` | Shared logging, bool parsing, and `.env` loading. |
| `mc-updater.sh` | Manual installer/updater for Fabric server jars, PaperMC/Velocity jars, Modrinth, CurseForge, and direct URL jars. |
| `mc-backup.sh` | Full or world-only backups, restore, save-off/save-on, and optional server restart. |
| `mc-dynmap.sh` | Dynmap web upload and SQL table reset helpers. |
| `Dockerfile` | Generic Java/tmux container. It does not know about Velocity or any specific server topology. |
| `docker-compose.yml` | Mounts a server folder at `/minecraft`, exposes configured ports, and runs `START_COMMAND`. |
| `.env.example` | Mostly commented override catalog. Copy to `.env`, then uncomment/edit values. |

## Requirements

Local usage needs Bash plus the tools used by the commands you run:

```bash
chmod +x start.sh mc-*.sh
```

```bash
# updater
curl jq

# backups
tar gzip zip unzip

# dynmap upload / SQL reset
openssh-client mysql-client
```

Docker usage needs Docker Compose. The image already includes Java, tmux, curl, jq, zip/unzip, tar/gzip, and SSH client tools.

## Start From Zero

1. Copy the toolkit files into an empty server folder.

2. Create your local config:

```bash
cp .env.example .env
```

3. Open `.env`. The most common settings are at the top and are commented with defaults/examples:

```env
# MC_GAME_VERSION=1.21.6
# MC_SERVER_LOADER=fabric
# MC_UPDATER_PLATFORMS=fabric,velocity,paper
# SERVER_JAVA_OPTS=-Xms2G -Xmx4G
# MINECRAFT_PORT=25565
# DOCKER_BASE_IMAGE=ghcr.io/graalvm/jdk-community:25-ol9
```

Uncomment the lines you want to override. Leaving a line commented means the script default is used.

4. Pick one topology and uncomment/edit those lines.

For one server jar without services:

```env
START_SERVER_ON_BOOT=true
START_SERVICES_ON_BOOT=false
SERVICES_CONFIG=
SERVER_WORKING_DIR=.
SERVER_ARGS=nogui
```

For Velocity plus a lazy backend started by AutoServer:

```env
START_SERVER_ON_BOOT=false
START_SERVICES_ON_BOOT=true
SERVER_WORKING_DIR=.
SERVER_ARGS=nogui
MC_HEALTHCHECK_PORT=25565
```

You can leave `SERVICES_CONFIG` commented until you install Velocity. The updater will fill it with the real downloaded Velocity filename.

In that setup, Velocity listens on `25565` and the backend Minecraft server usually listens on another port, for example `25566`.

The rest of `.env.example` stays grouped by tool: launcher, Docker, updater, backups, Dynmap, and shared `.env` loading. Those lower sections are mostly advanced knobs.

## Install Jars, Mods, And Plugins

The updater is manual. It only installs or updates files when you run it.

Install a Fabric server jar and write the downloaded filename into `SERVER_JAR` in `.env`:

```bash
./mc-updater.sh add fabric-server . --mc 1.21.6 --env-key SERVER_JAR
```

If `SERVER_JAR` is still commented in `.env`, the updater activates that template line instead of appending a duplicate.

Install Velocity from PaperMC into `velocity/`:

```bash
./mc-updater.sh add papermc velocity velocity
```

This keeps the real PaperMC filename, activates `SERVICES_CONFIG` if it is commented, adds the `velocity` service if it is missing, and updates the service jar filename on future `./mc-updater.sh update` runs.

Install a Paper server jar instead of Fabric:

```bash
./mc-updater.sh add papermc paper . --filename paper.jar --env-key SERVER_JAR
```

Install Fabric API into `mods/`:

```bash
./mc-updater.sh add modrinth fabric-api mods
```

Install a Velocity plugin from Modrinth, for example AutoServer:

```bash
./mc-updater.sh add modrinth autoserver velocity/plugins --loader velocity --ignore-game-version
```

Install a CurseForge project by numeric project id:

```bash
CURSEFORGE_API_KEY=your-api-key
./mc-updater.sh add curseforge 238222 mods
```

Install any direct jar URL:

```bash
./mc-updater.sh add url my-plugin https://example.com/plugin.jar plugins --filename my-plugin.jar
```

Manage tracked entries:

```bash
./mc-updater.sh list
./mc-updater.sh update
./mc-updater.sh update fabric-api
./mc-updater.sh disable fabric-api
./mc-updater.sh enable fabric-api
./mc-updater.sh remove fabric-api
```

Accept the EULA before the first server start:

```bash
printf 'eula=true\n' > eula.txt
```

## Launcher Console

Start locally:

```bash
./start.sh
```

Launcher commands start with `!`:

```text
!help
!start
!stop
!restart
!status
!services
!start-service velocity
!stop-service velocity
!send say hello
!exit
```

When the main server is running, normal console input is sent to Minecraft. To send a Minecraft command that starts with `!`, type it as `!!command`.

External scripts can control the running launcher through the same commands:

```bash
./start.sh start
./start.sh stop
./start.sh send "say hello"
```

## Velocity AutoServer

For lazy backend startup, configure AutoServer to call the launcher:

```toml
[servers.host]
workingDirectory = "../"
start = "bash start.sh start"
stop = "bash start.sh stop"
startupDelay = 10
shutdownDelay = 30
autoShutdownDelay = 1800
preserveQuotes = true
```

Velocity should point at the backend port:

```toml
[servers]
host = "127.0.0.1:25566"
try = ["host"]
```

The backend `server.properties` should match:

```properties
server-port=25566
online-mode=false
```

## Docker

Build and start:

```bash
docker compose up -d --build
```

Follow combined logs:

```bash
docker compose logs -f minecraft
```

Attach to the live tmux console:

```bash
docker compose exec minecraft attach
```

Detach without stopping the server: press `Ctrl+B`, then `D`.

Stop the stack:

```bash
docker compose down
```

Useful Docker `.env` values are already listed near the top of `.env.example`; uncomment the ones you need:

```env
SERVER_WORKING_DIR=.
MINECRAFT_PORT=25565
MINECRAFT_CONTAINER_PORT=25565
MC_HEALTHCHECK_ENABLED=true
MC_HEALTHCHECK_PORT=25565
START_COMMAND=./start.sh
DOCKER_BASE_IMAGE=ghcr.io/graalvm/jdk-community:25-ol9
```

Use `DOCKER_BASE_IMAGE` when you need a different Java version, but keep it compatible with the package install step in `Dockerfile`.

## Backups

Configure backup paths in `.env`:

```env
SERVER_WORKING_DIR=.
MC_BACKUP_DIR=./backups
MC_BACKUP_WORLDS=world,world_nether,world_the_end
```

Run:

```bash
./mc-backup.sh full
./mc-backup.sh worlds
./mc-backup.sh worlds --no-stop
./mc-backup.sh restart
./mc-backup.sh restore ./backups/example.zip
```

Hot world backups use `save-all`, `save-off`, then `save-on`. If archiving fails, the script turns saving back on before returning.

## Dynmap

Configure upload and SQL reset in `.env`:

```env
DYNMAP_WEB_SOURCE=dynmap/web
DYNMAP_REMOTE_HOST=user@example.com
DYNMAP_REMOTE_WEB_LOCATION=/home/user/.nginx/html/dynmap
DYNMAP_DB_HOST=example.com
DYNMAP_DB_USER=dynmap
DYNMAP_DB_NAME=dynmap
```

Run:

```bash
./mc-dynmap.sh upload-web
./mc-dynmap.sh reset-sql
./mc-dynmap.sh sync
```

`sync` runs `reset-sql` first, then uploads the web files.
