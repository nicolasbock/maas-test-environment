#!/bin/bash

set -x

for i in {1..3}; do
  ./add-machine-hypervisor.sh \
    --name juju-controller-${i} \
    --memory $((2 * 1024)) \
    --tag juju \
    --force \
    --bus sata \
    --network maas-admin-net \
    --network maas-internal-net \
    --network maas-external-net \
    --network maas-public-net
done

for i in {1..6}; do
  ./add-machine-hypervisor.sh \
    --name infra-1 \
    --debug \
    --memory $((4 * 1024)) \
    --force \
    --tag infra \
    --tag storage \
    --bus sata \
    --disk 50 \
    --disk 10 \
    --disk 10 \
    --network maas-admin-net \
    --network maas-internal-net \
    --network maas-external-net
done
