#!/bin/bash

set -u -e

debug=0

vcpus=1
memory=2048
bus=default
vcpus=1
declare -a disks=(8)
declare -a networks=(
    maas-oam-net
)
declare -a tags=()
first_disk=0
force=0
uefi=0

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
-v | --vcpus    The number of vCPUs (default = ${vcpus})
-m | --memory   The memory size in MiB (default = ${memory} MiB)
-d | --disk     The disk size in GiB. If used repeatedly more disks
                are added with this size. (default = ${disks[@]} GiB)
-b | --bus      The bus type {'ide', 'sata', 'scsi', 'usb', 'virtio' or 'xen'}
-t | --tag      Add a tag to the machine. This option can be used
                multiple times and is additive.
-i | --network  A network name to connect to. This option can be used
                multiple times and is additive. (default = ${networks[@]})
-u | --uefi     Use UEFI booting.
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
        -v|--vcpus)
            shift
            if (( $# <= 0 )); then
                echo "missing vCPUs"
                exit 1
            fi
            vcpus=$(( $1 ))
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
        -b|--bus)
            shift
            if (( $# <= 0 )); then
                echo "missing bus type"
                exit 1
            fi
            bus=$1
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
        -u|--uefi)
            uefi=1
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

maas_ip=172.18.0.2
maasadmin() {
    ssh root@${maas_ip} -- maas admin "$@"
}

VIRSH_IP_COUNT=$(xmllint --xpath 'count(//ip/@address)' <(virsh net-dumpxml default))
declare -a VIRSH_IPS
for (( i = 1; i <= VIRSH_IP_COUNT; i++ )); do
    VIRSH_IPS[$((i - 1))]=$(xmllint --xpath "string(//ip[${i}]/@address)" <(virsh net-dumpxml default))
done

declare -a network_strings
for (( i = 0; i < ${#networks[@]}; i++ )); do
    network_strings[${i}]="--network network=${networks[${i}]},model=virtio,address.type=pci,address.slot=$((3 + i))"
done

declare -a disk_strings
for (( i = 0; i < ${#disks[@]}; i++ )); do
    if [[ ${bus} = default ]]; then
        disk_strings[${i}]="--disk size=${disks[${i}]}"
    else
        disk_strings[${i}]="--disk size=${disks[${i}]},bus=${bus}"
    fi
done

ssh root@${maas_ip} -- 'maas login admin http://localhost:5240/MAAS $(cat ubuntu-api-key)'

if virsh dominfo "${vm_id}"; then
    if (( force == 1 )); then
        virsh destroy "${vm_id}" || true
        virsh undefine --remove-all-storage "${vm_id}" || true
        system_id=$(maasadmin machines read \
            | jq -r ".[] | select(.hostname == \"${vm_id}\") | .system_id")
        if [[ -n ${system_id} ]]; then
            maasadmin machine delete "${system_id}"
        fi
    else
        echo "VM with name ${vm_id} already exists"
        exit 1
    fi
fi

virt-install \
    --name "${vm_id}" \
    --cpu host-passthrough,cache.mode=passthrough \
    --vcpus maxvcpus=${vcpus} \
    --memory "${memory}" \
    ${disk_strings[@]} \
    ${network_strings[@]} \
    --boot network \
    $(if (( uefi == 1 )); then echo --boot uefi; fi) \
    --os-variant generic \
    --noautoconsole

mac=$(xmllint --xpath "//source[@network='maas-oam-net']/../mac/@address" \
    <(virsh dumpxml ${vm_id}) \
    | awk -F= '{print $2}' | tr --delete '"')

while true; do
    result=$(maasadmin machines create \
        architecture=amd64 \
        mac_addresses="${mac}" \
        hostname="${vm_id}" \
        power_type=virsh \
        power_parameters_power_id="${vm_id}" \
        power_parameters_power_address=qemu+ssh://"${USER}@${VIRSH_IPS[0]}"/system)
    if (( $? == 0 )); then
        break
    fi
done

system_id=$(jq '.system_id' <(echo ${result}) | tr -d '"')

if (( ${#tags[@]} > 0 )); then
    for tag in "${tags[@]}"; do
        if ! maasadmin tag read "${tag}"; then
            maasadmin tags create name="${tag}"
        fi
        maasadmin tag update-nodes "${tag}" add="${system_id}"
    done
fi

while [[ $(maasadmin machine read "${system_id}" \
    | jq -r '.commissioning_status_name') != Passed ]]; do
    sleep 10
done

for (( i = 1; i < ${#networks[@]}; i++ )); do
    network_mode=AUTO
    if [[ ${networks[i]} =~ oam ]]; then
        network_mode=dhcp
    fi
    bridge=$(xmllint --xpath 'string(/network/bridge/@name)' <(virsh net-dumpxml ${networks[i]}))
    readarray -t network_address < <(ip -json addr show dev "${bridge}" \
        | jq -r '.[].addr_info[] | "\(.local)/\(.prefixlen)"')
    network_name=$(python3 -c "import ipaddress; print(ipaddress.ip_network('${network_address[0]}', strict=False))")
    subnet_id=$(maasadmin subnets read \
        | jq -r ".[] | select(.name == \"${network_name}\") | .id")
    interface_id=$(maasadmin interfaces read "${system_id}" \
        | jq -r ".[] | select(.name == \"enp0s$((i + 3))\") | .id")
    readarray -t vlan_ids < <(maasadmin fabrics read \
        | jq -r ".[] | select(.name == \"${networks[i]}\") | .vlans[].id")
    maasadmin interface update "${system_id}" "${interface_id}" vlan="${vlan_ids[0]}"
    maasadmin interface link-subnet "${system_id}" "${interface_id}" \
        subnet="${subnet_id}" mode="${network_mode}"
done

echo "done deploying ${vm_id}"
