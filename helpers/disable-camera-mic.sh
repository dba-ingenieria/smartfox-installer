### Disable camera audio with wireplumber
configure_wireplumber_camera_disable() {

  CONF_DIR="/etc/wireplumber/wireplumber.conf.d"
  CONF_FILE="$CONF_DIR/90-disable-camera-audio.conf"

  sudo mkdir -p "$CONF_DIR"

  if [ ! -f "$CONF_FILE" ]; then
    echo "Creating camera audio disable rule..."

    sudo tee "$CONF_FILE" > /dev/null <<'EOF'
monitor.alsa.rules = [
  {
    matches = [
      { device.description = "~.*HD USB Camera*" }
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

configure_wireplumber_camera_disable
