{
  description = "Remotely controllable Monero CPU mining rig on NixOS (XMRig + Glances)";

  inputs = {
    # Bump to nixos-26.05 once you're ready; 25.11 is the conservative choice.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Declarative disk partitioning.
    #
    # Pinned, and not to the newest commit. disko's test harness — which is
    # what backs `system.build.installTest`, and so `nixos-anywhere --vm-test`
    # — calls nixpkgs' nixos/lib/qemu-common.nix. That function's signature
    # differs across nixpkgs branches:
    #
    #   nixos-25.11            { lib, pkgs }
    #   nixos-26.05, unstable  { lib, stdenv }
    #
    # disko switched to the `stdenv` form in ec90d55 (2026-01-20), so every
    # disko after that evaluates against 26.05 and fails against the 25.11
    # pinned above, with `function 'anonymous lambda' called without required
    # argument 'pkgs'`. This rev is the commit immediately before that switch.
    #
    # It costs nothing: against this nixpkgs, disko ff8702b4 (its current head)
    # and this rev produce a byte-identical system.build.toplevel, and
    # partitioning scripts that differ only in one comment. It only buys back
    # the ability to dry-run an install.
    #
    # Drop the rev when nixpkgs moves to nixos-26.05.
    disko = {
      url = "github:nix-community/disko/5ae05d98d2bebc0a9521c9fc89bd2e5cffa05926";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # One config, one disk. Everything else about a rig — core count, 1 GB
      # page support, hostname, NIC name, worker name — is still detected at
      # runtime, so these entries differ only in which block device gets
      # erased at install time.
      #
      # by-id rather than /dev/sdX: the kernel hands out sdX in enumeration
      # order, and an installer that happens to see the disks in a different
      # order would partition the wrong one. by-id names the hardware.
      mkMiner = device: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/miner
          ./modules/mining.nix
          ./modules/monitoring.nix
          ./modules/power.nix
          disko.nixosModules.disko
          ./hosts/miner/disko.nix
          { rig.disk.device = device; }
        ];
      };
    in
    {
      # ---------------------------------------------------------------------
      # Installed systems.
      #
      # Install a new rig (wipes the disk named in its entry):
      #   nix run github:nix-community/nixos-anywhere -- \
      #     --flake .#miner-a1b2c3d4 --target-host admin@192.168.1.42
      #
      # Update one that already runs:
      #   nixos-rebuild switch --flake .#miner --target-host admin@<ip> --use-remote-sudo
      #
      # `miner` is the generic entry, and the one to use for rebuilds: the
      # disk device is inert once the machine is installed (disko derives the
      # installed system's fileSystems from partition *labels*, not from this
      # path), so a rebuild against .#miner cannot repartition anything.
      # ---------------------------------------------------------------------
      nixosConfigurations = {
        # The generic entry. Partitions /dev/sda, so it installs as-is on a
        # machine with a single SATA disk — and it is the entry to target for
        # every rebuild, whichever entry installed the rig.
        miner = mkMiner "/dev/sda";

        # One entry per rig otherwise, named after the disk it erases. Get that
        # path from the target itself:
        #
        #   ssh admin@<ip> 'ls -l /dev/disk/by-id/ | grep -v part'
        #
        # then add a line like:
        #
        #   miner-a1b2c3d4 = mkMiner "/dev/disk/by-id/ata-<MODEL>_<SERIAL>";
      };

      packages.${system} = {
        # Boot the miner config locally. Mining does not really work here (no
        # MSR access, no 1 GB pages worth having) but every service starting
        # proves the config evaluates.
        #   nix build .#vm && ./result/bin/run-miner-vm
        #
        # The memory bump is not optional. `system.build.vm` defaults to
        # `virtualisation.memorySize = 1024`, and modules/mining.nix reserves
        # 2.5 GiB of 2 MB pages plus 3 GiB of 1 GB pages before userspace
        # starts. On a 1 GiB guest that is not a failure but a machine that
        # never finishes booting -- the same trap documented for installTest
        # below, which sidesteps it by turning mining off instead. Here mining
        # stays on, because a smoke test that skips the main unit is not one.
        # Lower this if your host cannot spare it; do not remove it.
        vm =
          (self.nixosConfigurations.miner.extendModules {
            modules = [{ virtualisation.vmVariant.virtualisation.memorySize = 8192; }];
          }).config.system.build.vm;

        # Dry-run of a real install: partition a scratch disk in a VM with the
        # very script nixos-anywhere would run, install the system onto it,
        # boot the result, and check it came up.
        #   nix build .#installTest
        #
        # This is what `nixos-anywhere --vm-test` builds, with one change it
        # has no flag for. That flag builds
        # `config.system.build.installTest`, which disko generates with
        # `virtualisation.emptyDiskImages = 4096` hardcoded — a 4 GiB scratch
        # disk. This layout wants 512 MiB of ESP plus 4 GiB of swap before the
        # root filesystem starts, so sgdisk fails on partition 2 with
        # `Could not create partition 2 from 1050624 to 9439231`, and the
        # installed system would not have fit anyway. Calling disko's test
        # generator directly is the only way to size the disk, since the
        # `disko.tests.*` options do not pass `extraInstallerConfig` through.
        installTest =
          let
            miner = self.nixosConfigurations.miner;
            # Same arguments disko's own module.nix passes when it builds
            # diskoLib. Imported here rather than read back out of the
            # evaluated config, because `config._module` is not accessible
            # from outside the module system.
            diskoLib = import "${disko}/lib" {
              inherit (nixpkgs) lib;
              rootMountPoint = miner.config.disko.rootMountPoint;
              makeTest = import "${nixpkgs}/nixos/tests/make-test-python.nix";
              eval-config = import "${nixpkgs}/nixos/lib/eval-config.nix";
              qemu-common = import "${nixpkgs}/nixos/lib/qemu-common.nix";
            };
          in
          diskoLib.testLib.makeDiskoTest {
            inherit pkgs;
            inherit (miner) extendModules;
            name = "miner-install";
            disko-config = builtins.removeAttrs miner.config [ "_module" ];
            testMode = "direct";
            efi = true;
            extraInstallerConfig = {
              # Room for ESP + swap + a root that holds the whole closure,
              # linux-firmware included. Sparse, so this costs nothing.
              virtualisation.emptyDiskImages = nixpkgs.lib.mkForce [ 32768 ];
              # nixos-install in 1 GiB (the test default) is tight.
              virtualisation.memorySize = 4096;
            };

            # Mining off for the boot check, and only there.
            #
            # disko starts the second VM — the one booted off the disk that
            # was just installed — with `-m 1024` hardcoded in its test
            # script, with no option to change it. modules/mining.nix asks the
            # kernel for `vm.nr_hugepages = 1280`, i.e. 2.5 GiB of 2 MB pages,
            # plus 3 GiB of 1 GB pages on the command line. On a 1 GiB machine
            # that is not a failure, it is a machine that never stops trying:
            # journald flushes caches under memory pressure forever and boot
            # never reaches local-fs.target.
            #
            # What this dry-run is for is the install path — partition, format,
            # mount by label, install a bootloader, come back up off the disk.
            # None of that involves XMRig. The real rigs have 8-32 GiB and
            # allocate the pool at boot without noticing.
            extraSystemConfig = {
              rig.mining.enable = nixpkgs.lib.mkForce false;
            };
          };
      };

      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
