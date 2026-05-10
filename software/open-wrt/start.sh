#!/bin/sh
set -eu

EXT_HELPER_CIDR="${EXT_HELPER_CIDR:-172.22.0.254/24}"
INT_HELPER_CIDR="${INT_HELPER_CIDR:-172.18.0.254/24}"

create_tap() {
    dev="$1"
    ip tuntap add dev "$dev" mode tap 2>/dev/null || true
    ip link set "$dev" up
}

find_iface_by_cidr() {
    cidr="$1"
    ip -o -4 addr show | awk -v cidr="$cidr" '$4 == cidr { print $2; exit }'
}

bridge_iface() {
    bridge="$1"
    uplink="$2"
    tap="$3"

    ip link add name "$bridge" type bridge 2>/dev/null || true
    ip link set "$bridge" up

    if [ -n "$uplink" ]; then
        ip link set "$uplink" promisc on
        ip link set "$uplink" master "$bridge"
        ip link set "$uplink" up
    fi

    ip link set "$tap" promisc on
    ip link set "$tap" master "$bridge"
    ip link set "$tap" up
}

create_tap tap0
create_tap tap1

EXT_IFACE="$(find_iface_by_cidr "$EXT_HELPER_CIDR")"
INT_IFACE="$(find_iface_by_cidr "$INT_HELPER_CIDR")"

if [ -z "$EXT_IFACE" ] || [ -z "$INT_IFACE" ]; then
    echo "ERROR: could not find Docker uplinks for $EXT_HELPER_CIDR / $INT_HELPER_CIDR" >&2
    ip -o -4 addr show >&2
    exit 1
fi

bridge_iface br-ext "$EXT_IFACE" tap0 "$EXT_HELPER_CIDR"
bridge_iface br-int "$INT_IFACE" tap1 "$INT_HELPER_CIDR"

echo "Container-local TAP bridging enabled: $EXT_IFACE -> br-ext, $INT_IFACE -> br-int"

ARCH=$(uname -m)

if [ "$ARCH" = "aarch64" ]; then
    exec qemu-system-aarch64 \
        -nographic \
        -machine virt \
        -cpu cortex-a57 \
        -m 256M \
        -drive file=openwrt.img,format=raw \
        -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
        -serial mon:stdio \
        -netdev tap,id=n0,ifname=tap0,script=no,downscript=no \
        -device virtio-net-pci,netdev=n0 \
        -netdev tap,id=n1,ifname=tap1,script=no,downscript=no \
        -device virtio-net-pci,netdev=n1 \
        -netdev user,id=n2,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080 \
        -device virtio-net-pci,netdev=n2
else
    exec qemu-system-x86_64 \
        -nographic \
        -m 128M \
        -drive file=openwrt.img,format=raw \
        -serial mon:stdio \
        -netdev tap,id=n0,ifname=tap0,script=no,downscript=no \
        -device e1000,netdev=n0 \
        -netdev tap,id=n1,ifname=tap1,script=no,downscript=no \
        -device e1000,netdev=n1 \
        -netdev user,id=n2,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080 \
        -device e1000,netdev=n2
fi
