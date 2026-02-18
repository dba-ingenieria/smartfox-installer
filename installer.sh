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
# Version:
#   --version=latest (default) or --version=v2.0.0-beta.3 or --version=2.0.0-beta.3
############################################

########### MODE + VERSION PARSER ###########

MODE="install"
RESET_ENV=0
MERGE_ENV=0
SMARTFOX_VERSION="latest"

for arg in "$@"; do
  case "$arg" in
    --install) MODE="install" ;;
    --update) MODE="update" ;;
    --reset-env) RESET_ENV=1 ;;
    --merge-env) MERGE_ENV=1 ;;
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
echo "Flags: reset-env=$RESET_ENV merge-env=$MERGE_ENV"

# Keep your version parsing behavior
GIT_VERSION="$SMARTFOX_VERSION"
DOCKER_VERSION="$SMARTFOX_VERSION"

if [[ "$GIT_VERSION" != "latest" && "$GIT_VERSION" != v* ]]; then
  GIT_VERSION="v${GIT_VERSION}"
fi

if [[ "$DOCKER_VERSION" == v* ]]; then
  DOCKER_VERSION="${DOCKER_VERSION#v}"
fi

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

###### UPDATE LOGIC (safe like reinstall: stop containers first) ######

if [[ "$MODE" == "update" ]]; then
  echo "Update mode: stopping containers"
  if [[ -f /opt/smartfox/docker-compose.yml ]]; then
    (cd /opt/smartfox && sudo docker compose down) || true
    (cd /var/lib/smartfox && rm -f .monitor_enabled) || true
  fi
fi

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
trap 'rm -f "$ASKPASS"' EXIT

cd "$INSTALL_HOME"

if [ ! -d smartfox ]; then
  echo ""
  echo "Cloning SmartFox repository"
  sleep 1
  GIT_ASKPASS="$ASKPASS" GH_USER="$GH_USER" GH_TOKEN="$GH_TOKEN" \
    git -c core.askPass="$ASKPASS" -c credential.helper= clone https://github.com/dba-ingenieria/smartfox.git
  cd smartfox
  git fetch --tags --force --prune
else
  cd smartfox
  GIT_ASKPASS="$ASKPASS" GH_USER="$GH_USER" GH_TOKEN="$GH_TOKEN" \
    git -c core.askPass="$ASKPASS" -c credential.helper= fetch --tags --force --prune
fi

if [[ "$SMARTFOX_VERSION" != "latest" ]]; then
  git tag -l | grep -F "$GIT_VERSION" || true
  git rev-parse "$GIT_VERSION" || true
  git checkout "$GIT_VERSION"
else
  git checkout main
  git pull
fi

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
    alsa-utils

  systemctl --user enable pipewire pipewire-pulse wireplumber
  systemctl --user start pipewire pipewire-pulse wireplumber
fi

####### SYSTEM DIRECTORIES (ALL MODES) #######

sudo mkdir -p /opt/smartfox /var/lib/smartfox
sudo chown -R "$INSTALL_USER:$INSTALL_USER" /opt/smartfox /var/lib/smartfox
mkdir -p /opt/smartfox/web

######## COPY RUNTIME ARTIFACTS (ALL MODES) ########

cp docker-compose.yml /opt/smartfox/
cp -r web/programs /opt/smartfox/web/ 2>/dev/null || true

######## CONFIG MANAGEMENT ########

if [[ "$MODE" == "install" ]]; then
  # Seed initial defaults
  cp -r config /opt/smartfox/ 2>/dev/null || true
  cp -r web/config /opt/smartfox/web/ 2>/dev/null || true
else
  echo "Merging config YAML files (add missing fields only)"
  sudo mkdir -p /opt/smartfox/config /opt/smartfox/web/config

  for file in config/*.yml config/*.yaml; do
    [[ -f "$file" ]] || continue

    name=$(basename "$file")
    LIVE="/opt/smartfox/config/$name"
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
fi

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

####### GHCR LOGIN #######

echo ""
echo "Logging into GHCR"
printf '%s' "$GH_TOKEN" | sudo docker login ghcr.io -u "$GH_USER" --password-stdin
unset GH_TOKEN

####### VERSION-DOCKER PULL #######

cd /opt/smartfox
export SMARTFOX_VERSION="$DOCKER_VERSION"

echo "Pulling Docker images (SMARTFOX_VERSION=$SMARTFOX_VERSION)"
sudo SMARTFOX_VERSION="$SMARTFOX_VERSION" docker compose pull

echo "Starting SmartFox"
sudo SMARTFOX_VERSION="$SMARTFOX_VERSION" docker compose up -d


###### CLEAN FILES CRON JOB
if [[ "$MODE" == "install" ]]; then
  echo ""
  echo "Setting Cleanup (clean_files) Cron Job"

  CRON_CMD="0 0 * * * /bin/bash -c 'cd /opt/smartfox && docker compose run --rm maintenance >> /var/lib/smartfox/logs/internal/clean_files.log.\$(date +\%F) 2>&1'"

  ( sudo crontab -l 2>/dev/null | grep -F "docker compose run --rm maintenance" ) >/dev/null || \
  ( sudo crontab -l 2>/dev/null; echo "$CRON_CMD" ) | sudo crontab -
fi

######## END MESSAGE ########

echo "$SMARTFOX_VERSION" | sudo tee /opt/smartfox/.version >/dev/null
echo ""
echo "/// Completed ///"
echo "Mode: $MODE"
echo "Deployed version: $SMARTFOX_VERSION"
echo "If this was a fresh install, please reboot the system."
