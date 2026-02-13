#!/bin/bash
set -e

############################################################
### NEW BLOCK: MODE + VERSION PARSER
############################################################

MODE="install"
RESET_ENV=0
SMARTFOX_VERSION="latest"

for arg in "$@"; do
  case "$arg" in
    --install) MODE="install" ;;
    --reinstall) MODE="reinstall" ;;
    --update) MODE="update" ;;
    --upgrade) MODE="upgrade" ;;
    --reset-env) RESET_ENV=1 ;;
    --version=*)
      SMARTFOX_VERSION="${arg#*=}"
      ;;
    *)
      ;;
  esac
done

echo "Mode: $MODE"
echo "Version: $SMARTFOX_VERSION"

############################################################
### ORIGINAL BLOCK: START
############################################################

echo "/// SmartFox Installer ///"
sleep 1

INSTALL_USER=$(logname)
INSTALL_HOME=$(eval echo "~$INSTALL_USER")

echo "Installing for user: $INSTALL_USER"
sleep 1

############################################################
### NEW BLOCK: GITHUB AUTH (ONE TOKEN FOR CLONE + GHCR)
############################################################

read -p "GitHub Username: " GH_USER
read -s -p "GitHub Token (repo + read:packages): " GH_TOKEN
echo ""

############################################################
### ORIGINAL BLOCK: DOCKER INSTALL
############################################################

echo "Removing cache packages"
sudo apt remove -y docker.io docker-compose docker-doc podman-docker containerd runc || true
sudo apt update
sudo apt -y install ca-certificates curl

echo ""
echo "Installing Docker"
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

############################################################
### ORIGINAL BLOCK: GIT INSTALL
############################################################

if ! command -v git >/dev/null; then
  echo ""
  echo "Installing Git"
  sudo apt-get install -y git
fi

############################################################
### NEW BLOCK: REINSTALL LOGIC
############################################################

if [[ "$MODE" == "reinstall" ]]; then
  echo "Reinstall mode: stopping containers"
  if [[ -f /opt/smartfox/docker-compose.yml ]]; then
    (cd /opt/smartfox && sudo docker compose down) || true
  fi
  sudo rm -rf /opt/smartfox
fi

############################################################
### ORIGINAL BLOCK: CLONE REPO
### MODIFIED to support private repo + version
############################################################

cd "$INSTALL_HOME"

if [ ! -d smartfox ]; then
  echo ""
  echo "Cloning SmartFox repository"
  git clone "https://${GH_TOKEN}@github.com/rafaelphayde/smartfox.git"
  cd smartfox
  git remote set-url origin https://github.com/rafaelphayde/smartfox.git
else
  cd smartfox
  git fetch
fi

git checkout "$SMARTFOX_VERSION" || true

############################################################
### NEW BLOCK: YAML MERGE (ADD MISSING FIELDS ONLY)
############################################################

if [[ "$MODE" == "upgrade" ]]; then
  echo "Merging config YAML files (add missing fields only)"

  # Merge main config directory
  for file in config/*.yml config/*.yaml; do
    [[ -f "$file" ]] || continue

    name=$(basename "$file")
    LIVE="/opt/smartfox/config/$name"
    DEFAULT="$PWD/$file"

    if [[ -f "$LIVE" ]]; then
      tmp=$(mktemp)
      # LIVE wins, DEFAULT only fills missing keys
      yq eval-all 'select(fileIndex==0) *+ select(fileIndex==1)' \
        "$LIVE" "$DEFAULT" > "$tmp"
      sudo mv "$tmp" "$LIVE"
    else
      # If file doesn't exist yet, copy it
      sudo cp "$DEFAULT" "$LIVE"
    fi
  done

  # Merge web config directory
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

############################################################
### ORIGINAL BLOCK: SYSTEM FILES INSTALL
############################################################

loginctl enable-linger "$INSTALL_USER"

echo ""
echo "Installing SmartFox system files"

sudo apt install -y \
  pipewire \
  pipewire-audio-client-libraries \
  wireplumber \
  libspa-0.2-jack \
  pipewire-jack \
  alsa-utils

if ! command -v yq >/dev/null; then
  echo "Installing yq"
  sudo curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64 -o /usr/local/bin/yq
  sudo chmod +x /usr/local/bin/yq
fi

systemctl --user enable pipewire pipewire-pulse wireplumber
systemctl --user start pipewire pipewire-pulse wireplumber

############################################################
### ORIGINAL BLOCK: SYSTEM DIRECTORIES
############################################################

sudo mkdir -p /opt/smartfox /var/lib/smartfox
sudo chown -R "$INSTALL_USER:$INSTALL_USER" /opt/smartfox /var/lib/smartfox
mkdir -p /opt/smartfox/web

############################################################
### ORIGINAL BLOCK: COPY RUNTIME ARTIFACTS
############################################################

cp docker-compose.yml /opt/smartfox/
cp -r config /opt/smartfox/ 2>/dev/null || true
cp -r web/config /opt/smartfox/web/ 2>/dev/null || true
cp -r web/programs /opt/smartfox/web/ 2>/dev/null || true

############################################################
### NEW BLOCK: ENV RESET OPTION
############################################################

if [[ "$RESET_ENV" == "1" ]]; then
  echo "Resetting .env file"
  sudo rm -f /opt/smartfox/.env
fi

############################################################
### ORIGINAL BLOCK: ENV CREATION
############################################################

ENV_FILE="/opt/smartfox/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo ""
  echo "Creating environment configuration"
  cp .env.template "$ENV_FILE"

  read -s -p "Ximilar Token: " XIMILAR_TOKEN; echo
  read -s -p "Dropbox Token: " DROPBOX_TOKEN; echo
  read -s -p "Cloudflare Token: " TUNNEL_TOKEN; echo
  read -s -p "API Crypt Key: " CRYPT_KEY; echo
  read -s -p "AUDIOCTL_TOKEN: " AUDIOCTL_TOKEN; echo

  sed -i "s|^XIMILAR_TOKEN=.*|XIMILAR_TOKEN=$XIMILAR_TOKEN|" "$ENV_FILE"
  sed -i "s|^DROPBOX_TOKEN=.*|DROPBOX_TOKEN=$DROPBOX_TOKEN|" "$ENV_FILE"
  sed -i "s|^TUNNEL_TOKEN=.*|TUNNEL_TOKEN=$TUNNEL_TOKEN|" "$ENV_FILE"
  sed -i "s|^CRYPT_KEY=.*|CRYPT_KEY=$CRYPT_KEY|" "$ENV_FILE"
  sed -i "s|^AUDIOCTL_TOKEN=.*|AUDIOCTL_TOKEN=$AUDIOCTL_TOKEN|" "$ENV_FILE"

  chmod 600 "$ENV_FILE"
fi

############################################################
### NEW BLOCK: GHCR LOGIN (SINGLE TOKEN)
############################################################

echo ""
echo "Logging into GHCR"
echo "$GH_TOKEN" | sudo docker login ghcr.io -u "$GH_USER" --password-stdin

unset GH_TOKEN

############################################################
### NEW BLOCK: VERSION-AWARE DOCKER PULL
############################################################

cd /opt/smartfox

export SMARTFOX_VERSION

echo "Pulling Docker images"
sudo SMARTFOX_VERSION="$SMARTFOX_VERSION" docker compose pull

echo "Starting SmartFox"
sudo SMARTFOX_VERSION="$SMARTFOX_VERSION" docker compose up -d

############################################################
### ORIGINAL BLOCK: END MESSAGE
############################################################

echo ""
echo "/// Installation Complete ///"
echo "Please reboot the system."
