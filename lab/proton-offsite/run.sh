#!/bin/sh
# runs inside the container: a headless Secret Service for the CLI, then the CLI
export HOME=/home/app
mkdir -p $HOME/.local/share/keyrings
echo -n 'lab-keyring-pass' | gnome-keyring-daemon --unlock --daemonize --components=secrets >/dev/null 2>&1
exec proton-drive "$@"
