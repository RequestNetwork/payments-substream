#!/bin/sh
# Docker HEALTHCHECK. Healthy while a sink child runs, or once every chain has finished its bounded
# replay: the supervisor then stays up idle and writes /tmp/payments-sink-idle. A script file, not
# `sh -c`, so pgrep never matches this process's own command line.
pgrep -f "substreams sink postgres" >/dev/null 2>&1 || [ -e /tmp/payments-sink-idle ]
