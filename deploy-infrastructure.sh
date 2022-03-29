#!/bin/bash

set -x

: ${bus:=scsi}
: ${number_storage:=0}
: ${number_small_compute:=0}
: ${number_large_compute:=9}
: ${STORAGE_VCPUS:=2}
: ${SMALL_COMPUTE_VCPUS:=2}
: ${LARGE_COMPUTE_VCPUS:=2}

next_id=1

# Storage nodes
for i in $(seq ${next_id} ${number_storage}); do
    ./add-machine-hypervisor.sh \
        --name infra-$(printf "%02d" ${i}) \
        --debug \
        --vcpus ${STORAGE_VCPUS} \
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
        --vcpus ${SMALL_COMPUTE_VCPUS} \
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
        --vcpus ${LARGE_COMPUTE_VCPUS} \
        --memory $((8 * 1024)) \
        --force \
        --tag infra \
        --tag compute \
        --tag large \
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
