{ lib, ... }:

# The one list of source ranges allowed to reach this rig's LAN-only services.
#
# It lives here rather than once per module because it used to be declared
# twice -- `rig.mining.lanCidrs` and `rig.monitoring.lanCidrs`, same type, same
# default, same warning comment copied across. Two options that must agree is
# one option with a way to disagree: narrowing the firewall for the XMRig API
# and forgetting Glances (or the reverse) is a silent half-fix, and the failure
# mode is a port that stops answering with nothing logged, because the packets
# are dropped by the default-deny input policy before any service sees them.
#
# Imported by modules/mining.nix and modules/monitoring.nix. Importing the same
# path from several modules is idempotent in NixOS, so neither module has to
# assume the other was loaded.

{
  options.rig.lanCidrs = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ "192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12" ];
    description = ''
      Source ranges allowed to reach the rig's LAN-only services: the XMRig
      HTTP API and Glances.

      Defaults to the RFC1918 ranges rather than one hardcoded /24, because the
      rigs move between networks and pinning this to a single /24 is what
      silently firewalled off the API the last time one did. These are
      unroutable ranges, so this is never internet-facing, and both services
      additionally require a credential of their own.

      An empty list closes both ports to everyone.
    '';
  };
}
