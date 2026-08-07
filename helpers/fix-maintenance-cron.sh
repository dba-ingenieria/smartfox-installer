#!/bin/bash
### Fix / standardize the nightly clean_files maintenance cron job ###
#
# Field problem this converges (seen in clean_files.log as
# "No such image: ghcr.io/dba-ingenieria/smartfox-core:latest"):
# hand-edited or pre-pin cron jobs resolve ${SMARTFOX_VERSION:-latest} with no
# pin in /opt/smartfox/.env, so at midnight compose either pulls a full image
# over the station link or fails outright and nothing cleans. A diverged line
# is also invisible to installer.sh's idempotence check, so the next update
# would add a second job on top of it.
#
# What it does, in order (idempotent, safe on a recording station — nothing
# is restarted and no image is ever pulled):
#   1. Detect the version already on the device: the core container first
#      (ground truth), then web (calibration bench), then the existing .env
#      pin, then the newest local smartfox-core image. A candidate only wins
#      if its smartfox-core image is actually on disk.
#   2. Pin SMARTFOX_VERSION=<tag> in /opt/smartfox/.env so every compose call
#      resolves to the image on disk.
#   3. Replace ALL existing maintenance lines in root's crontab with the
#      standard one (the same line installer.sh writes, including
#      `--pull never` where compose supports it). Other cron jobs are kept.
#   4. Verify with `docker compose config` that the job resolves to an image
#      present locally.
#
# Usage (as the login user, like installer.sh):
#   curl -O https://raw.githubusercontent.com/dba-ingenieria/smartfox-installer/main/helpers/fix-maintenance-cron.sh
#   bash fix-maintenance-cron.sh            # fix pin + cron, then verify
#   bash fix-maintenance-cron.sh --run-now  # additionally run the job once now

set -e

RUN_NOW=0
for arg in "$@"; do
  case "$arg" in
    --run-now) RUN_NOW=1 ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: bash fix-maintenance-cron.sh [--run-now]"
      exit 1
      ;;
  esac
done

COMPOSE_DIR="/opt/smartfox"
ENV_FILE="$COMPOSE_DIR/.env"
CORE_IMAGE="ghcr.io/dba-ingenieria/smartfox-core"
LOG_DIR="/var/lib/smartfox/logs/internal"

echo "== SmartFox maintenance-cron fixer =="

####### PREFLIGHT #######

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found — this does not look like an installed station."
  exit 1
fi
if ! sudo docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin not found."
  exit 1
