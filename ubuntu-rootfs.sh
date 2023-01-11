#!/bin/sh

DISTRO=jammy
RELEASE=22.04
LEVEL=1
FAMILY=malibu

install()
{
	echo "Installing Ubuntu $RELEASE.$LEVEL...."
	resize
	mkfs.ext4 -F /dev/vda -b 4096
	mount /dev/vda /mnt
	cd /mnt/
	udhcpc -i eth0
	wget -c -P /tmp/ http://cdimage.ubuntu.com/ubuntu-base/releases/$RELEASE/release/ubuntu-base-$RELEASE.$LEVEL-base-arm64.tar.gz
	tar zxf /tmp/ubuntu-base-$RELEASE.$LEVEL-base-arm64.tar.gz -C /mnt
	mount -o bind /proc /mnt/proc/
	mount -o bind /sys/ /mnt/sys/
	mount -o bind /dev/ /mnt/dev/
	mount -o bind /dev/pts /mnt/dev/pts
	mount -t tmpfs tmpfs /mnt/var/lib/apt/
	mount -t tmpfs tmpfs /mnt/var/cache/apt/
	echo "nameserver 8.8.8.8" > /mnt/etc/resolv.conf
	echo "localhost" > /mnt/etc/hostname
	echo "127.0.0.1 localhost" > /mnt/etc/hosts
	export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C

	# install packages
	chroot /mnt apt update
	chroot /mnt apt install --no-install-recommends -y systemd-sysv apt locales less wget procps openssh-server ifupdown net-tools isc-dhcp-client ntpdate lm-sensors i2c-tools psmisc less sudo htop iproute2 iputils-ping kmod network-manager iptables rng-tools apt-utils

	# Add package repos
	cat <<EOF > /mnt/etc/apt/sources.list
deb http://ports.ubuntu.com/ubuntu-ports $DISTRO main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports ${DISTRO}-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports ${DISTRO}-security main restricted universe multiverse
EOF
	# Add package src repos
	cat <<EOF >> /mnt/etc/apt/sources.list
deb-src http://ports.ubuntu.com/ubuntu-ports $DISTRO main restricted universe multiverse
deb-src http://ports.ubuntu.com/ubuntu-ports ${DISTRO}-updates main restricted universe multiverse
deb-src http://ports.ubuntu.com/ubuntu-ports ${DISTRO}-security main restricted universe multiverse
EOF
	# PPA's
	chroot /mnt apt install -y software-properties-common # add-apt-repository
	# Gateworks packages
	chroot /mnt add-apt-repository -y ppa:gateworks-software/packages
	# Prioritize Gateworks ppa packages in all cases
	cat <<\EOF > /mnt/etc/apt/preferences.d/gateworks
Package: *
pin: release o=LP-PPA-gateworks-software-packages
Pin-Priority: 1010
EOF

	# updated modemmanager/libqmi/libmbim
	chroot /mnt add-apt-repository -y ppa:aleksander-m/modemmanager-$DISTRO
	chroot /mnt apt update
	chroot /mnt apt upgrade -y

	# Set Hostname
	echo "${DISTRO}-${FAMILY}" > /mnt/etc/hostname

	# user root, pass root
	echo -e "root\nroot" | chroot /mnt passwd

	# Networking (ifupdown vs netplan)
	# Wireless
	chroot /mnt apt install -y wpasupplicant iw
	chroot /mnt apt install -y modemmanager libqmi-utils libmbim-utils policykit-1
	chroot /mnt apt install -y bluez brcm-patchram

	# Gateworks
	chroot /mnt apt install -y gsc-update gwsoc hostapd-conf

	# cleanup and unmount
	umount /mnt/var/lib/apt/
	umount /mnt/var/cache/apt
	chroot /mnt apt clean
	chroot /mnt apt autoclean
}

case "$1" in
	start)
		install
		reboot
		;;

esac

