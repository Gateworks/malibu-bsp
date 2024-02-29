SHELL = /bin/sh

PLAT := t9130_crb
FS_OFFSET_MB := 1

.PHONY: all
all: firmware-image ubuntu-image

# Buildroot Toolchain
.PHONY: toolchain
toolchain:
ifeq ($(CROSS_COMPILE),)
	$(error "Error: source setup-environment")
endif
ifeq (, $(shell which $(CROSS_COMPILE)gcc))
	$(error "Cross compiler $(CROSS_COMPILE)gcc can not be found")
endif
	@echo "Cross Compiler: $(CROSS_COMPILE)gcc"

# Buildroot
.PHONY: buildroot
buildroot:
	cp malibu_buildroot_defconfig buildroot/configs
	$(MAKE) -C buildroot malibu_buildroot_defconfig all

# Gateworks tool for creating binaries for jtag_usbv4
mkimage_jtag:
	wget -N http://dev.gateworks.com/jtag/mkimage_jtag
	chmod +x mkimage_jtag

# uboot
.PHONY: uboot
uboot: uboot/u-boot.bin
uboot/u-boot.bin: toolchain
	$(MAKE) -C uboot mvebu_malibu_defconfig
	$(MAKE) -C uboot DEVICE_TREE=cn9130-malibu-gw8901

# ATF
.PHONY: atf
atf: atf/build/$(PLAT)/release/flash-image.bin
atf/build/$(PLAT)/release/flash-image.bin: toolchain uboot/u-boot.bin
	$(MAKE) -C atf PLAT=$(PLAT) \
		USE_COHERENT_MEM=0 LOG_LEVEL=10 CP_NUM=1 \
		MV_DDR_PATH=$(PWD)/mv-ddr-marvell \
		BL33=$(PWD)/uboot/u-boot.bin \
		SCP_BL2=$(PWD)/binaries-marvell/mrvl_scp_bl2.img \
		all fip mrvl_flash

# U-Boot env
malibu.env.bin: malibu.env uboot/u-boot.bin
	uboot/tools/mkenvimage -r -s 0x8000 -o malibu.env.bin malibu.env

# boot firmware images
.PHONY: firmware-image
firmware-image: atf/build/$(PLAT)/release/flash-image.bin malibu.env.bin mkimage_jtag
	# firmware image to be flashed to where BOOTROM expects it (no default env)
	cp atf/build/$(PLAT)/release/flash-image.bin firmware-malibu-gw8901.bin
	md5sum firmware-malibu-gw8901.bin > firmware-malibu-gw8901.bin.md5
	# U-Boot is built via CONFIG_DEFAULT_ENV_FILE but we also want to
	# pre-poulate U-Boot env within image so that generic fw_env tools
	# in Linux work.  The env location in U-Boot is defined by
	# CONFIG_ENV_SIZE, CONFIG_ENV_OFFSET
	truncate -s 4M firmware-malibu-gw8901.img
	dd if=atf/build/$(PLAT)/release/flash-image.bin of=firmware-malibu-gw8901.img bs=1M conv=notrunc
	dd if=malibu.env.bin of=firmware-malibu-gw8901.img bs=1K seek=4032 conv=notrunc # 0x3f0000
	dd if=malibu.env.bin of=firmware-malibu-gw8901.img bs=1K seek=4064 conv=notrunc # 0x3f8000
	# Store a backup of the U-Boot env right below the default one that can easily be restored
	dd if=malibu.env.bin of=firmware-malibu-gw8901.img bs=1K seek=3968 conv=notrunc
	dd if=malibu.env.bin of=firmware-malibu-gw8901.img bs=1K seek=4000 conv=notrunc
	# create JTAG image
	./mkimage_jtag --soc cn931x --emmc -s --partconf=boot0 \
		firmware-malibu-gw8901.img@boot0:erase_part:0-8192 \
		firmware-malibu-gw8901.img@boot1:erase_part:0-8192 \
		> firmware-malibu-gw8901-jtag.bin

