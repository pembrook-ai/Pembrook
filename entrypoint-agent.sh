#!/bin/sh
# entrypoint-agent.sh — fix Docker socket permissions then drop to pembrook.
#
# The Docker socket (/var/run/docker.sock) is bind-mounted from the host with
# group=root (GID 0).  To let the non-root pembrook user (GID 1001) access the
# socket we change its group ownership at startup (runs briefly as root via
# the ENTRYPOINT then exec's as pembrook).

if [ -S /var/run/docker.sock ]; then
  chgrp pembrook /var/run/docker.sock
fi

exec gosu pembrook /usr/local/bin/pembrook-agent "$@"
