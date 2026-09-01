{ config, pkgs, lib, ... }:

# Monero mining.
#
# This module used to be able to trade hashrate for efficiency, through
# `rig.mining.efficiency`: a per-rig ceiling on the CPU frequency, expressed as
# a percentage of that CPU's own range, with a `rig-cpu-tune` unit applying it
# at boot and after every resume and an /etc/rig/max-freq-percent file
# overriding it per machine. It existed because hashes per watt peak well below
# full clock, and by a large margin -- measured across four rigs, the optimum
# sat at 30% of range on one and 50-70% on the other three.
#
# All of it has been removed, on purpose: every rig now runs flat out. What
# that costs is the ability to mine economically on purchased electricity,
# where those optima are what decide whether a rig makes or loses money. What
# it buys is one behaviour instead of two, no per-machine state file to keep in
# step with a flake value, and the full hashrate on a fleet whose electricity
# comes from a solar surplus that would otherwise be exported for nothing.
#
# The measurements are not lost, only unused -- they are in this file's git
# history, along with the tuning script itself, should the trade-off ever need
# revisiting.


let
  cfg = config.rig.mining;

  # Worst-case 2 MB pool: big enough to hold the whole RandomX dataset
  # (2080 MiB) plus a 2 MiB scratchpad per thread, for machines with no usable
  # 1 GB pages. rig-hugepages shrinks this at boot when 1 GB pages did work.
  fullPoolPages = 1280;

  # 2 MB pool when the dataset lives in 1 GB pages: scratchpads only.
  # 128 pages = 256 MiB, ample for any core count.
  scratchpadPoolPages = 128;

  # Shell fragments for the values that can only be known on the running
  # machine. This is what makes one ISO usable on several different rigs.
  workerExpr =
    if cfg.pool.workerName == null
    then ''"$(cat /proc/sys/kernel/hostname)"''
    else lib.escapeShellArg cfg.pool.workerName;

  # XMRig config, minus everything per-machine. The access token, the worker
  # name and the real 1 GB page availability are merged in at start time; see
  # xmrig-start below.
  xmrigConfig = pkgs.writeText "xmrig.json" (builtins.toJSON {
    # true, so that a config pushed to the HTTP API is written back to
    # /var/lib/xmrig/config.json rather than living only in the running
    # process. That is what makes a pool chosen from Home Assistant survive a
    # restart -- see the pool-carrying block in xmrig-start.
    #
    # The usual objection to autosave is that XMRig also writes back its
    # auto-detected thread layout, freezing a decision that should be remade on
    # the machine as it is now. That does not apply here: xmrig-start rebuilds
    # this file from the store on every start and carries exactly one field
    # across, so anything else XMRig saved is discarded the next time it boots.
    autosave = true;
    background = false;
    colors = false;

    cpu = {
      enabled = true;
      "huge-pages" = true;
      "huge-pages-jit" = true;
      "max-threads-hint" = cfg.maxThreadsHint;

      # false = "prefer hashrate over system responsiveness". XMRig defaults
      # this to true, which makes every RandomX thread sched_yield() in its
      # inner loop so the desktop stays smooth. This box has no desktop, and
      # the yields cost real hashrate -- badly so when the service is also
      # CPU-capped, because each yield lands the thread at the back of a queue
      # it then waits a full cgroup period to leave.
      yield = false;
    };

    # CPU-only rig: explicitly off so XMRig doesn't probe for GPUs.
    opencl.enabled = false;
    cuda.enabled = false;

    randomx = {
      # Overridden at start time with what the kernel actually reserved.
      "1gb-pages" = false;
      mode = "auto";
      rdmsr = true;
      wrmsr = true;
      "cache_qos" = false;
      numa = true;
    };

    http = {
      enabled = true;
      host = "0.0.0.0";
      port = cfg.apiPort;
      # "access-token" is injected into a copy of this file at start time by
      # xmrig-start below; it is deliberately absent from the store copy.
      restricted = false;
    };

    pools = [{
      # Overridden at start time with the pool last chosen over the API, if one
      # was and this value has not changed since.
      url = cfg.pool.url;
      user = cfg.pool.wallet;
      # Overridden at start time with the per-machine worker name.
      pass = "unset";
      tls = true;
      keepalive = true;
      nicehash = false;
    }];

    # An hour between hashrate lines meant the journal held no evidence that
    # the rigs were mining at a fraction of their speed. Once a minute is
    # cheap and makes the fault visible in `journalctl -u xmrig`.
    "print-time" = 60;
    "health-print-time" = 60;

    # Both rigs logged `DNS error: "unknown node or service"` and connects to
    # a literal `::` at boot: XMRig had asked for an AAAA record and been
    # handed nothing usable. There is no IPv6 on this LAN, so don't ask.
    dns = {
      ipv6 = false;
      ttl = 30;
    };

    # Also what covers the wake-up from `rig-power suspend`. S3 freezes the
    # process with its socket still open, and the pool has long since dropped
    # the other end, so on resume XMRig holds a connection that is dead
    # without being closed. Nothing here has to detect that: the first write
    # that fails -- a share submission, or the keepalive above -- fails the
    # connection, and XMRig then redials on its own, waiting `retry-pause`
    # seconds between attempts and giving up on the pool after `retries` of
    # them (with a single pool configured, "giving up" means starting over).
    #
    # So the cost of a wake is bounded by how long XMRig takes to *notice*,
    # not by how long it takes to reconnect: worst case is roughly one
    # keepalive interval before it tries anything, plus one retry-pause. The
    # hashing itself never stopped -- the dataset is still in RAM -- so this
    # window costs shares, not a restart.
    retries = 5;
    "retry-pause" = 5;
  });

  # Right-sizes the 2 MB hugepage pool once the kernel has settled.
  #
  # 1 GB pages can only be reserved by the kernel at boot, so we always ask for
  # them and always pre-allocate the worst-case 2 MB pool. Growing a hugepage
  # pool later is unreliable (physical memory fragments), but *shrinking* one
  # always works -- so we over-reserve early and give the memory back here if
  # the 1 GB reservation actually succeeded. That way a single image is correct
  # on machines with and without the pdpe1gb CPU flag.
  rigHugepages = pkgs.writeShellScript "rig-hugepages" ''
    set -euo pipefail

    reserved_1g=0
    if [ -r /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages ]; then
      reserved_1g=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)
    fi

    if [ "$reserved_1g" -ge 3 ]; then
      want=${toString scratchpadPoolPages}
      echo "rig-hugepages: $reserved_1g x 1GB pages reserved -> dataset uses those;" \
           "shrinking 2MB pool to $want pages (scratchpads only)."
    else
      want=${toString fullPoolPages}
      echo "rig-hugepages: no usable 1GB pages -> 2MB pool must hold the dataset;" \
           "keeping $want pages."
    fi

    echo "$want" > /proc/sys/vm/nr_hugepages
    got=$(cat /proc/sys/vm/nr_hugepages)
    echo "rig-hugepages: 2MB pool now $got pages ($((got * 2)) MiB)."

    if [ "$got" -lt "$want" ]; then
      echo "rig-hugepages: WARNING only got $got of $want pages." >&2
      echo "rig-hugepages: expect 'huge pages <100%' and reduced hashrate." >&2
    fi
  '';

  # Merges the per-machine bits into the config at start time, in a 0700 state
  # dir outside the Nix store. Using `jq --rawfile` (filename on the command
  # line, not the token itself) keeps the secret out of this process's argv and
  # out of `ps`/`/proc/<pid>/cmdline`, unlike a CLI flag.
  #
  # /var/lib rather than /run, and that is the whole point of the directory
  # change: XMRig writes this file back when a new config is pushed to its HTTP
  # API, which is how Home Assistant repoints a rig at another pool. In /run
  # that choice lasted until the next reboot. Here it lasts, and the block
  # below is what carries it into each freshly generated config.
  xmrigStart = pkgs.writeShellScript "xmrig-start" ''
    set -euo pipefail
    umask 077

    # Fail closed. The HTTP API runs with `restricted = false` (that is what
    # makes pause/resume work), so starting without a token would expose
    # unauthenticated miner control to the LAN. Refusing to start is correct.
    if [ ! -s /etc/xmrig/token ]; then
      echo "xmrig: /etc/xmrig/token is missing or empty — refusing to start" >&2
      echo "  sudo install -Dm600 /dev/stdin /etc/xmrig/token <<< \"\$(openssl rand -hex 24)\"" >&2
      exit 1
    fi

    # Which pool to start on.
    #
    # Two sources disagree, and the rule between them is: the flake wins when
    # it has changed, otherwise the machine keeps what it was last told.
    #
    # `/var/lib/xmrig/pool-default` records the flake's url as of the last start. If it
    # still matches, nobody has edited the flake since the pool was last chosen
    # remotely, so the remembered choice is the more recent instruction and it
    # stands. If it differs, someone has just rebuilt the rig with a new pool
    # in hand -- a deliberate act, and the newer one -- so that wins and the
    # remembered choice is dropped.
    #
    # Without this, one of the two would be unreachable: either a rebuild could
    # never move a rig that had been switched from Home Assistant, or a reboot
    # would silently undo every switch.
    default_pool=${lib.escapeShellArg cfg.pool.url}
    pool="$default_pool"

    baseline=""
    if [ -r /var/lib/xmrig/pool-default ]; then
      baseline=$(cat /var/lib/xmrig/pool-default)
    fi

    if [ "$baseline" = "$default_pool" ] && [ -s /var/lib/xmrig/config.json ]; then
      # `// empty` rather than a default: a config.json that is present but
      # unreadable (a truncated write, a hand-edit that lost a brace) must fall
      # back to the flake's pool, not abort the start.
      remembered=$(${pkgs.jq}/bin/jq -r '.pools[0].url // empty' \
        /var/lib/xmrig/config.json 2>/dev/null || true)
      if [ -n "$remembered" ]; then
        pool="$remembered"
      fi
    fi

    if [ "$pool" != "$default_pool" ]; then
      echo "xmrig: keeping the pool last chosen over the API -> $pool"
    fi
    printf '%s' "$default_pool" > /var/lib/xmrig/pool-default

    worker=${workerExpr}
