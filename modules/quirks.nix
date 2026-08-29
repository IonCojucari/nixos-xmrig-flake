{ config, lib, ... }:

let
  cfg = config.rig.quirks;
in
{
  # ---------------------------------------------------------------------------
  # Workarounds for one machine's firmware.
  #
  # This flake is deliberately a generic image: one ISO installs on any number
  # of rigs, and anything that varies per machine is detected at runtime rather
  # than written down. Firmware bugs are the exception that cannot be, because
  # the workaround has to be on the kernel command line before the kernel is
  # running and could detect anything.
  #
  # So everything here defaults to doing nothing, and a rig that needs one of
  # these opts in from hosts/miner/local.nix -- a file the other rigs simply do
  # not have. Never set these in rig.nix: that file is shared by the whole
  # fleet, and every option below is unsafe to apply blindly to a board that
  # does not need it.
  # ---------------------------------------------------------------------------
  options.rig.quirks = {
    maskGpes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "0x69" ];
      description = ''
        ACPI General Purpose Events to mask before the kernel ever evaluates
        them, given as hex strings.

        Some firmware ships a `_Lxx` / `_Exx` handler that calls a symbol its
        own DSDT never defines. Every time that event fires, the kernel walks
        the broken method, fails, and logs several lines:

          ACPI BIOS Error (bug): Could not resolve symbol [\_GPE._L69.D1F0]
          ACPI Error: Aborting method \_GPE._L69 due to previous error

        Fired a handful of times that is cosmetic, and the kernel eventually
        disables the GPE by itself. Fired in a loop it is an interrupt storm:
        the failing handler floods the console faster than the auto-disable
        heuristic reacts, and the machine can fail to reach a login prompt
        while it does so. That failure is intermittent -- it depends on
        hardware state at POST -- which makes it easy to misread as failing
        hardware, or as a BIOS that needs reflashing.

        Masking costs nothing precisely *because* the handler is broken: no
        working functionality is attached to an event whose method cannot run.

        GPE numbers are assigned by each board independently, though, so the
        same number is a real wake or thermal source on a different machine.
        That is why this is per-rig and empty by default.

        Diagnosis, on the rig:

          # how often it has fired, and whether it is masked already
          cat /sys/firmware/acpi/interrupts/gpe69
          # what the firmware is actually failing at
          dmesg | grep -E 'ACPI (BIOS )?Error'

        A boot that dies before journald flushes leaves almost nothing on disk,
        so `journalctl -b -1` can look calm while the screen was full of this.
        Trust the console, or a photograph of it.

        Known case: ASUS Z170-DELUXE, AMI BIOS 1302 -- `\_GPE._L69` calls the
        undefined `\_GPE._L69.D1F0`. Mask `"0x69"`.
      '';
    };
  };

  config = {
    boot.kernelParams = map (gpe: "acpi_mask_gpe=${gpe}") cfg.maskGpes;
  };
}
