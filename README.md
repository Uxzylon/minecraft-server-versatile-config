# Minecraft Server Toolkit

A small Bash-based toolkit for running and maintaining a Minecraft server setup with a main server jar, optional service jars such as Velocity, automatic updates, backups, Dynmap helpers, and Docker support.

The tools are designed around one `.env` file. Most configuration changes should happen there instead of editing the scripts.

## Included tools

| File                 | Purpose                                                                                                                       |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `start.sh`           | Runs the Minecraft server and service jars, combines logs, forwards console input, and supports external start/stop commands. |
| `mc-common.sh`       | Shared helper functions and `.env` loading used by the other scripts.                                                         |
| `mc-updater.sh`      | Installs and updates Fabric server jars, Velocity/PaperMC jars, Modrinth projects, CurseForge projects, and direct URL jars.  |
| `mc-backup.sh`       | Creates full or world-only backups, can warn players in-game, and can restore archives.                                       |
| `mc-dynmap.sh`       | Uploads Dynmap web files and can reset Dynmap SQL tables.                                                                     |
| `Dockerfile`         | Builds a GraalVM-based container that runs the configured start command inside tmux.                                          |
| `docker-compose.yml` | Runs the toolkit with Docker Compose.                                                                                         |
| `.env.example`       | Example configuration file. Copy it to `.env` and edit it.                                                                    |

## Requirements

On a host system, install:

```bash
bash curl jq zip unzip tar mysql-client openssh-client
```

For Docker usage, install Docker and Docker Compose.

The scripts should be executable:

```bash
chmod +x start.sh mc-common.sh mc-updater.sh mc-backup.sh mc-dynmap.sh
```

## Quick start: Fabric + Velocity

Start in an empty server folder containing the toolkit files.

```bash
cp .env.example .env
```

Edit `.env` and set at least:

```env
MC_GAME_VERSION=1.21.6
MC_SERVER_LOADER=fabric
START_SERVER_ON_BOOT=false
START_SERVICES_ON_BOOT=true
SERVER_WORKING_DIR=.
SERVER_ARGS=nogui
SERVICES_CONFIG=velocity|velocity|velocity.jar|-Xms512M -Xmx1G|
```

Install the Fabric server jar and update `SERVER_JAR` in `.env`:

```bash
./mc-updater.sh add fabric-server . --mc 1.21.6 --env-key SERVER_JAR
```

Install Velocity into the `velocity/` folder:

```bash
./mc-updater.sh add papermc velocity velocity
```

If the downloaded Velocity file is not named `velocity.jar`, either rename it:

```bash
mv velocity/velocity-*.jar velocity/velocity.jar
```

or update `SERVICES_CONFIG` in `.env` with the downloaded filename.

Accept the Minecraft EULA:

```bash
echo 'eula=true' > eula.txt
```

Start the launcher:

```bash
./start.sh
```

The launcher starts Velocity. The Minecraft server jar will not start automatically because `START_SERVER_ON_BOOT=false`.

Inside the launcher console:

```text
!help
!start
!stop
!status
!exit
```

When the Minecraft server is running, normal input is sent directly to Minecraft. Launcher commands always start with `!`.

## Using Velocity AutoServer

AutoServer can start and stop the Minecraft server through the running launcher.

Example AutoServer server config:

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

The external commands behave like typing these in the launcher console:

```text
!start
!stop
```

For Velocity, make sure `velocity.toml` points to the backend server port, for example:

```toml
[servers]
host = "127.0.0.1:25566"
try = ["host"]
```

And make sure the Minecraft backend uses the same port in `server.properties`:

```properties
server-port=25566
online-mode=false
```

## Managing services

Services are configured with `SERVICES_CONFIG`:

```env
SERVICES_CONFIG=velocity|velocity|velocity.jar|-Xms512M -Xmx1G|
```

Format:

```text
name|working_dir|jar_path|java_opts|jar_args
```

Multiple services are separated with semicolons:

```env
SERVICES_CONFIG=velocity|velocity|velocity.jar|-Xms512M -Xmx1G|;bot|bot|bot.jar|-Xmx512M|
```

Service commands in the launcher:

```text
!services
!start-service velocity
!stop-service velocity
!restart-service velocity
```

## Installing mods and plugins

Use `mc-updater.sh` to track and update mods/plugins.

Install Fabric API into `mods/`:

```bash
./mc-updater.sh add modrinth fabric-api mods
```

Install a Velocity plugin from Modrinth into `velocity/plugins/`:

```bash
./mc-updater.sh add modrinth limboapi velocity/plugins --loader velocity
```

Install from CurseForge using a project ID:

```bash
./mc-updater.sh add curseforge 238222 mods
```

CurseForge requires:

```env
CURSEFORGE_API_KEY=your-api-key
```

List tracked components:

```bash
./mc-updater.sh list
```

Update everything:

```bash
./mc-updater.sh update
```

Update one entry:

```bash
./mc-updater.sh update fabric-api
```

Disable or enable an entry:

```bash
./mc-updater.sh disable fabric-api
./mc-updater.sh enable fabric-api
```

## Docker usage

Build and start:

```bash
docker compose up -d --build
```

Follow logs:

```bash
docker compose logs -f minecraft
```

Attach to the live tmux console:

```bash
docker compose exec minecraft attach
```

Detach from tmux without stopping the server:

```text
Ctrl+B, then D
```

Stop the stack:

```bash
docker compose down
```

The Docker container runs the command from `.env`:

```env
START_COMMAND=./start.sh
```

## Backups

Configure backups in `.env`:

```env
MC_BACKUP_SERVER_DIR=.
MC_BACKUP_DIR=./backups
MC_BACKUP_NAME=minecraft-server
MC_BACKUP_WORLDS=world
MC_BACKUP_FORMAT=auto
```

Create a full backup:

```bash
./mc-backup.sh full
```

Create a world-only backup:

```bash
./mc-backup.sh worlds
```

Restart the server with warnings but no backup:

```bash
./mc-backup.sh restart
```

Restore a backup:

```bash
./mc-backup.sh restore ./backups/example.zip
```

Backup notifications are best-effort. If the server is not running or the console cannot be reached, the backup still runs.

## Dynmap helpers

Configure Dynmap upload:

```env
DYNMAP_WEB_SOURCE=dynmap/web
DYNMAP_REMOTE_HOST=user@example.com
DYNMAP_REMOTE_WEB_LOCATION=/home/user/.nginx/html/dynmap
```

Upload Dynmap web files:

```bash
./mc-dynmap.sh upload-web
```

Configure SQL reset:

```env
DYNMAP_DB_HOST=example.com
DYNMAP_DB_PORT=3306
DYNMAP_DB_USER=dynmap
DYNMAP_DB_NAME=dynmap
DYNMAP_DB_PASSWORD=
```

Reset Dynmap SQL tables:

```bash
./mc-dynmap.sh reset-sql
```

Run both SQL reset and web upload:

```bash
./mc-dynmap.sh sync
```

## Typical update workflow

Stop the running server if needed:

```text
!stop
```

Update all tracked jars, mods, and plugins:

```bash
./mc-updater.sh update
```

Start again:

```text
!start
```

Or restart the whole launcher:

```text
!exit
./start.sh
```

## Common launcher commands

```text
!help                         Show launcher help
!start                        Start the main Minecraft server jar
!stop                         Stop the main Minecraft server jar
!restart                      Restart the main Minecraft server jar
!status                       Show server and service status
!services                     List configured services
!send <command>               Send a command to Minecraft
!exit                         Stop everything and exit
```