${lib.optionalString (cfg.pool.workerName == null) ''
    # Backstop. If rig-hostname has not run (or ran too late), the hostname is
    # still "localhost" — and every rig would then report as the same worker,
    # silently defeating per-rig pool stats. Derive the same name
    # directly from the machine-id instead.
    if [ -z "$worker" ] || [ "$worker" = "localhost" ]; then
      worker="miner-$(cut -c1-8 /etc/machine-id)"
      echo "xmrig: hostname not set yet, using machine-id -> $worker" >&2
    fi
''}
    # Report what the kernel actually gave us, not what we hoped for at build
    # time: telling XMRig 1gb-pages=true when none were reserved makes it fall
    # back silently and mine slowly.
    onegb=false
    if [ "$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)" -ge 3 ]; then
      onegb=true
    fi

    echo "xmrig: worker=$worker 1gb-pages=$onegb"

    # Written via a temporary file and renamed: XMRig watches this path and
    # reloads on change, so a reader could otherwise catch a half-written
    # config. Nothing is watching it at this instant -- the miner is not
    # running yet -- but the same file is rewritten by hand often enough that
    # the atomic form is worth having be the only form.
    ${pkgs.jq}/bin/jq \
      --rawfile token /etc/xmrig/token \
      --arg worker "$worker" \
      --arg pool "$pool" \
      --argjson onegb "$onegb" \
      '.http["access-token"] = ($token | rtrimstr("\n"))
       | .pools[0].url = $pool
       | .pools[0].pass = $worker
       | .randomx["1gb-pages"] = $onegb' \
      ${xmrigConfig} > /var/lib/xmrig/config.json.new
    mv /var/lib/xmrig/config.json.new /var/lib/xmrig/config.json

    exec ${pkgs.xmrig}/bin/xmrig --config=/var/lib/xmrig/config.json
  '';

