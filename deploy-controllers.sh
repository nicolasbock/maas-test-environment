#!/bin/bash

set -x

num_controllers=1
controller_memory=2
: ${bus:=scsi}

for i in $(seq 1 ${num_controllers}); do
  ./add-machine-hypervisor.sh \
    --name "juju-controller-${i}" \
    --memory $((controller_memory * 1024)) \
    --tag juju \
    --bus "${bus}" \
    --debug \
    --force \
    --network maas-admin-net \
    --network maas-internal-net \
    --network maas-public-net \
    --network maas-storage-net
done
