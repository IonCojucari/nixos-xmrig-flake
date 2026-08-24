{ config, lib, ... }:

# Declarative partitioning.
#
# The device is not written here: it comes from `rig.disk.device`, which
# flake.nix sets per rig. This file owns the LAYOUT, which is identical on
# every machine.
#
# The partition NAMES matter beyond cosmetics. Disko derives the installed
# system's fileSystems from them, as
#   /dev/disk/by-partlabel/disk-main-ESP   -> /boot
#   /dev/disk/by-partlabel/disk-main-root  -> /
# so the running system never refers to the install-time device path at all.
# Two consequences worth knowing:
#
#   * `nixos-rebuild switch` against any of the flake's miner entries is safe
#     on an installed rig — a different `rig.disk.device` changes nothing it
#     mounts, and rebuilds never run the partitioner.
#   * Renaming the disk (`main`) or a partition (`ESP`/`root`) rewrites those
#     paths, and an already-installed rig would stop finding its root
#     filesystem at the next boot.
#
# This layout is UEFI (GPT + ESP). If a rig
# is old enough to be BIOS-only, see the alternative at the bottom.

{
  options.rig.disk.device = lib.mkOption {
    type = lib.types.str;
    default = "/dev/sda";
    example = "/dev/disk/by-id/ata-SAMSUNG_SSD_860_EVO_500GB_S3Z2NB0K123456A";
    description = ''
      Whole disk to partition at install time. Set per rig in flake.nix.

      Prefer a /dev/disk/by-id/ path: nixos-anywhere runs the partitioner
      inside a kexec'd installer, where kernel enumeration order — and so
      which disk is called sda — is not guaranteed to match what you saw on
      the running machine.

      Only ever read by the disko script. The installed system mounts by
      partition label, so this value is inert after installation.
    '';
  };

  config.disko.devices.disk.main = {
    device = config.rig.disk.device;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        swap = {
          size = "4G";
          content = {
            type = "swap";
            randomEncryption = true;
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  # Disko sets fileSystems for us, so there is no hardware-configuration.nix
  # to generate: hosts/miner/default.nix supplies the kernel modules and CPU
  # microcode that a generated one would have contained.
  #
  # The bootloader is deliberately NOT set here — hosts/miner/default.nix owns
  # it. Setting it in both places means the BIOS/legacy switch described below
  # only half-applies: you would disable systemd-boot in default.nix and this
  # file would still turn it back on, giving you a conflicting-definition
  # error at best and an unbootable disk at worst.
}

# ---------------------------------------------------------------------------
# BIOS / legacy-boot alternative
# ---------------------------------------------------------------------------
# If the machine predates UEFI, replace the ESP partition above with:
#
#   boot = {
#     size = "1M";
#     type = "EF02";   # BIOS boot partition
#   };
#
# ...and in hosts/miner/default.nix swap the loader for:
#
#   boot.loader.grub = {
#     enable = true;
#     device = config.rig.disk.device;
#   };
#   boot.loader.systemd-boot.enable = false;
#
# Unlike the old ISO-based install, this no longer needs a separate build
# artifact — nixos-anywhere builds whatever the target's flake entry says.