# kernel
.PHONY: linux
linux: linux/arch/arm64/boot/Image
linux/arch/arm64/boot/Image: toolchain
	cp malibu_linux_defconfig linux/arch/arm64/configs/
	$(MAKE) -C linux malibu_linux_defconfig
	$(MAKE) DTC_FLAGS="-@" -C linux Image dtbs modules
.PHONY: kernel_image
kernel_image: linux-malibu.tar.xz
linux-malibu.tar.xz: linux/arch/arm64/boot/Image uboot
	# install dir
	rm -rf linux/install
	mkdir -p linux/install/boot
	# install uncompressed kernel
	cp linux/arch/arm64/boot/Image linux/install/boot
	# install dtbs
	cp linux/arch/arm64/boot/dts/marvell/cn9130*-malibu-*.dtb* linux/install/boot
	# install U-Boot bootscript
	uboot/tools/mkimage -A $(ARCH) -T script -C none -a 0 -e 0 -d boot.scr \
		linux/install/boot/boot.scr
	# install kernel modules
	make -C linux INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=install modules_install
	make -C linux INSTALL_HDR_PATH=install/usr headers_install
	# cryptodev-linux build/install
	make -C cryptodev-linux KERNEL_DIR=../linux
	make -C cryptodev-linux KERNEL_DIR=../linux DESTDIR=../linux/install \
		INSTALL_MOD_PATH=../linux/install install
	# tarball
	tar -cvJf linux-malibu.tar.xz --numeric-owner --owner=0 --group=0 \
		-C linux/install .

# ubuntu
UBUNTU_FSSZMB ?= 2048
UBUNTU_REL ?= jammy
UBUNTU_FS ?= $(UBUNTU_REL)-malibu.ext4
UBUNTU_IMG ?= $(UBUNTU_REL)-malibu.img
$(UBUNTU_REL)-malibu.tar.xz:
	# fetch pre-built ubuntu rootfs tarball
	wget -N http://dev.gateworks.com/ubuntu/$(UBUNTU_REL)/$(UBUNTU_REL)-malibu.tar.xz
$(UBUNTU_FS): linux-malibu.tar.xz $(UBUNTU_REL)-malibu.tar.xz
	# create ext4 filesystem
	sudo ./mkfs ext4 $(UBUNTU_FS) $(UBUNTU_FSSZMB)M \
		$(UBUNTU_REL)-malibu.tar.xz linux-malibu.tar.xz
	sudo chown $$USER.$$USER $(UBUNTU_FS)

.PHONY: ubuntu-image
ubuntu-image: $(UBUNTU_FS)
	# disk image
	truncate -s $$(($(UBUNTU_FSSZMB) + $(FS_OFFSET_MB)))M $(UBUNTU_IMG)
	dd if=$(UBUNTU_FS) of=$(UBUNTU_IMG) bs=1M seek=$(FS_OFFSET_MB)
	# partition table
	printf "$$(($(FS_OFFSET_MB)*2*1024)),,L,*" | sfdisk -uS $(UBUNTU_IMG)
	# compress
	gzip -f $(UBUNTU_IMG)

.PHONY: clean
clean:
	rm -f firmware-malibu* malibu.env.bin
	make -C uboot clean
	make -C atf PLAT=$(PLAT) SCP_BL2=$(PWD)/binaries-marvell/mrvl_scp_bl2.img clean
	make -C linux clean
	make -C cryptodev-linux clean
	make -C buildroot clean
	rm -rf linux/install
	rm -rf linux-malibu.tar.xz
	rm -rf $(UBUNTU_REL)-malibu.ext4 $(UBUNTU_REL)-malibu.img.gz $(UBUNTU_REL)-malibu.tar.xz

.PHONY: distclean
distclean:
	rm -f firmware-malibu* malibu.env.bin
	make -C uboot distclean
	make -C atf PLAT=$(PLAT) SCP_BL2=$(PWD)/binaries-marvell/mrvl_scp_bl2.img distclean
	make -C linux distclean
	make -C buildroot distclean
	rm -rf linux/install
