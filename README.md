# Smartfox-Pi Installer

This installer manages the deployment and update lifecycle of Smartfox-Pi software using Docker.

It supports first-time installation, safe updates, configuration merging, environment management, version selection, and scheduled maintenance setup.

## Download installer

To download this installer into the device run the following command line:

`curl -O https://raw.githubusercontent.com/dba-ingenieria/smartfox-installer/main/installer.sh`

### Download helper tools

To download helper tools such as disable-camera-mic (for Debian 12 Bookworm devices), run the following command line:

`curl -O https://raw.githubusercontent.com/dba-ingenieria/smartfox-installer/main/helpers/disable-camera-mic.sh`

## Modes

The installer provides two modes:

- `--install`: Initial system setup and deployment. Performs a full system bootstrap and deploys Smartfox-Pi. Use this for first-time installation or to fresh install the software.

- `--update`: Safe update and redeployment of an existing installation. Use this for safely updates or redeploys Smartfox-Pi.

### Version flag 

The installer supports explicit version deployment. Accepted formats:

- `--version=latest`

- `--version=v2.0.0-beta.6`

- `--version=2.0.0-beta.6`

If no `--version` flag is provided, the latest version will be installed by default.

> The deployed version is stored in: `/opt/smartfox/.version`

### Variant flag (calibration bench)

- `--cal`: Provisions a **calibration bench** unit (e.g. for calibration at the ISP). The host is fully provisioned exactly like a production station and **both** images are pulled at the pinned version, but only the `web` and `cloudflared` containers are started, and the web UI hides the station-operation menus ("Configuración general de la estación", "Configuración de servicios", "Estado de los servicios"), leaving only the calibration workflow.

The variant of the station is decided by the presence of `--cal` on **each** installer run:

| Invocation | Result |
|---|---|
| `--install --cal --version=vX.Y.Z` | Fresh calibration bench |
| `--update --cal --version=vX.Y.Z` | Update a bench unit, staying in calibration mode |
| `--update --version=vX.Y.Z` (no `--cal`) | **Promote a bench to production**: full UI, all services started |
| `--update --cal` on a production station | Demote to calibration mode (stops the monitoring pipeline) |

Notes:

- The flag writes `SMARTFOX_VARIANT=cal` (or `full`) into `/opt/smartfox/.env`. Never add this key to the app repo's `.env.template`.
- The calibration factor saved during the cal stage (`/opt/smartfox/config/cal_factor.txt`) **survives promotion automatically** — `config/*.txt` files are only seeded when absent.
- The calibration-only UI requires a Smartfox image that supports `SMARTFOX_VARIANT` (first release: _fill in tag when released_). Older images ignore the flag and show the full UI; `core` is still not started either way.
- On a cal install, only `TUNNEL_TOKEN` is functionally required among the secret prompts (the web UI is reached through the Cloudflare tunnel). Placeholder values are acceptable for `XIMILAR_TOKEN` and `DROPBOX_TOKEN`; set the real values in `/opt/smartfox/.env` before promoting to production — `--update` never rewrites existing values.
- Never install the host service monitor (watchdog) on a cal unit: with no `core` container it escalates restarts up to a reboot loop.
- If you run Compose by hand on a cal unit, always name the services: `sudo docker compose up -d web cloudflared`.

### Config Flags

- `--reset-config`: Deletes all configured configs before redeployment. Use when you need to discard local config changes and restore a clean baseline. **Destructive — all local config edits will be lost.**

> If omitted, config files are always updated by merging (adding missing fields only, never overwriting existing values).

### Environment Flags (USE WITH CAUTION)
- `--merge-env`: Adds missing keys from .env.template into the existing /opt/smartfox/.env. Does not overwrite existing values. Useful when new environment variables are introduced in a release.

- `--reset-env`: Deletes /opt/smartfox/.env. In `--install`, it will be recreated interactively. In `--update`, the installer will exit and instruct you to run `--install`.

## Examples of usage

* First install:

 `bash installer.sh --install`

* Install a specific version:

`bash installer.sh --install --version=v2.0.0-beta.6`

* Update to a specific version:

`bash installer.sh --update --version=v2.0.0-beta.6`

* Reset config files to release defaults:

`bash installer.sh --update --version=v2.0.0-beta.6 --reset-config`

* Update and merge new environment variables:

`bash installer.sh --update --version=v2.0.0-beta.6 --merge-env`

* Recreate environment during installation:

`bash installer.sh --install --reset-env --version=v2.0.0-beta.6`

* Install a calibration bench:

`bash installer.sh --install --cal --version=v2.0.0-beta.6`

* Update a calibration bench (staying in calibration mode):

`bash installer.sh --update --cal --version=v2.0.0-beta.6`

* Promote a calibration bench to production:

`bash installer.sh --update --version=v2.0.0-beta.6`

## Summary

This installer provides a safe and predictable way to deploy and maintain Smartfox-Pi.

* Controlled installation

* Safe updates

* Version management

* Configuration preservation

* Environment management

* Automated maintenance
