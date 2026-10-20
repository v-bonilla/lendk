#!/bin/sh
# PROTOTYPE for #33, throwaway: boot an Ubuntu 24.04 cloud image under QEMU TCG inside a container,
# for hosts with no /dev/kvm. Usage: vm/up.sh DIR, where DIR holds noble.img and id_proto33.pub.
# ssh -p 2233 -i DIR/id_proto33 alice@127.0.0.1 once DIR/console.log shows the login prompt.
set -eu
dir=$1
here=$(cd "$(dirname "$0")" && pwd)
sed "s|@PUBKEY@|$(cat "$dir/id_proto33.pub")|" "$here/user-data.in" >"$dir/user-data"
printf 'instance-id: kr33\nlocal-hostname: kr33\n' >"$dir/meta-data"
docker run -d --name lendk-proto33-vm -p 127.0.0.1:2233:2222 -v "$dir:/vm" lendk-proto33-qemu sh -c '
	cd /vm &&
	cloud-localds seed.iso user-data meta-data &&
	{ [ -f disk.qcow2 ] || qemu-img create -q -f qcow2 -F qcow2 -b /vm/noble.img disk.qcow2 20G; } &&
	exec qemu-system-x86_64 -accel tcg,thread=multi -cpu max -smp 4 -m 6144 \
		-display none -monitor none -serial file:/vm/console.log \
		-drive file=disk.qcow2,if=virtio -drive file=seed.iso,if=virtio,format=raw \
		-netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0'
