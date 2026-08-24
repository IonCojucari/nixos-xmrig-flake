{ config, pkgs, lib, ... }:

let
  cfg = config.rig.power;

  # Arms Wake-on-LAN on every wired NIC the machine actually has.
  #
  # This deliberately does not use `networking.interfaces.<name>.wakeOnLan`:
  # that option needs an interface name at build time, and this image is built
  # without one on purpose: the LAN port is called something different on
  # almost every board, and a machine may have several with only one cabled.
  # So: discover at runtime.
  rigWol = pkgs.writeShellScript "rig-wol" ''
    set -uo pipefail

    found=0

    for path in /sys/class/net/*; do
      iface=$(basename "$path")

      [ "$iface" = "lo" ] && continue
      # Physical devices only -- skips bridges, veth, wireguard and friends.
      [ -e "$path/device" ] || continue
      # ARPHRD_ETHER. Wi-Fi reports the same type, so exclude it explicitly:
      # waking over Wi-Fi is WoWLAN, a different mechanism that these boards
      # do not do, and arming it here would only produce confusing logs.
      [ "$(cat "$path/type" 2>/dev/null)" = "1" ] || continue
      [ -e "$path/wireless" ] && continue

      mac=$(cat "$path/address")
      supports=$(${pkgs.ethtool}/bin/ethtool "$iface" 2>/dev/null \
                   | sed -n 's/^[[:space:]]*Supports Wake-on:[[:space:]]*//p')

      case "$supports" in
        *g*)
          found=1
          ${pkgs.ethtool}/bin/ethtool -s "$iface" wol g >/dev/null 2>&1 || true

          # Two separate switches have to be on, and only one of them is
          # ethtool's. `wol g` tells the NIC to watch for magic packets; PCI
          # PME is what lets it actually pull the board out of S5. A NIC can
          # come up with power/wakeup=disabled, i.e. armed but unable to wake
          # anything -- which looks identical to working until you try it.
          if [ -w "$path/device/power/wakeup" ]; then
            echo enabled > "$path/device/power/wakeup" 2>/dev/null || true
          fi

          wol=$(${pkgs.ethtool}/bin/ethtool "$iface" 2>/dev/null \
                  | sed -n 's/^[[:space:]]*Wake-on:[[:space:]]*//p')
          pme=$(cat "$path/device/power/wakeup" 2>/dev/null || echo "n/a")
          echo "rig-wol: $iface $mac wake-on=$wol pci-wakeup=$pme"

          if [ "$wol" = "d" ]; then
            echo "rig-wol: WARNING $iface accepted no setting — the driver reports Wake-on: d." >&2
          fi
          ;;
        "")
          echo "rig-wol: $iface $mac — ethtool reported nothing, skipped." >&2
          ;;
        *)
          echo "rig-wol: $iface $mac cannot do magic packets (supports: $supports)." >&2
          ;;
      esac
    done

    if [ "$found" = "0" ]; then
      echo "rig-wol: WARNING no wired NIC could be armed; this rig will not wake over LAN." >&2
    fi

    # Never fail the unit. A rig that cannot be woken remotely should still
    # boot and mine; the journal line above is the thing that tells you why
    # Home Assistant's switch does nothing.
    exit 0
  '';
  # A single entry point for the power actions. Granting this script rather
  # than `systemctl poweroff` and `systemctl reboot` separately is better for
  # three reasons: one sudo rule instead of N, a stable name Home Assistant can
  # call without knowing a Nix store path, and above all an audit trail -- a
  # machine that powers itself off at 3 a.m. should leave *who asked* in the
  # journal, which bare `systemctl poweroff` does not.
  rigPower = pkgs.writeShellScriptBin "rig-power" ''
    set -euo pipefail

    action="''${1:-}"
    # sudo(8) preserves the caller here; without it `id -un` would say "root"
    # and the audit trail would be worthless.
    who="''${SUDO_USER:-$(${pkgs.coreutils}/bin/id -un)}"

    note() {
      ${pkgs.util-linux}/bin/logger -t rig-power "$1 requested by $who"
      echo "rig-power: $1 requested by $who"
    }

    case "$action" in
      off|poweroff|stop)
        note "poweroff"
        exec ${pkgs.systemd}/bin/systemctl poweroff
        ;;
