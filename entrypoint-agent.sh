#!/bin/sh
# entrypoint-agent.sh — drop privileges then run the agent.
#
# SEC-003: The agent no longer has direct Docker socket access. All Docker API
# calls are routed through the docker_proxy service (tcp://docker_proxy:2375)
# which restricts the agent to container create/start/wait/remove/logs and
# image pull/inspect operations only.
#
# The raw socket chgrp that previously appeared here has been removed because
# /var/run/docker.sock is no longer mounted into this container.

exec gosu pembrook /usr/local/bin/pembrook-agent "$@"