fi
if [[ ! -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
  echo "ERROR: $COMPOSE_DIR/docker-compose.yml not found. Run installer.sh first."
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run installer.sh first."
  exit 1
fi

####### 1. DETECT THE VERSION ALREADY ON THE DEVICE #######
# Container lookup is by compose label, not container name: older deployments
# predate `container_name:` in docker-compose.yml and run as smartfox-core-1.

img_for_service() {
  local svc="$1" img
  img="$(sudo docker ps --filter "label=com.docker.compose.service=$svc" --format '{{.Image}}' | head -n 1)"
  if [[ -z "$img" ]]; then
    img="$(sudo docker ps -a --filter "label=com.docker.compose.service=$svc" --format '{{.Image}}' | head -n 1)"
  fi
  printf '%s' "$img"
}

TAG=""
SOURCE=""

# A candidate only wins if its core image is actually on disk — a container
# can outlive its tag (docker rmi -f / prune untags but the reference stays).
try_tag() {
  local candidate="$1" source="$2"
  if [[ -n "$TAG" || -z "$candidate" || "$candidate" == "<none>" ]]; then
    return 0
  fi
  if sudo docker image inspect "$CORE_IMAGE:$candidate" >/dev/null 2>&1; then
    TAG="$candidate"
    SOURCE="$source"
  else
    echo "  candidate '$candidate' ($source): $CORE_IMAGE:$candidate not on disk, skipping"
  fi
}

echo ""
echo "Detecting deployed version (never pulling)"

IMG="$(img_for_service core || true)"
[[ "$IMG" == *:* ]] && try_tag "${IMG##*:}" "core container"

IMG="$(img_for_service web || true)"
[[ "$IMG" == *:* ]] && try_tag "${IMG##*:}" "web container (calibration bench)"

PIN="$(sudo sed -n 's/^SMARTFOX_VERSION=//p' "$ENV_FILE" | head -n 1 || true)"
try_tag "$PIN" "existing .env pin"

if [[ -z "$TAG" ]]; then
  while IFS= read -r local_tag; do
    try_tag "$local_tag" "local image list"
  done < <(sudo docker images "$CORE_IMAGE" --format '{{.Tag}}' || true)
fi

if [[ -z "$TAG" ]]; then
  echo "ERROR: no smartfox-core image found on this device at all."
  echo "There is nothing the maintenance job could run with. Deploy first with"
  echo "installer.sh (schedule it — the pull is a few hundred MB), then re-run"
  echo "this helper."
  exit 1
fi

echo "Deployed version: $TAG (from $SOURCE)"

####### 2. PIN THE VERSION IN /opt/smartfox/.env #######
# Same update-or-append pattern as installer.sh. Compose interpolates
# ${SMARTFOX_VERSION:-latest} from this file whenever the caller's environment
# does not set it, so this alone stops the midnight job from resolving to
# :latest. Changes nothing until the next compose call; restarts nothing.

echo ""
if [[ "$PIN" == "$TAG" ]]; then
  echo "Version pin already correct (SMARTFOX_VERSION=$TAG)."
elif sudo grep -q '^SMARTFOX_VERSION=' "$ENV_FILE"; then
  sudo sed -i "s|^SMARTFOX_VERSION=.*|SMARTFOX_VERSION=$TAG|" "$ENV_FILE"
  echo "Version pin updated: SMARTFOX_VERSION='$PIN' -> '$TAG'"
else
  echo "SMARTFOX_VERSION=$TAG" | sudo tee -a "$ENV_FILE" >/dev/null
  echo "Version pin added: SMARTFOX_VERSION=$TAG"
fi

####### 3. STANDARDIZE THE CRON JOB #######
# `--pull never` turns a missing/wrong pin into a loud failure in the log
# instead of an accidental full-image download over the station link at
# midnight. Compose plugins older than v2.18 lack the flag on `run`; those
# fall back to relying on the pin alone.

if sudo docker compose run --help 2>/dev/null | grep -qE '^\s*--pull '; then
  MAINT_RUN_FLAGS="--rm --pull never"
else
  MAINT_RUN_FLAGS="--rm"
  echo "WARNING: this compose plugin does not support 'run --pull never';"
  echo "         installing the job without it (the version pin still prevents pulls)."
fi

CRON_LINE="0 0 * * * /bin/bash -lc 'install -d -o 1000 -g 1000 $LOG_DIR && cd $COMPOSE_DIR && sudo docker compose run $MAINT_RUN_FLAGS maintenance >> $LOG_DIR/clean_files.log.\$(date +\%F) 2>&1'"

echo ""
echo "Standardizing root's maintenance cron line"
CURRENT_CRON="$(sudo crontab -l 2>/dev/null || true)"
OLD_LINES="$(printf '%s\n' "$CURRENT_CRON" | grep -E 'docker compose run.*maintenance' || true)"
DESIRED_CRON="$({ printf '%s\n' "$CURRENT_CRON" | grep -vE 'docker compose run.*maintenance' || true; echo "$CRON_LINE"; } | sed '/^[[:space:]]*$/d')"

if [[ "$(printf '%s\n' "$CURRENT_CRON" | sed '/^[[:space:]]*$/d')" == "$DESIRED_CRON" ]]; then
  echo "Cron job already standard."
else
  if [[ -n "$OLD_LINES" ]]; then
    echo "Replacing existing maintenance line(s):"
    printf '  %s\n' "$OLD_LINES"
  else
    echo "No maintenance line found — adding one."
  fi
  printf '%s\n' "$DESIRED_CRON" | sudo crontab -
  echo "Installed:"
  echo "  $CRON_LINE"
fi

####### 4. VERIFY — THE JOB MUST RESOLVE TO AN IMAGE ON DISK #######

echo ""
echo "Verifying image resolution for the cron job"
RESOLVED="$(cd "$COMPOSE_DIR" && sudo docker compose config 2>/dev/null | grep -E 'image:.*smartfox-core' | awk '{print $2}' | sort -u || true)"
if [[ -z "$RESOLVED" ]]; then
  echo "WARNING: could not resolve the maintenance image via 'docker compose config'."
  echo "Check manually: cd $COMPOSE_DIR && sudo docker compose config | grep image:"
elif [[ "$(printf '%s\n' "$RESOLVED" | wc -l)" -gt 1 ]]; then
  echo "WARNING: compose resolves more than one smartfox-core reference:"
  printf '  %s\n' "$RESOLVED"
elif sudo docker image inspect "$RESOLVED" >/dev/null 2>&1; then
  echo "OK: compose resolves to $RESOLVED, which is on disk — the nightly job will not pull."
else
  echo "ERROR: compose resolves to $RESOLVED but that image is NOT on disk."
  echo "Something overrides the pin (an exported SMARTFOX_VERSION?). The job"
  echo "would pull or fail — do not leave the station like this."
  exit 1
fi

####### OPTIONAL: RUN THE JOB ONCE NOW #######
# Runs clean_files exactly as the cron job will (same flags, same log file).
# Safe at any hour: it only applies the configured retention.

if [[ "$RUN_NOW" == "1" ]]; then
  echo ""
  echo "Running the maintenance job once now"
  sudo install -d -o 1000 -g 1000 "$LOG_DIR"
  LOG_FILE="$LOG_DIR/clean_files.log.$(date +%F)"
  if sudo bash -c "cd $COMPOSE_DIR && docker compose run $MAINT_RUN_FLAGS maintenance >> '$LOG_FILE' 2>&1"; then
    echo "Maintenance run finished OK. Last lines of $LOG_FILE:"
    sudo tail -n 15 "$LOG_FILE"
  else
    echo "ERROR: maintenance run failed. Last lines of $LOG_FILE:"
    sudo tail -n 15 "$LOG_FILE"
    exit 1
  fi
fi

echo ""
echo "Done. The job runs at 00:00 and logs to $LOG_DIR/clean_files.log.<date>."
