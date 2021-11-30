#!/bin/bash

set -x

# Storage nodes
for i in {1..3}; do
  ./add-machine-hypervisor.sh \
    --name infra-$(printf "%02d" ${i}) \
    --debug \
    --memory $((2 * 1024)) \
    --force \
    --tag infra \
    --tag storage \
    --tag small \
    --bus sata \
    --disk 20 \
    --disk 10 \
    --disk 10 \
    --network maas-admin-net \
    --network maas-internal-net \
    --network maas-external-net
done

# Small computes
for i in {4..8}; do
  ./add-machine-hypervisor.sh \
    --name infra-$(printf "%02d" ${i}) \
    --debug \
    --memory $((2 * 1024)) \
    --force \
    --tag infra \
    --tag compute \
    --tag small \
    --bus sata \
    --disk 20 \
    --network maas-admin-net \
    --network maas-internal-net \
    --network maas-external-net
done

# Large computes
for i in {9..12}; do
  ./add-machine-hypervisor.sh \
    --name infra-$(printf "%02d" ${i}) \
    --debug \
    --memory $((8 * 1024)) \
    --force \
    --tag infra \
    --tag compute \
    --tag large \
    --bus sata \
    --disk 40 \
    --network maas-admin-net \
    --network maas-internal-net \
    --network maas-external-net
done
