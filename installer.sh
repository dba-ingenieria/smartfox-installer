#!/bin/bash
set -e

############################################
# SmartFox Installer
#
# Modes:
#   --install    : one-time host bootstrap + deploy
#   --update     : safe redeploy (containers down first), refresh compose/programs,
#                 merge config YAML (add missing fields only), pull + start selected version
#
# Env flags:
#   --merge-env  : add missing keys from repo .env.template into /opt/smartfox/.env
#                 (does NOT overwrite existing values)
#   --reset-env  : delete /opt/smartfox/.env
#                 - in --install: it will be recreated interactively
#                 - in --update : installer will exit and recommend running --install first
#
# Variant:
#   --cal        : calibration bench unit. Full host provision and both images are
#                 pulled at the pinned version, but only web + cloudflared are
#                 started and the web UI hides the station-operation menus
#                 (SMARTFOX_VARIANT=cal in /opt/smartfox/.env).
#                 The variant of EACH run is decided by this flag's presence on
#                 THAT run:
#                   --install --cal   : fresh calibration bench
#                   --update  --cal   : update a bench, staying cal
#                   --update (no cal) : promote a bench to production (variant=full,
#                                       all services started; the calibration factor
#                                       in config/cal_factor.txt is preserved because
#                                       config/*.txt is seeded only when absent)
#
# Version:
#   --version=latest (default) or --version=v2.0.0-beta.3 or --version=2.0.0-beta.3
#
# Fleet agent (app versions that ship setup/agent/, v2.3.0+):
#   The installer also installs the fleet update agent and cosign, and
#   prompts once for the station's fleet token (/etc/smartfox/agent.env).
#   From then on updates are applied unattended by the agent inside the
#   station's maintenance window; this script is the one-time host bootstrap
#   and the last manual update. The recording enable flag is left in place
#   across updates (auto-resume) — only --cal removes it.
############################################

########### MODE + VERSION PARSER ###########

MODE="install"
RESET_ENV=0
MERGE_ENV=0
RESET_CONFIG=0
CAL_VARIANT=0
SMARTFOX_VERSION="latest"

for arg in "$@"; do
  case "$arg" in
    --install) MODE="install" ;;
    --update) MODE="update" ;;
    --reset-env) RESET_ENV=1 ;;
    --merge-env) MERGE_ENV=1 ;;
    --reset-config) RESET_CONFIG=1 ;;
    --cal) CAL_VARIANT=1 ;;
    --version=*)
      SMARTFOX_VERSION="${arg#*=}"
      ;;
    *)
      ;;
  esac
done

# Validate mode (only 2 supported)
case "$MODE" in
  install|update) ;;
  *)
    echo "ERROR: Unsupported mode: $MODE"
    echo "Use: --install | --update"
    exit 1
    ;;
esac

echo "Mode: $MODE"
echo "Version: $SMARTFOX_VERSION"
echo "Flags: reset-env=$RESET_ENV merge-env=$MERGE_ENV reset-config=$RESET_CONFIG cal=$CAL_VARIANT"

# Fleet agent bootstrap constants (FLEET AGENT block). cosign stays on the
# v2 line: it is what CI signs with, and v3 changed the bundle format.
FLEET_URL="https://fleet.smartfoxconfig.ai"
COSIGN_VERSION="v2.6.5"
COSIGN_SHA256="426193b4c5da4d4d643e822f48fe0cc8a476ca1782a272704831f5a0cef716d7"   # cosign-linux-arm64

# Keep your version parsing behavior
GIT_VERSION="$SMARTFOX_VERSION"
DOCKER_VERSION="$SMARTFOX_VERSION"

if [[ "$GIT_VERSION" != "latest" && "$GIT_VERSION" != "dev" && "$GIT_VERSION" != v* ]]; then
  GIT_VERSION="v${GIT_VERSION}"
fi

#if [[ "$DOCKER_VERSION" == v* ]]; then
#  DOCKER_VERSION="${DOCKER_VERSION#v}"
#fi

########### START ###########

echo "/// SmartFox Installer ///"
sleep 1

INSTALL_USER=$(logname)
INSTALL_HOME=$(eval echo "~$INSTALL_USER")

echo "Installing for user: $INSTALL_USER"
sleep 1

######### DEP CHECKS (non-install modes) #########

