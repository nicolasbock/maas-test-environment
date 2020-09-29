# MaaS Test Environment

This repository contains scripts that create a libvirt VM based MaaS
environment.

The script `create.sh` will create a libvirt VM running MAAS. Optional
arguments for the script are:

    -h | --help     This help
    -s | --series   The Ubuntu series (default: ${SERIES})
    -r | --refresh  Refresh cloud images
    -d | --debug    Print debugging information

The script will destroy an existing `maas-server` VM and rebuild it.

## Adding a VM

Running the script

    $ ./add-machine-hypervisor.sh

on the hypervisor will create a new VM and add it to MAAS running on
VM `maas-server`. That VM can then be commissioned via MAAS. The
script will add the correct "Power Configuration" to that VM so it can
be manager via MAAS.

## Installing a Juju controller

Create a VM for the Juju controller:

    $ ./add-machine-hypervisor.sh --name juju-controller

And wait for it to be READY in MAAS. Then log into the `maas-server`
and run:

    $ ssh ubuntu@MAAS_IP
    $ ./juju/gencloud.sh
