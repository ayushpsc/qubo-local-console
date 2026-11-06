#!/bin/sh
set -eu

TASK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="$TASK_DIR/.env"
CONTAINER_NAME="qubo-go2rtc"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE" >&2
  echo "Copy .env.example to .env and fill in the LAN/Qubo values first." >&2
  exit 1
fi

set -a
# This is a user-owned local configuration file containing simple KEY=VALUE
# entries. It is intentionally excluded from Git.
. "$ENV_FILE"
set +a

: "${QDEVICE:?Set QDEVICE in .env}"
: "${QUNIT:?Set QUNIT in .env}"
: "${QMOB:?Set QMOB in .env}"
: "${QADVERT:?Set QADVERT in .env}"

if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  docker update --restart always "$CONTAINER_NAME" >/dev/null
  RUNNING=$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")
  if [ "$RUNNING" = "true" ]; then
    echo "$CONTAINER_NAME is already running."
  else
    docker start "$CONTAINER_NAME"
  fi
  echo "Logs: docker logs -f $CONTAINER_NAME"
  exit 0
fi

set -- docker run --detach \
  --name "$CONTAINER_NAME" \
  --restart always \
  --network host \
  --env QDEVICE \
  --env QUNIT \
  --env QMOB \
  --env QADVERT \
  --env QPORT="${QPORT:-49700}" \
  --env QQUALITY="${QQUALITY:-high}" \
  --env QVIDEOFPS="${QVIDEOFPS:-10}" \
  --env QDUR="${QDUR:-86400}" \
  --env QMEDIATIMEOUT="${QMEDIATIMEOUT:-30}" \
  --env QSTALLTIMEOUT="${QSTALLTIMEOUT:-120}" \
  --env QAUDIO="${QAUDIO:-true}" \
  --env QAUDIOWAIT="${QAUDIOWAIT:-8}" \
  --env QAUDIOGAINDB="${QAUDIOGAINDB:-20}" \
  --env QTALK="${QTALK:-false}" \
  --env QTALKGAINDB="${QTALKGAINDB:-12}" \
  --env QFFMPEG="${QFFMPEG:-ffmpeg}" \
  --env QLIBS=/config/_libs \
  --volume "$TASK_DIR:/config"

if [ -n "${HA_CONFIG_DIR:-}" ]; then
  HA_STORAGE="$HA_CONFIG_DIR/.storage"
  HA_STORE="$HA_STORAGE/core.config_entries"
  if [ ! -f "$HA_STORE" ]; then
    echo "Home Assistant credentials file not found: $HA_STORE" >&2
    echo "Fix HA_CONFIG_DIR, or leave it blank and set QACCESS and QUUID." >&2
    exit 1
  fi
  set -- "$@" \
    --env QSTORE=/ha-storage/core.config_entries \
    --volume "$HA_STORAGE:/ha-storage:ro"
else
  : "${QACCESS:?Set QACCESS when HA_CONFIG_DIR is blank}"
  : "${QUUID:?Set QUUID when HA_CONFIG_DIR is blank}"
  set -- "$@" --env QACCESS --env QUUID --env QREFRESH
fi

if [ -n "${QSOURCE:-}" ]; then
  set -- "$@" --env QSOURCE
fi

set -- "$@" alexxit/go2rtc:latest
"$@"

echo "Started $CONTAINER_NAME."
echo "Player: http://$QADVERT:1984/stream.html?src=qubo_doorbell"
echo "Logs: docker logs -f $CONTAINER_NAME"
