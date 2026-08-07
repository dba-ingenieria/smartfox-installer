#!/bin/bash
############################################
# DEPRECATED — use installer.sh for every track.
#
# The two installers were merged on 2026-08-06. installer.sh now detects
# whether the checked-out app version ships the host service monitor
# (setup/monitor/) and installs it only then — present on dev and main,
# absent in v2.2.0 and older tags — so a separate dev installer is no
# longer needed and only drifts.
#
# Equivalent commands:
#   bash installer.sh --install --version=dev
#   bash installer.sh --update  --version=dev
############################################

echo "ERROR: installer-dev.sh is deprecated. Use installer.sh for all tracks:" >&2
echo "  bash installer.sh --install --version=dev" >&2
echo "  bash installer.sh --update  --version=dev" >&2
echo "The service monitor is now installed automatically when the selected" >&2
echo "version ships it (dev/main: yes; v2.2.0 and older tags: no)." >&2
exit 1