${lib.optionalString cfg.allowReboot ''
      reboot|restart)
        note "reboot"
        exec ${pkgs.systemd}/bin/systemctl reboot
        ;;
''}      status)
        # Lets the caller check what it is allowed to do without having to
        # attempt it.
        echo "actions: off${lib.optionalString cfg.allowReboot ", reboot"}, status"
        ;;
      *)
        echo "usage: rig-power off${lib.optionalString cfg.allowReboot "|reboot"}|status" >&2
        exit 1
        ;;
    esac
  '';
in
{
  options.rig.power = {
    enable = lib.mkEnableOption "remote power control (Wake-on-LAN in, shutdown out)";

    wakeOnLan = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Arm Wake-on-LAN on every wired NIC at boot, and re-arm it on the way
        down. Home Assistant's `wake_on_lan` integration then starts the rig
        by sending a magic packet to its MAC.

        This only covers the operating-system half. The board must also be
        told to keep the NIC powered in S5 -- "Power On By PCI-E/PCI" or
        "Wake on LAN" enabled, and ErP/EuP Ready *disabled*, since ErP cuts
        exactly the standby rail the NIC needs. That part is a BIOS trip and
        cannot be done from here.
      '';
    };

    controlUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "ha";
      description = ''
        Unprivileged user granted passwordless `rig-power`, so Home Assistant
        can power the rig down over SSH. null grants nothing.

        The grant is for that one wrapper, not for systemctl: `rig-power off`
        and nothing else, unless `allowReboot` widens it by exactly one verb.
        This account is reachable with a key that lives on the Home Assistant
        box, so its rights should stay boring.
      '';
    };

    allowReboot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Also allow `rig-power reboot`.

        Off by default, and worth keeping that way unless something actually
        needs it: powering a rig down is recoverable with a magic packet,
        whereas a reboot loop is not recoverable remotely at all. Note the
        asymmetry when testing -- a reboot comes back on its own, a poweroff
        only comes back if Wake-on-LAN really works, BIOS included.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [

    (lib.mkIf cfg.wakeOnLan {
      environment.systemPackages = [ pkgs.ethtool ];

      systemd.services.rig-wol = {
        description = "Arm Wake-on-LAN on all wired interfaces";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          Type = "oneshot";
          # RemainAfterExit is what makes ExecStop run at shutdown, and that
          # second call is the point of the unit rather than a nicety: several
          # drivers (r8169 especially) drop the WoL flag when the link is
          # taken down, which is precisely what happens on the way to poweroff.
          # Arming only at boot gives a rig that wakes after a crash but not
          # after a clean shutdown -- the confusing half-working case.
          RemainAfterExit = true;
          ExecStart = "${rigWol}";
          ExecStop = "${rigWol}";
        };
      };
    })

    (lib.mkIf (cfg.controlUser != null) {
      environment.systemPackages = [ rigPower ];

      # The path has to be the one the caller types, not the one it points at:
      # sudo matches the string after PATH resolution and does not follow
      # symlinks. A rule naming "${rigPower}/bin/rig-power" is therefore silent
      # when Home Assistant runs `sudo rig-power off`, which resolves to
      # /run/current-system/sw/bin/rig-power -- sudo then demands a password
      # this account does not have, and the action fails quietly.
      #
      # The /run/current-system link is also the only stable path: the store
      # path changes every time the script is edited, which would break the
      # command on the Home Assistant side at every rebuild.
      security.sudo.extraRules = [{
        users = [ cfg.controlUser ];
        commands = [
          { command = "/run/current-system/sw/bin/rig-power"; options = [ "NOPASSWD" ]; }
          { command = "${rigPower}/bin/rig-power"; options = [ "NOPASSWD" ]; }
        ];
      }];
    })
  ]);
}
