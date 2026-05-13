ARG BASE_IMAGE=ghcr.io/graalvm/jdk-community:25-ol9
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN microdnf install -y \
  bash \
  tmux \
  curl \
  jq \
  gzip \
  openssh-clients \
  procps-ng \
  tar \
  util-linux \
  unzip \
  zip \
  shadow-utils \
  && microdnf clean all

ARG MINECRAFT_UID=1000
ARG MINECRAFT_GID=1000

RUN groupadd -g "${MINECRAFT_GID}" minecraft \
  && useradd -u "${MINECRAFT_UID}" -g "${MINECRAFT_GID}" -m -d /home/minecraft -s /bin/bash minecraft

RUN printf '%s\n' \
  'set -g mouse on' \
  'set -g history-limit 50000' \
  'set -g remain-on-exit off' \
  > /etc/tmux.conf

WORKDIR /minecraft

COPY --chown=minecraft:minecraft . /minecraft
RUN chmod +x /minecraft/start.sh /minecraft/mc-*.sh 2>/dev/null || true

RUN cat > /usr/local/bin/container-start <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

session="${TMUX_SESSION:-minecraft}"
workdir="/minecraft"
start_command="${START_COMMAND:-./start.sh}"

if (($# > 0)); then
  printf -v start_command '%q ' "$@"
fi

cd "$workdir"

if tmux has-session -t "$session" 2>/dev/null; then
  echo "tmux session '$session' already exists" >&2
  exit 1
fi

tmux new-session -d -s "$session" -c "$workdir" "bash -lc $(printf '%q' "$start_command")"
tmux pipe-pane -o -t "$session" 'cat >> /proc/1/fd/1'

shutdown() {
  tmux has-session -t "$session" 2>/dev/null || exit 0
  tmux send-keys -t "$session" C-c || true

  for _ in {1..120}; do
    tmux has-session -t "$session" 2>/dev/null || exit 0
    sleep 1
  done

  echo "tmux session '$session' did not stop in time; killing it" >&2
  tmux kill-session -t "$session" 2>/dev/null || true
  exit 143
}

trap shutdown INT TERM

while tmux has-session -t "$session" 2>/dev/null; do
  sleep 1
done
EOF

RUN cat > /usr/local/bin/attach <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

session="${TMUX_SESSION:-minecraft}"

if ! tmux has-session -t "$session" 2>/dev/null; then
  echo "tmux session '$session' is not running" >&2
  exit 1
fi

exec tmux attach-session -t "$session"
EOF

RUN chmod +x /usr/local/bin/container-start /usr/local/bin/attach

ENV HOME=/home/minecraft \
  TERM=xterm-256color \
  START_COMMAND=./start.sh

ENTRYPOINT ["container-start"]
