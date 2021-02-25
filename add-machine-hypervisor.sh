#!/bin/bash

set -u -e

debug=0

memory=2048
declare -a disks=(8)
declare -a networks=(
    maas-oam-net
)
declare -a tags=()
first_disk=0
force=0

while (( $# > 0 )); do
    case $1 in
        -h|--help)
            cat <<EOF
Usage:

-h | --help     This help
     --debug    Print debugging information
-f | --force    Force VM creation even if a VM with that name
                already exists.
-n | --name     The name of the machine (libvirt ID)
-m | --memory   The memory size in MiB (default = ${memory} MiB)
-d | --disk     The disk size in GiB. If used repeatedly more disks
                are added with this size. (default = ${disks[@]} GiB)
-t | --tag      Add a tag to the machine. This option can be used
                multiple times and is additive.
-i | --network  A network name to connect to. This option can be used
                multiple times and is additive. (default = ${networks[@]})
EOF
            exit
            ;;
        --debug)
            debug=1
            ;;
        -f|--force)
            force=1
            ;;
        -n|--name)
            shift
            if (( $# <= 0 )); then
                echo "missing machine name"
                exit 1
            fi
            vm_id=$1
            ;;
        -m|--memory)
            shift
            if (( $# <= 0 )); then
                echo "missing memory size"
                exit 1
            fi
            memory=$1
            ;;
        -d|--disk)
            shift
            if (( $# <= 0 )); then
                echo "missing disk size"
                exit 1
            fi
            if (( first_disk == 0 )); then
                disks=( $1 )
                first_disk=1
            else
                disks=( ${disks[@]} $1 )
            fi
            ;;
        -t|--tag)
            shift
            if (( $# <= 0 )); then
                echo "missing tag name"
                exit 1
            fi
            tags=( ${tags[@]} $1 )
            ;;
        -i|--network)
            shift
            if (( $# <= 0 )); then
                echo "missing network name"
                exit 1
            fi
            networks=( ${networks[@]} $1 )
            ;;
        *)
            echo "unknown command line argument '$1'"
            exit 1
            ;;
    esac
    shift
done

if ! [[ -v vm_id ]]; then
    echo "missing machine name"
    exit 1
fi

if (( debug == 1 )); then
    set -x
    PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
fi

VIRSH_IP=$(xmllint --xpath '*/ip/@address' <(virsh net-dumpxml default) | awk -F = '{print $2}' | tr -d '"')

for (( i = 0; i < ${#networks[@]}; i++ )); do
    networks[${i}]="--network network=${networks[${i}]}"
done

for (( i = 0; i < ${#disks[@]}; i++ )); do
    disks[${i}]="--disk size=${disks[${i}]}"
done

if virsh dominfo ${vm_id}; then
    if (( force == 1 )); then
        virsh destroy ${vm_id} || true
        virsh undefine ${vm_id} || true
    else
        echo "VM with name ${vm_id} already exists"
        exit 1
    fi
fi

virt-install \
    --name ${vm_id} \
    --memory ${memory} \
    ${disks[@]} \
    ${networks[@]} \
    --boot network \
    --os-variant generic \
    --noautoconsole

ip=$(virsh domifaddr maas-server | grep ipv4 | awk '{print $4}' | awk -F/ '{print $1}')
mac=$(xmllint --xpath "//source[@network='maas-oam-net']/../mac/@address" <(virsh dumpxml ${vm_id}) \
    | awk -F= '{print $2}' | tr --delete '"')

result=$(ssh root@${ip} -- maas admin machines create \
    architecture=amd64 \
    mac_addresses=${mac} \
    hostname=${vm_id} \
    power_type=virsh \
    power_parameters_power_id=${vm_id} \
    power_parameters_power_address=qemu+ssh://${USER}@${VIRSH_IP}/system)

system_id=$(jq '.system_id' <(echo ${result}) | tr -d '"')

if (( ${#tags[@]} > 0 )); then
    for tag in ${tags[@]}; do
        if ! ssh root@${ip} -- maas admin tag read ${tag}; then
            ssh root@${ip} -- maas admin tags create name=${tag}
        fi
        ssh root@${ip} -- maas admin tag update-nodes ${tag} add=${system_id}
    done
fi
