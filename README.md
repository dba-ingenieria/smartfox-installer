# Smartfox-Pi Installer

This installer manages the deployment and update lifecycle of Smartfox-Pi software using Docker.

It supports first-time installation, safe updates, configuration merging, environment management, version selection, and scheduled maintenance setup.

## Download installer

To download this installer into the device run the following command line:

`curl -O https://raw.githubusercontent.com/dba-ingenieria/smartfox-installer/main/installer.sh`

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

* Update and merge new environment variables:

`bash installer.sh --update --version=v2.0.0-beta.6 --merge-env`

* Recreate environment during installation:

`bash installer.sh --install --reset-env --version=v2.0.0-beta.6`

## Summary

This installer provides a safe and predictable way to deploy and maintain Smartfox-Pi.

* Controlled installation

* Safe updates

* Version management

* Configuration preservation

* Environment management

* Automated maintenance
