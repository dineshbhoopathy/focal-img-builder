#!/bin/bash

set -eu -o pipefail

: "${IMAGE_NAME:="ubuntu-20.04-cloud-init"}"
: "${BUILDER_DIR:=./builder}"
: "${INPUT_DIR:=./input}"
: "${OUTPUT_DIR:=/root/apple-focal-live}"

img_dir="$(mktemp -d)"
squashfs_dir="$(mktemp -d)"
squashfs_installer_dir="$(mktemp -d)"
cleanup_dirs() {
  rm -rf "${squashfs_dir}" "${squashfs_installer_dir}" "${img_dir}"
}
trap cleanup_dirs EXIT

# extract img files and nested casper root fs
iso_path="$(ls ${INPUT_DIR}/*.iso)"
osirrox -indev "${iso_path}" -extract / "${img_dir}"
dd bs=1 count=446 if="${iso_path}" of="${img_dir}/isolinux/isohdpfx.bin"
rm -r "${squashfs_dir}" "${squashfs_installer_dir}" # ensure dest doesn't exist
unsquashfs -dest "${squashfs_dir}" "${img_dir}/casper/filesystem.squashfs"
unsquashfs -dest "${squashfs_installer_dir}" "${img_dir}/casper/installer.squashfs"

# allow internet access in chroot
mv "${squashfs_dir}/etc/resolv.conf" "${squashfs_dir}/etc/resolv.conf.bak"
cp /etc/resolv.conf "${squashfs_dir}/etc/"

# chroot into casper squashfs
mount --bind /dev/ "${squashfs_dir}/dev"
unmount_dirs() {
  umount "${squashfs_dir}/dev"
}
trap '{ unmount_dirs && cleanup_dirs; }' EXIT

chroot "${squashfs_dir}" /bin/bash -x <<EOF
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devpts none /dev/pts
trap '{ umount /proc /sys /dev/pts; }' EXIT

export HOME=/root
export LC_ALL=C

echo "apple-focal-live" > /etc/hostname

apt-get update
dbus-uuidgen > /var/lib/dbus/machine-id
dpkg-divert --local --rename --add /sbin/initctl

ln -s /bin/true /sbin/initctl

apt-get -y upgrade

apt-get install -y systemd sudo ubuntu-standard casper lupin-casper discover os-prober resolvconf net-tools locales grub-common grub-gfxpayload-lists grub-pc grub-pc-bin grub2-common apt-transport-https ca-certificates curl git dnsutils tree nvme-cli lm-sensors traceroute traceroute tcptraceroute lsscsi pciutils rsync gnupg2 gnupg-agent ldap-utils software-properties-common python3-ethtool vim openssh-server ca-certificates apt-utils wget dnsutils inetutils-ping systemd live-boot cloud-init open-iscsi laptop-detect subiquitycore snapd libterm-readline-gnu-perl

rm /var/lib/dbus/machine-id
rm /sbin/initctl
dpkg-divert --rename --remove /sbin/initctl
apt-get clean
rm -rf /tmp/*
mv /etc/resolv.conf.bak /etc/resolv.conf
EOF

# repack squashfs
chroot "${squashfs_dir}" dpkg-query -W --showformat='${Package} ${Version}\n' | \
  tee "${img_dir}/casper/filesystem.manifest"
cp -v "${img_dir}/casper/filesystem.manifest" "${img_dir}/casper/filesystem.manifest-desktop"
packages_to_remove='ubiquity ubiquity-frontend-gtk ubiquity-frontend-kde casper lupin-casper live-initramfs user-setup discover1 xresprobe os-prober libdebian-installer4'
for i in ${packages_to_remove}; do
  sed -i "/${i}/d" "${img_dir}/casper/filesystem.manifest-desktop"
done
mksquashfs "${squashfs_dir}" "${img_dir}/casper/filesystem.squashfs" -noappend

# disable networking in installer to make install more hermetic
#echo 'network: {config: disabled}' > \
#  "${squashfs_installer_dir}/etc/netplan/00-installer-config.yaml"
mksquashfs "${squashfs_installer_dir}" "${img_dir}/casper/installer.squashfs" -noappend

pushd "${img_dir}" > /dev/null
  # regenerate md5sum
  rm md5sum.txt
  find -type f -print0 | \
    xargs -0 md5sum | \
    grep -v isolinux/boot.cat > md5sum.txt

  # build new iso
  xorriso -as mkisofs -r -V "${IMAGE_NAME}" \
            -cache-inodes -J -l \
            -isohybrid-mbr isolinux/isohdpfx.bin \
            -c isolinux/boot.cat \
            -b isolinux/isolinux.bin \
               -no-emul-boot -boot-load-size 4 -boot-info-table \
            -eltorito-alt-boot \
            -e boot/grub/efi.img \
               -no-emul-boot -isohybrid-gpt-basdat \
            -o "${OUTPUT_DIR}/${IMAGE_NAME}.iso" \
            .
popd > /dev/null
