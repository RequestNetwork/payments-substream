#!/bin/sh
# Docker HEALTHCHECK. Healthy while a sink runs, or once every chain has finished its bounded
# replay: the supervisor then stays up idle and writes /tmp/payments-sink-idle. Only the sink run
# command has the package path (absolute) right after `postgres`; `setup` and `tools cursor read`
# do not, so a sink stuck in setup never looks healthy. A script file, not `sh -c`, so pgrep never
# matches this process's own command line.
pgrep -f "substreams sink postgres /" >/dev/null 2>&1 || [ -e /tmp/payments-sink-idle ]
