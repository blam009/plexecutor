# `plexecutor`

Systemd service that starts a plex docker container via docker compose

## Prerequisites

* `docker`. See: <https://docs.docker.com/desktop/install/linux-install/>
* `sponge`
* `yq`

## Install

```text
./setup.sh [OPTIONS]
```

> Run `./setup.sh --help` for all available install `OPTIONS`.

## Start the service

```shell
sudo sytemctl start plexecutor
```
