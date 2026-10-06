#!/bin/sh
# one command of the CLI in a fresh container: the keyring is unlocked first, the session is on the volume
exec sudo podman run --rm -v ${PTHOME:-/srv/protontest/home}:/home/app -v /srv/protontest/data:/data -v ${PTBIN:-/home/lab/proton-drive}:/usr/local/bin/proton-drive:ro -v /home/lab/ptest/run.sh:/run.sh:ro localhost/proton-test dbus-run-session -- /run.sh "$@"
