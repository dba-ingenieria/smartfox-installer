#!/bin/bash
set -e

########### MODE + VERSION PARSER

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

########### START

echo "/// SmartFox Installer ///"
sleep 1

INSTALL_USER=$(logname)
INSTALL_HOME=$(eval echo "~$INSTALL_USER")

echo "Installing for user: $INSTALL_USER"
sleep 1

######### GITHUB AUTH (ONE TOKEN FOR CLONE + GHCR)

if [[ -z "${GH_USER:-}" ]]; then
  read -p "GitHub Username: " GH_USER
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
  read -s -p "GitHub Token: " GH_TOKEN
  echo ""
fi

######### DOCKER INSTALL

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

##### GIT INSTALL


if ! command -v git >/dev/null; then
  echo ""
  echo "Installing Git"
  sudo apt-get install -y git
  if ! command -v yq >/dev/null; then
    echo "Installing yq"
    sudo curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64 -o /usr/local/bin/yq
    sudo chmod +x /usr/local/bin/yq
  fi
fi

###### REINSTALL LOGIC

if [[ "$MODE" == "reinstall" ]]; then
  echo "Reinstall mode: stopping containers"
  if [[ -f /opt/smartfox/docker-compose.yml ]]; then
    (cd /opt/smartfox && sudo docker compose down) || true
  fi
  sudo rm -rf /opt/smartfox
fi

###### CLONE REPO

##### NEW BLOCK: GIT_ASKPASS helper (prevents git prompting twice)
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
  GIT_ASKPASS="$ASKPASS" GH_USER="$GH_USER" GH_TOKEN="$GH_TOKEN" \
    git -c core.askPass="$ASKPASS" -c credential.helper= clone https://github.com/dba-ingenieria/smartfox.git
  cd smartfox
else
  cd smartfox
  GIT_ASKPASS="$ASKPASS" GH_USER="$GH_USER" GH_TOKEN="$GH_TOKEN" \
    git -c core.askPass="$ASKPASS" -c credential.helper= fetch
fi

git checkout "$SMARTFOX_VERSION" || true

###### YAML MERGE (ADD MISSING FIELDS ONLY)

if [[ "$MODE" == "upgrade" ]]; then
  echo "Merging config YAML files (add missing fields only)"

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

######## SYSTEM FILES INSTALL

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

####### SYSTEM DIRECTORIES

sudo mkdir -p /opt/smartfox /var/lib/smartfox
sudo chown -R "$INSTALL_USER:$INSTALL_USER" /opt/smartfox /var/lib/smartfox
mkdir -p /opt/smartfox/web

######## COPY RUNTIME ARTIFACTS

cp docker-compose.yml /opt/smartfox/
cp -r web/programs /opt/smartfox/web/ 2>/dev/null || true
if [[ "$MODE" == "install" || "$MODE" == "reinstall" ]]; then
  cp -r config /opt/smartfox/ 2>/dev/null || true
  cp -r web/config /opt/smartfox/web/ 2>/dev/null || true
fi

####### ENV RESET OPTION


if [[ "$RESET_ENV" == "1" ]]; then
  echo "Resetting .env file"
  sudo rm -f /opt/smartfox/.env
fi

####### ENV CREATION

ENV_FILE="/opt/smartfox/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo ""
  echo "Creating environment configuration"
  echo "Inputs are hidden for security"
  cp .env.template "$ENV_FILE"

  read -s -p "Cloudflare Token (e.g. eYJh...): " TUNNEL_TOKEN
  echo
  sed -i "s|^TUNNEL_TOKEN=.*|TUNNEL_TOKEN=$TUNNEL_TOKEN|" "$ENV_FILE"

  if grep -q "^XIMILAR_TOKEN=PLACEHOLDER" "$ENV_FILE"; then
    read -s -p "Ximilar Token: " XIMILAR_TOKEN; echo
    sed -i "s|^XIMILAR_TOKEN=.*|XIMILAR_TOKEN=$XIMILAR_TOKEN|" "$ENV_FILE"
  fi

  if grep -q "^DROPBOX_TOKEN=PLACEHOLDER" "$ENV_FILE"; then
    read -s -p "Dropbox Token: " DROPBOX_TOKEN; echo
    sed -i "s|^DROPBOX_TOKEN=.*|DROPBOX_TOKEN=$DROPBOX_TOKEN|" "$ENV_FILE"
  fi

  if grep -q "^CRYPT_KEY=PLACEHOLDER" "$ENV_FILE"; then
    read -s -p "API Crypt Key: " CRYPT_KEY; echo
    sed -i "s|^CRYPT_KEY=.*|CRYPT_KEY=$CRYPT_KEY|" "$ENV_FILE"
  fi

  if grep -q "^AUDIOCTL_TOKEN=PLACEHOLDER" "$ENV_FILE"; then
    read -s -p "AudioCTL Token: " AUDIOCTL_TOKEN; echo
    sed -i "s|^AUDIOCTL_TOKEN=.*|AUDIOCTL_TOKEN=$AUDIOCTL_TOKEN|" "$ENV_FILE"
  fi

  chmod 600 "$ENV_FILE"
fi

####### GHCR LOGIN

echo ""
echo "Logging into GHCR"
echo "$GH_TOKEN" | sudo docker login ghcr.io -u "$GH_USER" --password-stdin

unset GH_TOKEN

####### VERSION-DOCKER PULL

cd /opt/smartfox

export SMARTFOX_VERSION

echo "Pulling Docker images"
sudo SMARTFOX_VERSION="$SMARTFOX_VERSION" docker compose pull

echo "Starting SmartFox"
sudo SMARTFOX_VERSION="$SMARTFOX_VERSION" docker compose up -d

######## END MESSAGE

echo ""
echo "/// Installation Complete ///"
echo "Please reboot the system."
