{ ... }:

# Your actual rig settings. Import this from hosts/miner/default.nix,
# or paste the contents in there directly.
#
# This is a GENERIC image: one ISO installs on any number of machines. Anything
# that varies per machine — core count, 1 GB page support, hostname, worker
# name, target disk — is detected at runtime rather than set here. Only things
# that are genuinely the same on every rig belong in this file.

{
  rig.mining = {
    enable = true;
    pool = {
      # SupportXMR is PPLNS. A rig that gets throttled or stopped often is
      # paid more predictably by a PPS/PPS+ pool — worth switching once
      # running.
      url = "pool.supportxmr.com:443";

      # Your Monero address. Worth keeping out of a public fork: pool APIs are
      # unauthenticated, so anyone holding this string can read the hashrate,
      # worker list and unpaid balance it earns.
      wallet = "YOUR_MONERO_ADDRESS";

      # null = use the machine's hostname (miner-<machine-id>), so each rig
      # appears as its own worker in the pool's stats. Set a fixed string only
      # if you want every rig reported as one merged worker.
      workerName = null;
    };

    # Ask for 1 GB pages everywhere. On CPUs without pdpe1gb the reservation
    # silently does not happen, and rig-hugepages keeps the full 2 MB pool
    # instead — so this is safe to leave on for a mixed fleet.
    oneGbPages = true;

    maxThreadsHint = 100; # let XMRig decide based on L3 cache

    # Mine for hashes per watt rather than for peak hashrate, on every rig in
    # the fleet. Left explicit rather than at its default because it is the
    # setting that decides the electricity bill, and because the number below
    # is the one worth revisiting per machine.
    efficiency = {
      enable = true;

      # Frequency ceiling as a percentage of each CPU's own range, applied at
      # runtime. 70 is a starting point near the usual knee of the RandomX
      # curve, not a measured optimum: hashrate falls roughly with the clock,
      # power falls faster, and where the two cross depends on the silicon.
      #
      # Measure it per rig at the wall — package power flatters the result,
      # because VRM and DRAM losses are a real share of what the meter sees.
      # Log hashes and watts at 100, 80, 70 and 60 and keep the best.
      maxFreqPercent = 70;
    };
  };

  # One list for both LAN-only services (XMRig API and Glances), deliberately
  # left at its default (the RFC1918 ranges). Pinning it to a single /24 is
  # what silently firewalled off the API after a rig was moved to another
  # network.
  # rig.lanCidrs = [ "192.168.1.0/24" ];

  rig.monitoring = {
    enable = true;

    # passwordFile left at its default, /etc/glances/password: written per rig
    # by scripts/mk-secrets.sh and shipped with `nixos-anywhere --extra-files`,
    # exactly like the XMRig token. Glances refuses to start without it, which
    # is the point — its API serves the process list and logged-in users, and
    # it used to answer all of RFC1918 with no credential at all.
  };

  rig.power = {
    enable = true;

    # Arm Wake-on-LAN on whatever the wired NIC turns out to be called.
    #
    # Nothing to record here: the Home Assistant integration reads the MAC of
    # the interface holding the default route over SSH, so it needs no MAC in
    # its config and cannot pick the wrong port. Your own notes are still worth
    # keeping —
    #
    #   <rig name>  <ip>  <mac>  (<iface>, <driver>)
    #
    # — because on a board with several ethernet ports and one cable, waking it
    # needs the BIOS set to wake on *that* port, not merely "on LAN".
    wakeOnLan = true;

    # The same account Home Assistant already reaches the rig with, so powering
    # it down needs no new key and no new trust.
    controlUser = "ha";

    # A headless rig is awkward to reach physically, so being able to reboot it
    # remotely is usually worth more than the narrower grant. Safe to test, too,
    # unlike poweroff: a reboot comes back on its own.
    allowReboot = true;

    # Suspend-to-RAM, and the verb the solar-surplus automation should reach
    # for. Restated here rather than left at its default (true) because it is
    # the one that has to be tested per board model: S3 is firmware, and a
    # board that sleeps but does not wake is a walk to the machine. Set it
    # false for a rig that fails that test and Home Assistant stops offering
    # the button, since it builds them from `rig-power status`.
    allowSuspend = true;
  };

  rig.mqtt = {
    # What replaces Home Assistant guessing. The rig says whether it is up,
    # whether it is really mining, and whether it is on its way down, instead
    # of having that inferred from a wattmeter and a start timer — and it
    # takes its power commands on the same connection, which is what makes the
    # SSH account, its key and its sudo rule optional rather than load-bearing.
    enable = true;

    # Your Home Assistant box, running the Mosquitto add-on. Point this at the
    # broker you already have rather than standing up a second one: a broker is
    # a thing that can fall over, and two of them fall over independently.
    #
    # There is no default for this option, on purpose. A rig aimed at the wrong
    # address looks perfectly healthy -- it mines, it answers its API -- while
    # publishing where nobody is listening.
    broker = "192.168.1.42";

    # port, username and interval left at their defaults (1883, `miner`, 30 s),
    # and passwordFile at /etc/mqtt/password: one shared fleet account, written
    # per rig by scripts/mk-secrets.sh and shipped with `nixos-anywhere
    # --extra-files`, exactly like the XMRig token and the Glances password.
  };
}