if [[ "$MODE" != "install" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker not found. Run --install first."
    exit 1
  fi
  if ! sudo docker compose version >/dev/null 2>&1; then
    echo "ERROR: docker compose plugin not available. Run --install first."
    exit 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git not found. Run --install first."
    exit 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: yq not found. Run --install first."
    exit 1
  fi
fi

######### GITHUB AUTH (ONE TOKEN FOR CLONE + GHCR) #########

if [[ -z "${GH_USER:-}" ]]; then
  read -p "GitHub Username: " GH_USER
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
  read -s -p "GitHub Token: " GH_TOKEN
  echo ""
fi

######### DOCKER + TOOLS INSTALL (INSTALL MODE ONLY) #########

if [[ "$MODE" == "install" ]]; then
  echo "Removing cache packages"
  sudo apt remove -y docker.io docker-compose docker-doc podman-docker containerd runc || true
  sudo apt update
  sudo apt -y install ca-certificates curl

  echo ""
  echo "Installing Docker"
  sleep 1
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$INSTALL_USER"

  ##### GIT INSTALL
  if ! command -v git >/dev/null; then
    echo ""
    echo "Installing Git"
    sleep 1
    sudo apt-get install -y git
  fi

  ##### yq INSTALL
  if ! command -v yq >/dev/null; then
    echo "Installing yq tool"
    sudo curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64 -o /usr/local/bin/yq
    sudo chmod +x /usr/local/bin/yq
  fi
fi

######### CONFIGURE NTP #############
if [[ "$MODE" == "install" ]]; then
  echo "Configuring NTP Server"
  FILE="/etc/systemd/timesyncd.conf"
  LINE="NTP=ntp.shoa.cl"
  if ! grep -Fxq "$LINE" "$FILE"; then
      if grep -q "^\[Time\]" "$FILE"; then
        awk -v line="$LINE" '
            /^\[Time\]/ { print; in_time=1; next }
            in_time && /^[[]/ { print line; in_time=0 }
            { print }
            END { if (in_time) print line }
        ' "$FILE" > /tmp/timesyncd.conf.tmp && sudo mv /tmp/timesyncd.conf.tmp "$FILE"
      else
          echo -e "\n[Time]\n$LINE" | sudo tee -a "$FILE" > /dev/null
      fi
      echo "Added: $LINE"
  else
      echo "Line already present."
  fi
  sudo systemctl restart systemd-timesyncd
fi


###### UPDATE LOGIC (safe like reinstall: stop containers first) ######

if [[ "$MODE" == "update" ]]; then
  echo "Update mode: stopping containers"
  # Stop the timer AND any in-flight oneshot run: the watchdog escalates to
  # `docker restart` / `systemctl restart docker` / reboot, and would otherwise
  # fight the `compose down` below. Re-enabled by the SERVICE MONITOR block
  # when the checked-out version ships it, or restarted at the end otherwise.
  sudo systemctl stop smartfox-svc-monitor.timer smartfox-svc-monitor.service 2>/dev/null || true
  # Same for the fleet agent: an apply in flight must not race this update.
  sudo systemctl stop smartfox-agent.timer smartfox-agent.service 2>/dev/null || true
  if [[ -f /opt/smartfox/docker-compose.yml ]]; then
    (cd /opt/smartfox && sudo docker compose down) || true
    # The recording enable flag is deliberately kept: start_smartfox.sh
    # resumes the pipeline with the new containers (auto-resume, the same
    # policy the fleet agent applies). --cal removes it further down.
  fi
fi

####### DOCKER WAIT FOR TIME-SET ############
if [[ "$MODE" == "install" ]]; then
  sudo mkdir -p /etc/systemd/system/docker.service.d
  sudo tee /etc/systemd/system/docker.service.d/wait-for-timesync.conf << 'EOF'
[Unit]
After=time-set.target
EOF
  sudo systemctl daemon-reload
fi

####### SYSTEM DIRECTORIES (ALL MODES) #######

sudo mkdir -p /opt/smartfox /var/lib/smartfox
sudo chown -R "$INSTALL_USER:$INSTALL_USER" /opt/smartfox /var/lib/smartfox
mkdir -p /opt/smartfox/web

###### CLONE / FETCH REPO (ALL MODES) ######

##### GIT_ASKPASS helper (prevents git prompting twice)
ASKPASS=$(mktemp)
cat > "$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) echo "$GH_USER" ;;
  *Password*) echo "$GH_TOKEN" ;;
esac
EOF
chmod +x "$ASKPASS"
export GIT_ASKPASS GH_USER GH_TOKEN
trap 'rm -f "$ASKPASS"' EXIT

cd "$INSTALL_HOME"

if [ ! -d smartfox ]; then
  echo ""
  echo "Cloning SmartFox repository"
  sleep 1
  GIT_ASKPASS="$ASKPASS" GH_USER="$GH_USER" GH_TOKEN="$GH_TOKEN" \
    git -c core.askPass="$ASKPASS" -c credential.helper= clone https://github.com/dba-ingenieria/smartfox.git
  cd smartfox
  git -c core.askPass="$ASKPASS" -c credential.helper= fetch --tags --force --prune
else
  cd smartfox
  GIT_ASKPASS="$ASKPASS" GH_USER="$GH_USER" GH_TOKEN="$GH_TOKEN" \
    git -c core.askPass="$ASKPASS" -c credential.helper= fetch --tags --force --prune
fi

if [[ "$SMARTFOX_VERSION" != "latest" ]]; then
  git tag -l | grep -F "$GIT_VERSION" || true
  git rev-parse "$GIT_VERSION" || true
  git checkout "$GIT_VERSION"
  if git rev-parse --verify "refs/heads/$GIT_VERSION" >/dev/null 2>&1; then
    git -c core.askPass="$ASKPASS" -c credential.helper= pull
  fi
else
  git checkout main
  git -c core.askPass="$ASKPASS" -c credential.helper= pull
fi

######## COPY RUNTIME ARTIFACTS (ALL MODES) ########

cp docker-compose.yml /opt/smartfox/
cp -r web/programs /opt/smartfox/web/ 2>/dev/null || true

######## SYSTEM FILES INSTALL (INSTALL MODE ONLY) ########

if [[ "$MODE" == "install" ]]; then
  loginctl enable-linger "$INSTALL_USER"

  echo ""
  echo "Installing SmartFox system files"
  sleep 1

  sudo apt install -y \
    pipewire \
    pipewire-audio-client-libraries \
    wireplumber \
    libspa-0.2-jack \
    pipewire-jack \
    alsa-utils \
    tree

  systemctl --user enable pipewire pipewire-pulse wireplumber
  systemctl --user start pipewire pipewire-pulse wireplumber

  echo "Enabling persistent boot journal"
  sudo mkdir -p /var/log/journal
  sudo sed -i 's/^#\?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
  grep -q '^Storage=' /etc/systemd/journald.conf || echo 'Storage=persistent' | sudo tee -a /etc/systemd/journald.conf
  sudo systemd-tmpfiles --create --prefix /var/log/journal
  sudo systemctl restart systemd-journald
fi

### Disable camera audio with wireplumber
configure_wireplumber_camera_disable() {

  CONF_DIR="/etc/wireplumber/wireplumber.conf.d"
  CONF_FILE="$CONF_DIR/90-disable-camera-audio.conf"

  echo ""
  echo "Checking WirePlumber camera audio disable rule..."

  sudo mkdir -p "$CONF_DIR"

  if [ ! -f "$CONF_FILE" ]; then
    echo "Creating camera audio disable rule..."

    sudo tee "$CONF_FILE" > /dev/null <<'EOF'
monitor.alsa.rules = [
  {
    matches = [
      { device.description = "~.*Camera*" }
      { device.description = "~.*camera*" }
      { device.description = "~.*Webcam*" }
      { device.description = "~.*webcam*" }
    ]
    actions = {
      update-props = {
        device.disabled = true
      }
    }
  }
]
EOF

    echo "Rule created."

    # Restart WirePlumber only if user service is active
    if systemctl --user is-active wireplumber >/dev/null 2>&1; then
      systemctl --user restart wireplumber
      echo "WirePlumber restarted (user service)."
    else
      echo "WirePlumber not active or no user session — will apply on next boot."
    fi

  else
    echo "Camera audio disable rule already exists. Skipping."
  fi
}

if [ "$MODE" = "install" ]; then
  configure_wireplumber_camera_disable
fi

if [ "$MODE" = "update" ]; then
  configure_wireplumber_camera_disable
fi

### Setup host reboot trigger (systemd path unit watches for trigger file)
configure_reboot_trigger() {
  local trigger_dir="/opt/smartfox/triggers"

  echo ""
  echo "Checking SmartFox reboot trigger units..."

  sudo mkdir -p "$trigger_dir"
  sudo rm -f "$trigger_dir/reboot"

  sudo tee /etc/systemd/system/smartfox-reboot.path > /dev/null <<'EOF'
[Unit]
Description=Watch for SmartFox reboot trigger

[Path]
PathExists=/opt/smartfox/triggers/reboot

[Install]
WantedBy=multi-user.target
EOF

  sudo tee /etc/systemd/system/smartfox-reboot.service > /dev/null <<'EOF'
[Unit]
Description=SmartFox host reboot

[Service]
Type=oneshot
ExecStartPre=/bin/rm -f /opt/smartfox/triggers/reboot
ExecStart=/sbin/reboot
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now smartfox-reboot.path
  echo "Reboot trigger units installed."
}

if [ "$MODE" = "install" ]; then
  configure_reboot_trigger
fi

if [ "$MODE" = "update" ]; then
  configure_reboot_trigger
fi

####### SERVICE MONITOR (version-dependent) ########
# The host watchdog ships in the app repo under setup/monitor/ from a certain
# point onward (present on the dev and main branches, absent in v2.2.0 and
# older tags). Install its files only when the checked-out version actually
# provides them — that way a release that includes the watchdog rolls it out
# on the next update with no installer change. Never on a calibration bench:
# with no smartfox-core container the watchdog escalates docker/daemon
# restarts up to a reboot loop.
# The timer is NOT enabled here: it would fire during the down/pull/up window
# against missing containers and can escalate to a docker-daemon restart
# mid-pull. It is enabled/started after `docker compose up` in the deploy step.
# (cwd is the app repo checkout here, so the relative path is the versioned one.)

MONITOR_AVAILABLE=0
if [[ "$CAL_VARIANT" == "1" ]]; then
  echo "Skipping service monitor (calibration variant)"
elif [[ -f setup/monitor/smartfox-svc-monitor.py ]]; then
  echo ""
  echo "Installing Smartfox-Pi Service Monitor files (shipped by $GIT_VERSION)"
  sudo install -m 0755 setup/monitor/smartfox-svc-monitor.py /usr/local/bin/smartfox-svc-monitor.py
  sudo install -m 0644 setup/monitor/smartfox-svc-monitor.service /etc/systemd/system/smartfox-svc-monitor.service
  sudo install -m 0644 setup/monitor/smartfox-svc-monitor.timer /etc/systemd/system/smartfox-svc-monitor.timer
  sudo mkdir -p /var/lib/smartfox-svc-monitor
  sudo systemctl daemon-reload
  MONITOR_AVAILABLE=1
else
  echo "Service monitor not shipped by $GIT_VERSION — skipping"
fi

####### FLEET AGENT (version-dependent) ########
# The fleet update agent ships in the app repo under setup/agent/ (v2.3.0+).
# Like the monitor, install it only when the checked-out version provides it;
# unlike the monitor, also on --cal benches (the agent handles the variant).
# The station's fleet token lives in /etc/smartfox/agent.env (root-only —
# never in /opt/smartfox/.env, which is env_file for every container) and is
# prompted once. cosign (pinned + checksum) lets the agent verify image
# signatures; without it the agent refuses updates that require verification.
# The timer is enabled after `docker compose up`, like the monitor's.

AGENT_AVAILABLE=0
if [[ -f setup/agent/smartfox_agent.py ]]; then
  echo ""
  echo "Installing SmartFox fleet agent files (shipped by $GIT_VERSION)"
  sudo install -m 0755 setup/agent/smartfox_agent.py /usr/local/bin/smartfox_agent.py
  sudo install -m 0644 setup/agent/smartfox-agent.service /etc/systemd/system/smartfox-agent.service
  sudo install -m 0644 setup/agent/smartfox-agent.timer /etc/systemd/system/smartfox-agent.timer
  sudo mkdir -p /etc/smartfox /opt/smartfox/state /opt/smartfox/dist
  sudo chown "$INSTALL_USER:$INSTALL_USER" /opt/smartfox/state /opt/smartfox/dist
  sudo systemctl daemon-reload

  if ! sudo grep -qsE '^FLEET_TOKEN=.+' /etc/smartfox/agent.env; then
    echo ""
    read -s -p "Fleet token (per-station, from the smartfox-fleet inventory; empty = agent stays idle): " FLEET_TOKEN
    echo ""
    if [[ -n "$FLEET_TOKEN" && ! "$FLEET_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "ERROR: fleet token may only contain letters, digits, - and _"
      exit 1
    fi
    printf 'FLEET_URL=%s\nFLEET_TOKEN=%s\n' "$FLEET_URL" "$FLEET_TOKEN" | sudo tee /etc/smartfox/agent.env >/dev/null
    sudo chmod 600 /etc/smartfox/agent.env
    unset FLEET_TOKEN
  else
    echo "Fleet token already present in /etc/smartfox/agent.env (kept)."
  fi

  if ! command -v cosign >/dev/null 2>&1; then
    echo "Installing cosign $COSIGN_VERSION"
    COSIGN_TMP=$(mktemp)
    if curl -fsSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-arm64" -o "$COSIGN_TMP" \
       && echo "${COSIGN_SHA256}  ${COSIGN_TMP}" | sha256sum -c --quiet; then
      sudo install -m 0755 "$COSIGN_TMP" /usr/local/bin/cosign
      sudo cosign initialize >/dev/null 2>&1 || echo "WARNING: cosign initialize failed (no network?); the agent retries at verify time"
    else
      echo "WARNING: cosign download or checksum failed; the agent will refuse updates that require verification until cosign is installed"
    fi
    rm -f "$COSIGN_TMP"
  fi
  AGENT_AVAILABLE=1
else
  echo "Fleet agent not shipped by $GIT_VERSION — skipping"
fi

####### RESET CONFIG (if requested) #######

if [[ "$RESET_CONFIG" == "1" ]]; then
  echo "Resetting config files"
  sudo rm -rf /opt/smartfox/config
  sudo rm -rf /opt/smartfox/web/config
fi

######## CONFIG MANAGEMENT ########

echo "Merging config YAML files (add missing fields only, seed if not present)"
sudo mkdir -p /opt/smartfox/config /opt/smartfox/web/config
sudo cp -f config/paths.yml /opt/smartfox/config/ 2>/dev/null || true

for file in config/*.yml config/*.yaml; do
  [[ -f "$file" ]] || continue

  name=$(basename "$file")
  LIVE="/opt/smartfox/config/$name"
  DEFAULT="$PWD/$file"

  [[ "$name" == "paths.yml" ]] && continue

  if [[ -f "$LIVE" ]]; then
    tmp=$(mktemp)
    yq eval-all '
      select(fileIndex==0) as $live |
      select(fileIndex==1) as $def |
      (
        $def
        | .. style=""
        | select(tag != "!!map" and tag != "!!seq") |= ""
      ) as $blank |
      $live *n $blank
    ' "$LIVE" "$DEFAULT" > "$tmp"
    sudo mv "$tmp" "$LIVE"
  else
    sudo cp "$DEFAULT" "$LIVE"
  fi
done

for file in web/config/*.yml web/config/*.yaml; do
  [[ -f "$file" ]] || continue

  name=$(basename "$file")
  LIVE="/opt/smartfox/web/config/$name"
  DEFAULT="$PWD/$file"

  if [[ -f "$LIVE" ]]; then
    tmp=$(mktemp)
    yq eval-all 'select(fileIndex==0) *+ select(fileIndex==1)' \
      "$LIVE" "$DEFAULT" > "$tmp"
    sudo mv "$tmp" "$LIVE"
  else
    sudo cp "$DEFAULT" "$LIVE"
  fi
done

# Copy non-YAML config files (seed if not present)
for file in config/*.txt; do
  [[ -f "$file" ]] || continue
  name=$(basename "$file")
  LIVE="/opt/smartfox/config/$name"
  [[ -f "$LIVE" ]] || sudo cp "$file" "$LIVE"
done

# Ensure config dirs/files are owned by the install user, not root
sudo chown -R "$INSTALL_USER:$INSTALL_USER" /opt/smartfox/config /opt/smartfox/web/config

####### ENV OPTIONS (RESET / MERGE) #######

ENV_FILE="/opt/smartfox/.env"

if [[ "$RESET_ENV" == "1" ]]; then
  echo "Resetting .env file (destructive)"
  sudo rm -f "$ENV_FILE"
fi

if [[ "$MODE" == "install" ]]; then
  if [ ! -f "$ENV_FILE" ]; then
    echo ""
    echo "Creating environment configuration"
    cp .env.template "$ENV_FILE"

    read -s -p "Ximilar Token: " XIMILAR_TOKEN; echo
    read -s -p "Dropbox Token: " DROPBOX_TOKEN; echo
    read -s -p "Cloudflare Token: " TUNNEL_TOKEN; echo
    read -s -p "API Crypt Key: " CRYPT_KEY; echo
    read -s -p "AudioCTL Token: " AUDIOCTL_TOKEN; echo

    sed -i "s|^XIMILAR_TOKEN=.*|XIMILAR_TOKEN=$XIMILAR_TOKEN|" "$ENV_FILE"
    sed -i "s|^DROPBOX_TOKEN=.*|DROPBOX_TOKEN=$DROPBOX_TOKEN|" "$ENV_FILE"
    sed -i "s|^TUNNEL_TOKEN=.*|TUNNEL_TOKEN=$TUNNEL_TOKEN|" "$ENV_FILE"
    sed -i "s|^CRYPT_KEY=.*|CRYPT_KEY=$CRYPT_KEY|" "$ENV_FILE"
    sed -i "s|^AUDIOCTL_TOKEN=.*|AUDIOCTL_TOKEN=$AUDIOCTL_TOKEN|" "$ENV_FILE"

    chmod 600 "$ENV_FILE"
  fi
else
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: /opt/smartfox/.env not found."
    echo "Run the installer with --install first (or run --install --reset-env if you need to recreate it)."
    exit 1
  fi
fi

if [[ "$MERGE_ENV" == "1" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Cannot merge env because /opt/smartfox/.env does not exist."
    echo "Run --install first."
    exit 1
  fi

  echo "Merging env keys from .env.template (add missing keys only)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *"="* ]] && continue

    key="${line%%=*}"
    key="$(echo "$key" | tr -d ' ')"
    [[ -z "$key" ]] && continue

    if ! grep -qE "^${key}=" "$ENV_FILE"; then
      echo "${key}=" | sudo tee -a "$ENV_FILE" >/dev/null
    fi
  done < .env.template
fi

####### PIN DEPLOYED VERSION FOR COMPOSE #######
# docker compose interpolates ${SMARTFOX_VERSION} from /opt/smartfox/.env when
# the variable is not set in the caller's environment - the same mechanism the
# cloudflared service already relies on for TUNNEL_TOKEN. Recording the deployed
# tag here means the nightly maintenance cron job, and any manual
# `docker compose` call on the device, resolves to the image that is already on
# disk instead of falling back to :latest and pulling it over the station link.
#
# Do NOT add SMARTFOX_VERSION to the app repo's .env.template: --merge-env would
# then seed it on every device.

echo ""
echo "Pinning deployed version in $ENV_FILE (SMARTFOX_VERSION=$DOCKER_VERSION)"
if sudo grep -q '^SMARTFOX_VERSION=' "$ENV_FILE"; then
  sudo sed -i "s|^SMARTFOX_VERSION=.*|SMARTFOX_VERSION=$DOCKER_VERSION|" "$ENV_FILE"
else
  echo "SMARTFOX_VERSION=$DOCKER_VERSION" | sudo tee -a "$ENV_FILE" >/dev/null
fi

####### SET STATION VARIANT (full | cal) #######
# SMARTFOX_VARIANT reaches the web container via compose `env_file: .env`; the
# web app treats anything other than "cal" (including absent/empty) as the full
# UI. The variant of each run is decided by the presence of --cal on THAT run,
# so `--update` without --cal promotes a calibration bench to a full station.
# Do NOT add SMARTFOX_VARIANT to the app repo's .env.template — --merge-env
# would seed it (empty) on every device.

if [[ "$CAL_VARIANT" == "1" ]]; then
  VARIANT_VALUE="cal"
else
  VARIANT_VALUE="full"
fi

echo ""
echo "Setting station variant in $ENV_FILE (SMARTFOX_VARIANT=$VARIANT_VALUE)"
if sudo grep -q '^SMARTFOX_VARIANT=' "$ENV_FILE"; then
  sudo sed -i "s|^SMARTFOX_VARIANT=.*|SMARTFOX_VARIANT=$VARIANT_VALUE|" "$ENV_FILE"
else
  echo "SMARTFOX_VARIANT=$VARIANT_VALUE" | sudo tee -a "$ENV_FILE" >/dev/null
fi

if [[ "$CAL_VARIANT" == "1" ]]; then
  echo "NOTE: the calibration-only UI requires a smartfox image that supports"
  echo "      SMARTFOX_VARIANT. Older images ignore it and show the full UI"
  echo "      (core is still not started either way)."
fi

####### CAL ADMIN TOKEN #######
# Cal slots are public (no Cloudflare Access): the web app gates state-changing
# actions behind SMARTFOX_ADMIN_TOKEN (admin URL /?admin=<token>, REST header
# X-Admin-Token). Prompt only when the key is missing, empty, or a placeholder
# so reruns keep the existing value. Never add this key to the app repo's
# .env.template (--merge-env would seed it empty fleet-wide). Token charset:
# letters, digits, - and _ only (it is substituted with sed and used in a URL).

if [[ "$CAL_VARIANT" == "1" ]]; then
  CURRENT_ADMIN_TOKEN=$(sudo grep -E '^SMARTFOX_ADMIN_TOKEN=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)
  if [[ -z "$CURRENT_ADMIN_TOKEN" || "$CURRENT_ADMIN_TOKEN" == "PLACEHOLDER" ]]; then
    echo ""
    read -s -p "SmartFox Admin Token (letters/digits/-/_ ; enables /?admin=<token> on the bench): " SMARTFOX_ADMIN_TOKEN
    echo ""
    if [[ -z "$SMARTFOX_ADMIN_TOKEN" ]]; then
      echo "WARNING: empty admin token - admin mode will never activate on this bench."
    elif [[ ! "$SMARTFOX_ADMIN_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "ERROR: admin token may only contain letters, digits, - and _"
      exit 1
    fi
    if sudo grep -q '^SMARTFOX_ADMIN_TOKEN=' "$ENV_FILE"; then
      sudo sed -i "s|^SMARTFOX_ADMIN_TOKEN=.*|SMARTFOX_ADMIN_TOKEN=$SMARTFOX_ADMIN_TOKEN|" "$ENV_FILE"
    else
      echo "SMARTFOX_ADMIN_TOKEN=$SMARTFOX_ADMIN_TOKEN" | sudo tee -a "$ENV_FILE" >/dev/null
    fi
    unset SMARTFOX_ADMIN_TOKEN
  else
    echo "Admin token already present in $ENV_FILE (kept)."
  fi
fi

###### CLEAN FILES CRON JOB ######
### IF MORE MODES ARE ADDED, SET A CONDITION TO RUN
# Installed before the deploy on purpose: with `set -e` a slow or failed
# `compose pull` aborts the run, and this job must not be what gets skipped -
# without it the data volume fills up and recording stops.
# The job inherits SMARTFOX_VERSION from /opt/smartfox/.env, so it reuses the
# deployed image instead of pulling :latest.
echo ""
echo "Setting Cleanup (clean_files) Cron Job"
# `--pull never` turns a missing/wrong version pin into a loud failure in the
# log instead of an accidental full-image download over the station link at
# midnight. Compose plugins older than v2.18 lack the flag on `run`; those
# fall back to relying on the pin alone.
if sudo docker compose run --help 2>/dev/null | grep -qE '^\s*--pull '; then
  MAINT_RUN_FLAGS="--rm --pull never"
else
  MAINT_RUN_FLAGS="--rm"
fi
CRON_LINE="0 0 * * * /bin/bash -lc 'install -d -o 1000 -g 1000 /var/lib/smartfox/logs/internal && cd /opt/smartfox && sudo docker compose run $MAINT_RUN_FLAGS maintenance >> /var/lib/smartfox/logs/internal/clean_files.log.\$(date +\%F) 2>&1'"
# Replace-not-append: any existing maintenance line (older canonical form or a
# hand-edited variant) is removed before the standard line is added, so a
# diverged station converges instead of ending up with two jobs at midnight.
# helpers/fix-maintenance-cron.sh applies this same normalization fleet-wide.
CURRENT_CRON="$(sudo crontab -l 2>/dev/null || true)"
DESIRED_CRON="$({ printf '%s\n' "$CURRENT_CRON" | grep -vE 'docker compose run.*maintenance' || true; echo "$CRON_LINE"; } | sed '/^[[:space:]]*$/d')"
if [[ "$(printf '%s\n' "$CURRENT_CRON" | sed '/^[[:space:]]*$/d')" == "$DESIRED_CRON" ]]; then
  echo "Cleanup cron job already present."
elif printf '%s\n' "$DESIRED_CRON" | sudo crontab -; then
  echo "Cleanup cron job installed."
else
  echo "WARNING: could not install the cleanup cron job. Add it with 'sudo crontab -e':"
  echo "  $CRON_LINE"
fi

####### STATE FILES ########
# The recording enable flag (/var/lib/smartfox/.smartfox_enabled) is left in
# place on purpose: start_smartfox.sh resumes the pipeline with the new
# containers (auto-resume — the fleet agent applies the same policy). --cal
# removes it below. .version is the legacy stamp read by images older than
# v2.3.0; newer images read /opt/smartfox/state/state.json.
sudo touch /opt/smartfox/.version

####### GHCR LOGIN #######

echo ""
echo "Logging into GHCR"
printf '%s' "$GH_TOKEN" | sudo docker login ghcr.io -u "$GH_USER" --password-stdin
unset GIT_ASKPASS GH_USER GH_TOKEN

####### VERSION-DOCKER PULL #######

cd /opt/smartfox
export SMARTFOX_VERSION="$DOCKER_VERSION"

echo "Pulling Docker images (SMARTFOX_VERSION=$SMARTFOX_VERSION)"
sudo SMARTFOX_VERSION="$SMARTFOX_VERSION" docker compose pull

if [[ "$CAL_VARIANT" == "1" ]]; then
  echo "Starting SmartFox (calibration variant: web + cloudflared only)"
  # A calibration bench must not run the monitoring pipeline. Enforce that
  # regardless of what ran on this host before:
  # - remove any leftover containers from a previous full deployment
  #   (install mode has no global `down`, and core is restart=unless-stopped),
  # - disarm the recording auto-start flag (this is the real flag name;
  #   start_smartfox.sh starts the pipeline whenever it exists),
  # - disable the host watchdog if a dev-track install left one: with no
  #   smartfox-core container it escalates docker/daemon restarts up to a
  #   reboot loop.
  (sudo SMARTFOX_VERSION="$SMARTFOX_VERSION" docker compose down) || true
  sudo rm -f /var/lib/smartfox/.smartfox_enabled
  sudo systemctl disable --now smartfox-svc-monitor.timer smartfox-svc-monitor.service 2>/dev/null || true
  sudo SMARTFOX_VERSION="$SMARTFOX_VERSION" docker compose up -d web cloudflared
else
  echo "Starting SmartFox"
  sudo SMARTFOX_VERSION="$SMARTFOX_VERSION" docker compose up -d

  # Watchdog goes live only now that the containers exist (see the SERVICE
  # MONITOR block). If this version does not ship it but a previous install
  # left an enabled one, put it back the way the update-mode pre-stop found
  # it (a cal-demoted unit has it disabled and stays that way).
  if [[ "$MONITOR_AVAILABLE" == "1" ]]; then
    echo "Enabling Smartfox-Pi Service Monitor"
    sudo systemctl enable --now smartfox-svc-monitor.timer
  elif systemctl is-enabled smartfox-svc-monitor.timer >/dev/null 2>&1; then
    sudo systemctl start smartfox-svc-monitor.timer 2>/dev/null || true
  fi
fi

####### FLEET AGENT STATE + TIMER #######
if [[ "$AGENT_AVAILABLE" == "1" ]]; then
  printf '{"agent": 1, "deployed": "%s", "last_result": "installer", "applied_at": "%s"}\n' \
    "$DOCKER_VERSION" "$(date -Iseconds)" | sudo tee /opt/smartfox/state/state.json >/dev/null
  sudo chown "$INSTALL_USER:$INSTALL_USER" /opt/smartfox/state/state.json
  # A pause left behind by an interrupted agent apply must not keep the
  # watchdog asleep; a hand-made (empty) pause file is kept.
  if sudo grep -qs '^agent' /var/lib/smartfox-svc-monitor/maintenance; then
    sudo rm -f /var/lib/smartfox-svc-monitor/maintenance
  fi
  echo "Enabling SmartFox fleet agent timer"
  sudo systemctl enable --now smartfox-agent.timer
fi

sudo docker logout ghcr.io

if [[ "$SMARTFOX_VERSION" == "latest" ]]; then
  RESOLVED_VERSION=$(sudo docker inspect ghcr.io/dba-ingenieria/smartfox-core:latest \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo "latest")
else
  RESOLVED_VERSION="$SMARTFOX_VERSION"
fi
echo "$RESOLVED_VERSION" | sudo tee /opt/smartfox/.version >/dev/null

######## END MESSAGE ########

echo ""
echo "/// Completed ///"
echo "Mode: $MODE"
echo "Variant: $VARIANT_VALUE"
echo "Deployed version: $RESOLVED_VERSION"
echo "Pinned image tag: $DOCKER_VERSION (SMARTFOX_VERSION in /opt/smartfox/.env)"
if [[ "$AGENT_AVAILABLE" == "1" ]]; then
  echo "Fleet agent: enabled (state in /opt/smartfox/state/state.json; further updates are applied by the agent)"
fi
echo "If this was a fresh install, please reboot the system."
