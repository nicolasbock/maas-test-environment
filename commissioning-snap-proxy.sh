#!/bin/bash

while true; do
    if snap version; then
        break
    fi
    sleep 2
done

SNAP_HTTP_PROXY
SNAP_HTTPS_PROXY

snap get system proxy

exit 0
