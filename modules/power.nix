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
          #
          # The same file covers S3. There is no separate S3 knob: the kernel
          # reads this one attribute (device_may_wakeup()) both when a driver
          # suspends the card for suspend-to-RAM and when it shuts it down for
          # soft-off, and calls pci_enable_wake() from either path. So nothing
          # extra is needed here for S3 -- what S3 needs is for this script to
          # run *again after every resume*, which is what rig-wol-resume below
          # is for. The BIOS side does differ slightly: S5 needs the standby
          # rail kept alive (ErP off), S3 needs the ACPI GPE behind the PCIe
          # root port armed, and boards usually tie both to the same
          # "Wake on LAN" setting.
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
''}${lib.optionalString cfg.allowSuspend ''
      suspend|sleep)
        note "suspend"
        # Like `off`, this needs the sudo grant rather than the bare
        # account: systemctl asks logind over D-Bus, and logind's polkit
        # defaults for org.freedesktop.login1.suspend are the same as for
        # power-off -- `yes` for an active local session, auth_admin_keep for
        # anything else. An SSH session is "anything else", so the
        # unprivileged `ha` user calling systemctl directly gets
        # "Interactive authentication required" and nothing happens.
        #
        # What it does differently from `off` is when it returns. logind
        # acknowledges the request and suspends after replying, so exit 0
        # here means "accepted", not "asleep", and the caller's SSH
        # connection then *freezes* mid-session rather than being closed --
        # it is the machine that stops, not the socket. Anything waiting on
        # this sees a read timeout rather than a clean disconnect.
        #
        # Hence the note() above the exec rather than after it: the journal
        # line is written while the machine is still running, and it is the
        # only durable record of who asked.
        exec ${pkgs.systemd}/bin/systemctl suspend
        ;;
''}      status)
        # Lets the caller check what it is allowed to do without having to
        # attempt it.
        #
        # The format is load-bearing, not decorative: the Home Assistant
        # integration builds its buttons by looking for a line starting with
        # "actions:" and splitting the rest on commas
        # (homeassistant-xmrig, custom_components/xmrig_remote_miner/ssh.py,
        # _parse_actions). Order does not matter to it -- it makes a set --
        # but the prefix, the commas and the verb spellings do.
        echo "actions: off${lib.optionalString cfg.allowReboot ", reboot"}${lib.optionalString cfg.allowSuspend ", suspend"}, status"
        ;;
      *)
        echo "usage: rig-power off${lib.optionalString cfg.allowReboot "|reboot"}${lib.optionalString cfg.allowSuspend "|suspend"}|status" >&2
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

        The same magic packet is what brings the rig out of S3, so this is
        also what `rig.power.allowSuspend` depends on. Enabling this option
        additionally installs rig-wol-resume, which re-arms the card after
        every resume -- without it a rig wakes from the first suspend and
        then, on some drivers, from no later one.
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
        and nothing else, unless `allowReboot` or `allowSuspend` widen it by
        exactly one verb each. This account is reachable with a key that lives
        on the Home Assistant box, so its rights should stay boring.
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

    allowSuspend = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also allow `rig-power suspend` (S3, suspend-to-RAM).

        On by default, unlike `allowReboot`, and the reasoning is not "it is
        another power verb, be consistent" -- it is that this one is strictly
        less destructive than the `off` that is already unconditional.

        S3 keeps the RAM refreshed, so the RandomX dataset and the hugepage
        pool are still there on the other side: the rig resumes in seconds
        where a poweroff pays a full boot plus a dataset re-initialisation.
        It also adds no new way to lose a rig. Coming back from S3 uses the
        very same magic packet as coming back from S5, so on a rig where
        Wake-on-LAN works, suspend works; on a rig where it does not, `off`
        was already a console trip and suspend is no worse. There is no
        equivalent of the reboot loop to get stuck in.

        The reason to turn it off is firmware, not policy: a board that goes
        into S3 and does not come out, or comes out with a dead NIC, is a
        machine you have to walk to. Test it once per board model before
        letting Home Assistant cycle a rig on solar surplus several times a
        day -- `rig-power suspend`, then wake it, then check
        `journalctl -u rig-wol-resume` says the card was re-armed.
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

      # Re-arm after every resume. This is the unit that makes `rig-power
      # suspend` a round trip rather than a one-way one.
      #
      # rig-wol above covers boot (ExecStart) and shutdown (ExecStop, which is
      # what RemainAfterExit buys). Neither fires for a sleep cycle: systemd
      # does not stop units to suspend, it freezes the whole machine and thaws
      # it. So on a rig that only ever suspends, the WoL flag is set exactly
      # once, at boot -- and several drivers, r8169 first among them, drop it
      # when the link goes down, which is precisely what suspending does to
      # the link. The failure mode is the nasty one: the first suspend/wake
      # cycle works because boot armed the card, and some later one does not,
      # so it reads as flaky hardware rather than as missing configuration.
      #
      # wantedBy = post-resume.target is the NixOS idiom, not a systemd one:
      # upstream systemd has no post-resume.target. NixOS defines it in
      # nixos/modules/config/power-management.nix as a target that is
      # `wantedBy = [ "sleep.target" ]` and requires a post-resume.service
      # ordered `after = [ "suspend.target" "hibernate.target" ... ]`. Because
      # sleep.target pulls the target in on the way *down*, and the service it
      # requires cannot finish until suspend.target has been reached -- which
      # only happens once the machine has actually come back -- everything
      # hanging off this target runs on the far side of the sleep. The same
      # `after = [ "suspend.target" ]` is repeated here rather than relied on
      # transitively: Wants= carries no ordering, so without it this unit
      # would be free to run on the way into the suspend instead.
      #
      # It also means this depends on powerManagement.enable, which is NixOS's
      # default true and is what defines the target at all. Nothing in this
      # flake turns it off; modules/mining.nix only sets its cpuFreqGovernor.
      #
      # Not gated on rig.power.allowSuspend: the rig can be put to sleep by
      # something other than the wrapper -- an admin over SSH, logind -- and
      # arming a card that is already armed costs one ethtool call.
      systemd.services.rig-wol-resume = {
        description = "Re-arm Wake-on-LAN after resume from suspend";
        wantedBy = [ "post-resume.target" ];
        after = [ "suspend.target" "post-resume.service" ];

        serviceConfig = {
          Type = "oneshot";
          # Deliberately no RemainAfterExit here, the opposite of rig-wol.
          # This unit has to be re-runnable: post-resume.target is restarted
          # on every resume, and a start job for a unit that is still active
          # from the last one is a no-op. Ending inactive is what makes the
          # second wake re-arm the card as well as the first.
          ExecStart = "${rigWol}";
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
