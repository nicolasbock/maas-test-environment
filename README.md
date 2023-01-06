# MaaS Test Environment

[![CI](https://github.com/nicolasbock/maas-test-environment/actions/workflows/CI.yaml/badge.svg)](https://github.com/nicolasbock/maas-test-environment/actions/workflows/CI.yaml)
[![Python CI](https://github.com/nicolasbock/maas-test-environment/actions/workflows/build_and_test.yaml/badge.svg)](https://github.com/nicolasbock/maas-test-environment/actions/workflows/build_and_test.yaml)

This repository contains scripts that create a libvirt VM based MaaS
environment.

The script `create.sh` will create a libvirt VM running MAAS. Optional
arguments for the script are:

```
-h | --help     This help
-s | --series   The Ubuntu series (default: ${SERIES})
-r | --refresh  Refresh cloud images
-d | --debug    Print debugging information
-c | --console  Attach to VM console after creating it
-s | --sync     Sync MAAS images (default is not to)
--maas-deb      Install MAAS from deb (not snap)
```

The script will destroy an existing `maas-server` VM and rebuild it.

## Adding a VM

Running the script

```shell
$ ./add-machine-hypervisor.sh
```

on the hypervisor will create a new VM and add it to MAAS running on
VM `maas-server`. That VM can then be commissioned via MAAS. The
script will add the correct "Power Configuration" to that VM so it can
be manager via MAAS.

## Installing a Juju controller

Create a VM for the Juju controller:

```shell
$ ./add-machine-hypervisor.sh --name juju-controller
```

And wait for it to be READY in MAAS. Then log into the `maas-server`
and run:

```shell
$ ssh ubuntu@MAAS_IP
$ ./juju/gencloud.sh
```

## Adding machines for juju models

Adding machines can be done in much the same way as adding the juju
controller VM in the example above. The following command will create
a machine with 8 GiB of memory, 3 disks, and 2 NICs (`maas-oam-net`
and `maas-public-net`):

```shell
$ ./add-machine-hypervisor.sh \
    --name infra-1 \
    --memory $((8 * 1024)) \
    --disk 10 --disk 2 --disk 2 \
    --network maas-public-net
```