in
{
  imports = [ ./lan.nix ];

  options.rig.mining = {
    enable = lib.mkEnableOption "Monero CPU mining";

    pool = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "pool.supportxmr.com:443";
        description = "Pool address. Prefer a PPS/PPS+ pool if the rig mines intermittently.";
      };
      wallet = lib.mkOption {
        type = lib.types.str;
        description = "Your Monero wallet address.";
      };
      workerName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Worker name reported to the pool. Leave null to use the machine's
          hostname, which is what lets several rigs share one image and still
          show up separately in the pool's worker list.
        '';
      };
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "XMRig HTTP API port. LAN only — never expose this.";
    };

    maxThreadsHint = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 100;
      description = ''
        Percentage of auto-detected threads to use. RandomX wants ~2 MB of L3
        per thread, so XMRig usually picks correctly on its own. Lower this if
        the machine does other work.
      '';
    };

    oneGbPages = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ask the kernel to reserve 1 GB hugepages for the RandomX dataset.
        Harmless on CPUs without the pdpe1gb flag: the reservation simply does
        not happen, rig-hugepages keeps the full 2 MB pool instead, and XMRig
        is told at start time which of the two it actually got.
      '';
    };

  };

  config = lib.mkIf cfg.enable {

    # The same class of mistake the SSH key assertion catches, and with a
    # quieter failure: a rig installed with the placeholder wallet mines
    # perfectly happily while the pool rejects every login, and the only local
    # symptom is a repeating error in `journalctl -u xmrig`.
    assertions = [{
      assertion = cfg.pool.wallet != "YOUR_MONERO_ADDRESS";
      message = ''
        rig.mining.pool.wallet is still the placeholder: the rig would mine
        into nobody's account. Set your Monero address in
        hosts/miner/rig.nix before installing.
      '';
    }];

    # Every rig runs its CPU flat out. There is no longer a way to ask for
    # anything else, and that is deliberate -- see the note at the top of this
    # module.
    #
    # NixOS applies this from a boot-time unit that writes every policy's
    # scaling_governor, which is also why nothing here has to handle resume:
    # a governor written to sysfs survives S3, and it was the old ceiling --
    # a numeric scaling_max_freq -- that did not.
    #
    # On amd-pstate-epp and intel_pstate `performance` does not merely mean
    # "ramp up quickly": it pins the P-state request to maximum and forces the
    # energy/performance preference to `performance` with it. That is exactly
    # what is wanted here, and it is worth being clear that it is NOT what a
    # 100% ceiling used to give -- that left the governor on `powersave` and
    # the EPP on `power`, which the hardware honoured: 16743 H/s measured that
    # way against 18941 H/s like this, on the same machine.
    powerManagement.cpuFreqGovernor = "performance";

    # -------------------------------------------------------------------------
    # Kernel: hugepages + writable MSRs. This is the part that actually moves
    # the hashrate needle, and the main reason NixOS is pleasant here.
    # -------------------------------------------------------------------------
    boot.kernelParams = [
      "msr.allow_writes=on"
    ] ++ lib.optionals cfg.oneGbPages [
      "hugepagesz=1G"
      "hugepages=3"
    ];

    boot.kernelModules = [ "msr" ];

    # Always pre-allocate the worst case at boot, while memory is unfragmented.
    # rig-hugepages hands most of it back moments later if 1 GB pages worked.
    boot.kernel.sysctl = {
      "vm.nr_hugepages" = fullPoolPages;
    };

    systemd.services.rig-hugepages = {
      description = "Right-size the 2 MB hugepage pool for RandomX";
      wantedBy = [ "multi-user.target" ];
      before = [ "xmrig.service" ];
      after = [ "systemd-sysctl.service" ];

      # This unit shrinks the 2 MB pool that boot.kernel.sysctl above sets to
      # its worst-case size. systemd-sysctl re-applies that sysctl whenever
      # /etc/sysctl.d changes -- nixpkgs gives it exactly this restartTrigger --
      # so without the same trigger here, a rebuild touching any sysctl would
      # restore the 2.5 GiB pool and leave it there: RemainAfterExit means this
      # oneshot does not re-run, and nothing would shrink it again until the
      # next reboot.
      restartTriggers = [ config.environment.etc."sysctl.d/60-nixos.conf".source ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${rigHugepages}";
      };
    };

    # -------------------------------------------------------------------------
    # XMRig service
    # -------------------------------------------------------------------------
    systemd.services.xmrig = {
      description = "XMRig Monero miner";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "rig-hugepages.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        # Root is required for MSR writes and hugepage allocation. This is the
        # documented XMRig setup; the hardening below limits the blast radius.
        User = "root";
        # 0700: this file carries the HTTP access token, and now outlives the
        # boot that wrote it.
        StateDirectory = "xmrig";
        StateDirectoryMode = "0700";
        ExecStart = "${xmrigStart}";
        Restart = "always";
        RestartSec = 10;

        # Deliberately no CPUQuota, no Nice, no CPUWeight, no IO class here.
        #
        # This unit used to carry `CPUQuota = "100%"` under the comment "start
        # throttled". systemd's CPUQuota= is denominated in *one core*, not in
        # the machine: 100% is one core's worth of runtime no matter how many
        # cores exist, and 400% is what "all of a 4-core box" is spelled. So
        # a rig carrying it is pinned to a single core's budget, shared between
        # however many RandomX threads it started, which then spend most of each
        # 100 ms period frozen by the cgroup throttler. The giveaway is machines
        # with quite different CPUs all settling on an identical hashrate: the
        # cap, not the hardware, is setting it.
        #
        # Unthrottled, full stop: nothing else runs on these boxes, so there
        # is no workload for the miner to be polite towards. The proportional
        # throttle that used to live here is gone -- it was only ever there to
        # follow solar surplus, it was never actually reachable from Home
        # Assistant, and every way of expressing it went back through the same
        # CPUQuota= that caused the fault above. Removing it removes the path
        # back to it.

        # Hardening (kept loose enough for MSR/hugepages to work).
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
    };

    # -------------------------------------------------------------------------
    # Restart the miner after a resume, because its MSR tweaks did not survive
    # -------------------------------------------------------------------------
    #
    # XMRig writes a set of model-specific registers at start-up -- the line
    # `msr register values for "intel" preset have been set successfully` in
    # the journal -- and RandomX depends on them heavily. Firmware restores its
    # own MSR state across S3, XMRig never reapplies them, and nothing else
    # knows they exist. So a resumed miner keeps hashing at a permanently
    # reduced rate, with the dataset intact, the hugepages intact, the clocks
    # at maximum and nothing in the log to say anything is wrong.
    #
    # Measured on the i7-6700K rig, 2026-09-01: 2442 H/s after a resume against
    # 3046 H/s once restarted. Same 4000 MHz, same 100% hugepages, 65 °C, zero
    # throttle events. Roughly a quarter of the hashrate, invisible.
    #
    # That matters here far more than it would elsewhere, because suspend is
    # not an edge case on these machines: it is the verb the solar-surplus
    # automation reaches for several times a day, and modules/power.nix offers
    # it precisely because it keeps the RandomX dataset warm. Without this unit
    # the rigs would spend most of their mining time in the degraded state, and
    # the feature that exists to make stopping cheap would quietly be making
    # running expensive.
    #
    # Restarting rather than rewriting the registers here is deliberate. The
    # values are per-microarchitecture and XMRig already chooses them; a second
    # implementation in this file would be one more thing to keep in step with
    # upstream, and wrong in a way that looks exactly like this bug. What the
    # restart costs is one dataset init -- about four seconds with 1 GB pages --
    # against the quarter of the hashrate above. It does mean the warm dataset
    # is not what suspend preserves any more; the fast wake still is.
    #
    # `try-restart`, not `restart`: a miner that was deliberately stopped must
    # stay stopped, and `restart` would start it. Pausing from Home Assistant
    # is unaffected either way -- that goes through the API and leaves the unit
    # running, so this reapplies the MSRs under a paused miner too, which is
    # what should happen.
    #
    # `--no-block` because this unit is itself part of the resume transaction:
    # waiting for a job it has just enqueued into that same transaction is how
    # a deadlock is spelled.
    #
    # For the post-resume.target idiom, and why `after` repeats suspend.target
    # rather than relying on it transitively, see the long note on
    # rig-wol-resume in modules/power.nix.
    systemd.services.rig-xmrig-resume = {
      description = "Restart XMRig after resume so its MSR tweaks are reapplied";
      wantedBy = [ "post-resume.target" ];
      after = [ "suspend.target" "post-resume.service" ];

      serviceConfig = {
        Type = "oneshot";
        # No RemainAfterExit, for the same reason as rig-wol-resume: this has
        # to run again on the second wake, and a start job for a unit still
        # active from the first one would be a no-op.
        ExecStart =
          "${pkgs.systemd}/bin/systemctl --no-block try-restart xmrig.service";
      };
    };

    environment.systemPackages = [ pkgs.xmrig ];

    # Deliberately no sudo rule for `systemctl start/stop xmrig` here.
    #
    # There used to be one, granting the `ha` user four systemctl invocations.
    # Nothing calls them: Home Assistant pauses and resumes the miner through
    # the HTTP API's json_rpc methods, which keep the process alive and the
    # RandomX dataset allocated, so resuming is instant where a restart would
    # cost a minute of dataset init. The rules were also written against the
    # literal user `ha` rather than modules/power.nix's `rig.power.controlUser`,
    # so changing that option would have left half the grant pointing at an
    # account that no longer exists.
    #
    # Machine-level power actions live in modules/power.nix and go through the
    # `rig-power` wrapper, which is one grant, one audit trail, and one name
    # Home Assistant can call without knowing a store path.

    # -------------------------------------------------------------------------
    # Firewall: API reachable from the LAN only
    # -------------------------------------------------------------------------
    # An empty list would emit `ip saddr { }`, which nft rejects at ruleset
    # load time -- taking the whole firewall down, not just this rule.
    networking.firewall.extraInputRules =
      lib.optionalString (config.rig.lanCidrs != [ ]) ''
        ip saddr { ${lib.concatStringsSep ", " config.rig.lanCidrs} } tcp dport ${toString cfg.apiPort} accept
      '';

    # Warn at activation time if the token file is missing. This cannot be a
    # build-time assertion: the token lives outside the Nix store by design, so
    # its presence is only knowable on the running machine. Without it the
    # service refuses to start (see xmrig-start above) and will crash-loop, so
    # this warning is what tells you why.
    system.activationScripts.xmrigToken = ''
      if [ ! -f /etc/xmrig/token ]; then
        echo "WARNING: /etc/xmrig/token is missing — XMRig will fail to start."
        echo "  sudo install -Dm600 /dev/stdin /etc/xmrig/token <<< 'your-secret'"
      fi
    '';
  };
}
