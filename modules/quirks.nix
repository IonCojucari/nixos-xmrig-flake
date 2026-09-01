{ config, lib, ... }:

let
  cfg = config.rig.quirks;
in
{
  # ---------------------------------------------------------------------------
  # Per-machine firmware workarounds.
  #
  # Everything here defaults to "do nothing", because these are properties of
  # one motherboard, not of the fleet. Set them from hosts/miner/local.nix on
  # the machine that needs them -- never from rig.nix, which is the generic
  # image every rig shares.
  # ---------------------------------------------------------------------------
  options.rig.quirks = {
    maskGpes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "0x69" ];
      description = ''
        ACPI General Purpose Events to mask before the kernel ever evaluates
        them, as hex strings.

        Some firmware ships a _Lxx / _Exx handler that calls a symbol its own
        DSDT never defines. Every time that event fires the kernel walks the
        broken method, fails, and logs several lines. When the event re-arms in
        a loop the result is an interrupt storm that floods the console and can
        stop the machine reaching a login prompt -- before the kernel gets far
        enough to auto-disable the GPE on its own.

        Masking is safe precisely because the handler is broken: no working
        functionality is attached to it. But GPE numbers are assigned by each
        board independently, so the same number is a real wake or thermal event
        elsewhere -- which is why this belongs in a per-machine file.

        Known: ASUS Z170-DELUXE, BIOS 1302 -- \_GPE._L69 calls the undefined
        \_GPE._L69.D1F0. Mask "0x69".
      '';
    };
  };

  config = {
    boot.kernelParams = map (gpe: "acpi_mask_gpe=${gpe}") cfg.maskGpes;
  };
}
