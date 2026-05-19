### Disable camera audio with wireplumber
configure_wireplumber_camera_disable() {

  CONF_DIR="/etc/wireplumber/main.lua.d"
  CONF_FILE="$CONF_DIR/90-disable-camera-audio.lua"

  sudo mkdir -p "$CONF_DIR"

  if [ ! -f "$CONF_FILE" ]; then
    echo "Creating camera audio disable rule"
  else
    echo "Camera audio disable rule already exists. Removing and installing the new one"
  fi
  
  sudo tee "$CONF_FILE" > /dev/null <<'EOF'
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "device.description", "matches", "*HD USB Camera*" },
    },
  },
  apply_properties = {
    ["device.disabled"] = true,
  },
})
EOF

  echo "Rule created."

    # Restart WirePlumber only if user service is active
  if systemctl --user is-active wireplumber >/dev/null 2>&1; then
    systemctl --user restart wireplumber
    echo "WirePlumber restarted (user service)."
  else
    echo "WirePlumber not active or no user session — will apply on next boot."
  fi
}

configure_wireplumber_camera_disable
