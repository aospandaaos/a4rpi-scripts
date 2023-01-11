#!/bin/bash

# Copyright Chris Simmonds. All rights reserved.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Format an SD card for AOSP on RPi4

if [ -z ${ANDROID_PRODUCT_OUT} ]; then
	echo "You must run lunch first"
	exit 1
fi

if [ $# -ne 1 ]; then
        echo "Usage: $0 [drive]"
        echo "       drive is '/dev/sdb', '/dev/mmcblk0', etc"
        exit 1
fi

DRIVE=$(basename $1)
UBOOTDIR=../rpi/u-boot
KERNELDIR=../rpi/android-kernel-rpi-5.15/out/arpi-5.15/dist
RPIBOOTDIR=../rpi/firmware/boot

# Check it is a flash drive (size < 32MiB)
NUM_SECTORS=`cat /sys/block/${DRIVE}/size`
if [ $NUM_SECTORS -eq 0 -o $NUM_SECTORS -gt 64000000 ]; then
	echo "Does not look like an SD card, bailing out"
	exit 1
fi

# Unmount any partitions that have been automounted
if [ $DRIVE == "mmcblk0" ]; then
	sudo umount /dev/${DRIVE}*
	BOOTLOADER_PART=/dev/${DRIVE}p1
	SYSTEM_PART=/dev/${DRIVE}p2
	VENDOR_PART=/dev/${DRIVE}p3
	USER_PART=/dev/${DRIVE}p4
else
	sudo umount /dev/${DRIVE}[1-9]
	BOOTLOADER_PART=/dev/${DRIVE}1
	SYSTEM_PART=/dev/${DRIVE}2
	VENDOR_PART=/dev/${DRIVE}3
	USER_PART=/dev/${DRIVE}4
fi

sleep 2

echo "Zap existing partition tables"
sudo sgdisk --zap-all /dev/${DRIVE}
# Ignore errors here: sgdisk fails if the GPT is damaged *before* erasing it
# if [ $? -ne 0 ]; then echo "Error: sgdisk"; exit 1; fi

# Create 5 partitions
# 1   64 MiB  boot
# 2 2048 MiB  system
# 3  256 MiB  vendor
# 4  512 MiB  userdata

echo "Writing GPT"
sudo gdisk /dev/${DRIVE} << EOF 2>&1 > /dev/null
n
1

+64M

c
boot
n
2

+2048M

c
2
system
n
3

+256M

c
3
vendor
n
4

+512M

c
4
userdata
w
y
EOF
if [ $? -ne 0 ]; then echo "Error: gdisk"; exit 1; fi

echo "Writing MBR"
sudo gdisk /dev/${DRIVE} << EOF 2>&1 > /dev/null
r
h
1
N
0c
Y
N
w
y
EOF
if [ $? -ne 0 ]; then echo "Error: gdisk"; exit 1; fi
# Format p1 with FAT32
sudo mkfs.vfat -F 16 -n bootload ${BOOTLOADER_PART}
if [ $? -ne 0 ]; then echo "Error: mkfs.vfat"; exit 1; fi

# Copy boot files
echo "Mounting $BOOTLOADER_PART"
sudo mount $BOOTLOADER_PART /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo cp $RPIBOOTDIR/fixup4.dat /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo cp $RPIBOOTDIR/start4.elf /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo cp $ANDROID_BUILD_TOP/device/a4rpi/rpi4/boot/cmdline.txt /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo cp $ANDROID_BUILD_TOP/device/a4rpi/rpi4/boot/config.txt /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo cp $UBOOTDIR/u-boot.bin /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo mkimage -A arm -T script -C none -n "Boot script" -d ${ANDROID_BUILD_TOP}/device/a4rpi/rpi4/boot/boot.scr.txt /mnt/boot.scr
if [ $? != 0 ]; then echo "ERROR"; exit; fi

# RPi bootloader needs a device tree
sudo cp $KERNELDIR/bcm2711-rpi-4-b.dtb /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi
sudo mkdir /mnt/overlays
sudo cp $KERNELDIR/vc4-kms-v3d-pi4.dtbo /mnt/overlays
if [ $? != 0 ]; then echo "ERROR"; exit; fi
# sudo cp $KERNELDIR/dwp4.dtbo /mnt/overlays
# if [ $? != 0 ]; then echo "ERROR"; exit; fi

# TBD: kernel and ramdisk should be loded from boot.img
sudo cp $KERNELDIR/Image.gz /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi
sudo cp ${ANDROID_PRODUCT_OUT}/ramdisk.img /mnt
# cat ${ANDROID_PRODUCT_OUT}/ramdisk.img ${ANDROID_PRODUCT_OUT}/vendor_ramdisk.img > ${ANDROID_PRODUCT_OUT}/ramdisk_rpi.img
# sudo cp ${ANDROID_PRODUCT_OUT}/ramdisk_rpi.img /mnt/ramdisk.img
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sync
sudo umount /mnt


# Create bmap files
bmaptool create -o ${ANDROID_PRODUCT_OUT}/system.img.bmap ${ANDROID_PRODUCT_OUT}/system.img
bmaptool create -o ${ANDROID_PRODUCT_OUT}/vendor.img.bmap ${ANDROID_PRODUCT_OUT}/vendor.img
bmaptool create -o ${ANDROID_PRODUCT_OUT}/userdata.img.bmap ${ANDROID_PRODUCT_OUT}/userdata.img

# Copy disk images
echo "Writing system"
sudo bmaptool copy ${ANDROID_PRODUCT_OUT}/system.img ${SYSTEM_PART}
#sudo dd if=${ANDROID_PRODUCT_OUT}/system.img of=$SYSTEM_PART bs=1M
if [ $? != 0 ]; then echo "ERROR"; exit; fi
sudo e2label $SYSTEM_PART system
echo "Writing vendor"
sudo bmaptool copy ${ANDROID_PRODUCT_OUT}/vendor.img ${VENDOR_PART}
#sudo dd if=${ANDROID_PRODUCT_OUT}/vendor.img of=$VENDOR_PART bs=1M
if [ $? != 0 ]; then echo "ERROR"; exit; fi
sudo e2label $VENDOR_PART vendor
echo "Writing userdata"
sudo bmaptool copy ${ANDROID_PRODUCT_OUT}/userdata.img ${USER_PART}
#sudo dd if=${ANDROID_PRODUCT_OUT}/userdata.img of=$USER_PART bs=1M
if [ $? != 0 ]; then echo "ERROR"; exit; fi
sudo e2label $USER_PART userdata


echo "SUCCESS! Andrdoid4RPi installed on the uSD card. Enjoy"

exit 0


