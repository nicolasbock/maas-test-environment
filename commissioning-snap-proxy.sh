#!/bin/bash

while true; do
  if snap version; then
    break
  fi
  sleep 2
done

snap set system proxy.http=http://squid-deb-proxy.virtual:8080
snap set system proxy.https=http://squid-deb-proxy.virtual:8080

snap get system proxy

exit 0
