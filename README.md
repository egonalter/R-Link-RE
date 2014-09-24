R-Link-RE
=========

Tools (bash scripts) to decompile Renault R-Link Java Apps

- decompile.sh
  Needs an unpacked android filesystem. Downloads required software
  (needs wget, java, unzip, other stuff ...) and tries to decompile
  the java Apps into the current directory.

- download_firmware.sh
  Downloads the firmware version specified in the argument and
  unpacks it.

- toolchain
  This directory contains the toolchain for compiling uboot and kernel.
  It requires an anjient compiler (gcc-4.3), so best is to install
  an old linux distro (e.g. debian lenny) to a vm without network for
  security reasons.
  It supports only old ARM11 targets and needs an update for our shiny
  new OMAP3.

- repack-zImage.sh
  Script to "unpack" a zImage (kernel, ramdisk, stuff).
