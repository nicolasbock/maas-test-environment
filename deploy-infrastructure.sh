#!/bin/bash

set -x

: ${bus:=scsi}
: ${number_storage:=3}
: ${number_small_compute:=2}
: ${number_large_compute:=4}

next_id=1

# Storage nodes
for i in $(seq ${next_id} ${number_storage}); do
  ./add-machine-hypervisor.sh \
    --name infra-$(printf "%02d" ${i}) \
    --debug \
    --memory $((2 * 1024)) \
    --force \
    --tag infra \
    --tag storage \
    --tag small \
    --bus "${bus}" \
    --disk 20 \
    --disk 10 \
    --disk 10 \
    --disk 10 \
    --disk 10 \
    --network maas-admin-net \
    --network maas-internal-net \
    --network maas-public-net \
    --network maas-storage-net
done

next_id=$((next_id + number_storage))

# Small computes
for i in $(seq ${next_id} $((next_id + number_small_compute - 1))); do
  ./add-machine-hypervisor.sh \
    --name infra-$(printf "%02d" ${i}) \
    --debug \
    --memory $((2 * 1024)) \
    --force \
    --tag infra \
    --tag compute \
    --tag small \
    --bus "${bus}" \
    --disk 20 \
    --network maas-admin-net \
    --network maas-internal-net \
    --network maas-public-net \
    --network maas-storage-net
done

next_id=$((next_id + number_small_compute))

# Large computes
for i in $(seq ${next_id} $((next_id + number_large_compute - 1))); do
  ./add-machine-hypervisor.sh \
    --name infra-$(printf "%02d" ${i}) \
    --debug \
    --memory $((8 * 1024)) \
    --force \
    --tag infra \
    --tag compute \
    --tag large \
    --bus "${bus}" \
    --disk 40 \
    --network maas-admin-net \
    --network maas-internal-net \
    --network maas-public-net \
    --network maas-storage-net
done
