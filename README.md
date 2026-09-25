# Smartfox-Pi Installer

This installer manages the deployment and update lifecycle of Smartfox-Pi software using Docker.

It supports first-time installation, safe updates, configuration merging, environment management, version selection, and scheduled maintenance setup.

## Download installer

To download this installer into the device run the following command line:

`curl -O https://raw.githubusercontent.com/dba-ingenieria/smartfox-installer/main/installer.sh`

### Download helper tools

To download helper tools such as disable-camera-mic (for Debian 12 Bookworm devices), run the following command line:

`curl -O https://raw.githubusercontent.com/dba-ingenieria/smartfox-installer/main/helpers/disable-camera-mic.sh`

#### fix-maintenance-cron

Standardizes the nightly `clean_files` maintenance cron job on an already-installed station. Use it on any station whose cron line was hand-edited, is missing, or fails with `No such image: ...smartfox-core:latest` in `clean_files.log`. It detects the version already deployed on the device (core container → web container → `.env` pin → local images), pins `SMARTFOX_VERSION` in `/opt/smartfox/.env` to it, replaces every existing maintenance cron line with the standard one, and verifies the job resolves to an image on disk. It never pulls an image and never restarts anything, so it is safe on a recording station.

`curl -O https://raw.githubusercontent.com/dba-ingenieria/smartfox-installer/main/helpers/fix-maintenance-cron.sh`

`bash fix-maintenance-cron.sh` — fix pin + cron, then verify

`bash fix-maintenance-cron.sh --run-now` — additionally run the cleanup once immediately and show the log tail

> **Note:** `installer.sh` is the single installer for **all** tracks (release tags, `dev`, `latest`, and `--cal` benches). The former `installer-dev.sh` is deprecated and only prints an error: the host service monitor (watchdog) it used to add is now installed automatically whenever the selected version ships it (`setup/monitor/` exists on `dev` and `main`, but not in `v2.2.0` or older tags), and is never installed on `--cal` benches.

> **Fleet agent (v3.0.0+).** When the selected version ships `setup/agent/`, the installer also installs the fleet update agent, its systemd timer and `cosign`, and prompts once for the station's **fleet token** (written to `/etc/smartfox/agent.env`, root-only; an empty token leaves the agent idle). From then on the station updates itself from the fleet manifest inside its maintenance window and rolls back on failure — this script becomes the one-time bootstrap / last manual update. **Recording resumes on its own after an update**: the enable flag is no longer removed by `--update` (only `--cal` removes it). Tokens and rollout commands live in the private `smartfox-fleet` repo.

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

- `--cal`: Provisions a **calibration bench** unit (e.g. for calibration at the ISP). The host is fully provisioned exactly like a production station and **both** images are pulled at the pinned version, but only the `web` and `cloudflared` containers are started, and the web UI hides the service-configuration and service-status menus while reducing "Configuración general de la estación" to the station-ID and Modelo fields — an admin sets them per unit and they are stamped into each calibration report (the ID also names the download file). Because cal benches are reachable on **public hostnames without Cloudflare Access**, cal mode enforces an Admin/User split server-side: anonymous users can only measure, save the calibration factor, download the report, and select the recording device; everything else requires the admin token below.

The variant of the station is decided by the presence of `--cal` on **each** installer run:

| Invocation | Result |
|---|---|
| `--install --cal --version=vX.Y.Z` | Fresh calibration bench |
| `--update --cal --version=vX.Y.Z` | Update a bench unit, staying in calibration mode |
| `--update --version=vX.Y.Z` (no `--cal`) | **Promote a bench to production**: full UI, all services started |
| `--update --cal` on a production station | Demote to calibration mode: removes all pipeline containers, deletes the recording auto-start flag, and disables the host watchdog if one was installed |

Notes:

- The flag writes `SMARTFOX_VARIANT=cal` (or `full`) into `/opt/smartfox/.env`. Never add this key to the app repo's `.env.template`.
- `--cal` also prompts for `SMARTFOX_ADMIN_TOKEN` when the key is missing, empty, or `PLACEHOLDER` (reruns keep the existing value; promotion leaves it in place — the full variant ignores it). Charset: letters, digits, `-` and `_` only. Admin mode is activated at `https://calNN.smartfoxconfig.ai/?admin=<token>`; REST admin calls send the `X-Admin-Token: <token>` header. An empty token means admin mode can never activate on that bench. Never add this key to `.env.template` either.
- The calibration factor saved during the cal stage (`/opt/smartfox/config/cal_factor.txt`) **survives promotion automatically** — `config/*.txt` files are only seeded when absent.
- The calibration-only UI requires a Smartfox image that supports `SMARTFOX_VARIANT` (first release: _fill in tag when released_). Older images ignore the flag and show the full UI; `core` is still not started either way. To check whether a deployed image supports it: `GET /api/status/version` returns a `"variant"` field on supporting images.
- On a cal install, only `TUNNEL_TOKEN` is functionally required among the secret prompts (the web UI is reached through the Cloudflare tunnel). Placeholder values are acceptable for `XIMILAR_TOKEN` and `DROPBOX_TOKEN`; set the real values in `/opt/smartfox/.env` before promoting to production — `--update` never rewrites existing values.
- Never install the host service monitor (watchdog) on a cal unit: with no `core` container it escalates restarts up to a reboot loop.
- If you run Compose by hand on a cal unit, always name the services: `sudo docker compose up -d web cloudflared`.

### Cal slot (Cloudflare) runbook

Cal benches are published at generic slots `cal01.smartfoxconfig.ai`, `cal02…`, reusable for any bench unit:

1. Create the tunnel (`cloudflared tunnel create calNN` or via the Zero Trust dashboard) and route the DNS hostname `calNN.smartfoxconfig.ai` to it, pointing at `http://web:8000`.
2. **Do NOT create a Cloudflare Access application for the hostname.** The slot is public by design (the ISP operator has no credentials); the web app enforces the admin split server-side.
3. Put the tunnel's token into the bench's `/opt/smartfox/.env` as `TUNNEL_TOKEN` (the installer prompts for it on `--install`).
4. **Warning: never point a public cal slot at a full (non-cal) station.** The server-side hardening only activates with `SMARTFOX_VARIANT=cal`; a full station on a no-Access hostname exposes unauthenticated config writes and reboot.
5. Admin usage: `https://calNN.smartfoxconfig.ai/?admin=<SMARTFOX_ADMIN_TOKEN>` in the browser, or `X-Admin-Token: <token>` for REST. Rotate the token by editing `/opt/smartfox/.env` and running `sudo docker compose up -d web`.

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
