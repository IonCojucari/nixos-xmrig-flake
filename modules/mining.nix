{ config, pkgs, lib, ... }:

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
    autosave = false;
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

  # Puts the CPU where RandomX earns the most hash per watt, rather than where
  # it reaches the highest hashrate.
  #
  # These two are not the same point, and the difference is large. RandomX is
  # memory-latency-bound: above roughly base clock the core spends most of
  # every hash waiting on RAM, so the last few hundred MHz buy a couple of
  # percent hashrate while costing a third of the package power -- boost
  # voltage scales worse than linearly. A rig that is paid in electricity
  # wants the knee of that curve, not its end.
  #
  # Everything here is decided on the running machine for the same reason the
  # rest of this flake is: one image, several rigs, different silicon. What
  # the governor should be is not a constant -- it depends on which cpufreq
  # driver the kernel bound to this CPU:
  #
  #   intel_pstate / amd-pstate-epp (active mode)
  #       `performance` here does not mean "governor that ramps up quickly",
  #       it pins the P-state request to maximum and forces EPP to
  #       performance, which is exactly the 100%-power behaviour we are trying
  #       to leave. `powersave` is the *tunable* governor on these drivers,
  #       and the energy/performance preference underneath it is what actually
  #       chooses the operating point.
  #
  #   intel_cpufreq / amd-pstate (passive) / acpi-cpufreq
  #       No EPP at all, and `powersave` really does mean "sit at the minimum
  #       frequency", which would cost far more hashrate than it saves watts.
  #       Keep `performance` and let the frequency ceiling below do the work.
  #
  # The ceiling is the lever that works on every driver, and the only one that
  # reaches an AMD board whose PPT is set in firmware: Linux cannot lower a
  # PBO power limit, but it can decline to ask for the clocks that would reach
  # it. See rig.mining.efficiency.maxFreqPercent for how the number is picked.
  rigCpuTune = pkgs.writeShellScript "rig-cpu-tune" ''
    set -uo pipefail

    pct=${toString cfg.efficiency.maxFreqPercent}

    # Per-rig override, shipped the way the credentials are.
    #
    # The efficiency optimum is not a fleet constant, and measuring it on one
    # rig and copying the number to the others is actively wrong. Measured
    # across four rigs, the ceiling that maximises hashes per watt at the wall
    # was 30% on a 9950X but 70%, 50% and 70% on an i7-6700K, an i5-10600K and
    # an i5-6600K.
    #
    # The reason is structural rather than incidental, so it will keep being
    # true of any mixed fleet: what a rig burns *besides* its CPU -- PSU
    # losses, RAM, board -- does not fall when the CPU slows down. On the
    # 6700K that floor is ~34 W against 7.5 W of package at the bottom of the
    # range, so pushing the clock down stops buying watts long before it stops
    # costing hashes, and the optimum sits high. On the 9950X the CPU is most
    # of the draw, so it keeps paying much further down.
    #
    # Hence a file rather than a flake value: same mechanism as the XMRig
    # token and the MQTT password (write it into the --extra-files tree, or
    # drop it on a running rig), so one generic image still suits every
    # machine and retuning one rig needs no rebuild of any other.
    if [ -r /etc/rig/max-freq-percent ]; then
      want=$(tr -d '[:space:]' < /etc/rig/max-freq-percent | tr A-Z a-z)

      # `off` is not the same as 100, and the difference is not small. At 100
      # the ceiling is gone but the governor is still powersave and the EPP is
      # still `power`, and the hardware honours that: measured on a 9950X,
      # 16743 H/s at 100% against 18941 H/s with the plain performance
      # governor. So a rig that genuinely wants maximum hashrate -- one
      # running on a solar surplus that would otherwise be exported for
      # nothing, where the electricity has no marginal cost -- needs the CPU
      # handed back untouched, not merely uncapped.
      if [ "$want" = off ]; then
        echo "rig-cpu-tune: /etc/rig/max-freq-percent says off, overriding $pct."
        pct=off
      elif [ -n "$want" ] && [ "$want" -ge 10 ] && [ "$want" -le 100 ] 2>/dev/null; then
        echo "rig-cpu-tune: /etc/rig/max-freq-percent says $want%, overriding $pct."
        pct=$want
      else
        # Deliberately not fatal. A rig that mines at the fleet default is a
        # rig that mines; one that refuses to start its tuning unit because a
        # config file has a typo in it is a rig nobody notices is untuned.
        echo "rig-cpu-tune: /etc/rig/max-freq-percent unusable, keeping $pct." >&2
      fi
    fi

    # Hoisted out of the file-reading block above, so `off` is honoured whether
    # it came from that file or straight from the option. It used to live
    # inside that block, which made `off` expressible per machine but not as a
    # fleet default -- and the option type could not have held it anyway.
    #
    # That asymmetry is worth removing rather than documenting: a fleet mining
    # on solar surplus, where the electricity has no marginal cost, wants every
    # rig untuned, and saying so once in the flake is not the same amount of
    # work as writing a file on each machine and keeping them in step.
    if [ "$pct" = off ]; then
      echo "rig-cpu-tune: leaving the CPU untuned."

      # Boost first, for the same reason the tuning path re-arms it first:
      # cpuinfo_max_freq reports the non-boost maximum while boost is off,
      # so reading the ceiling before re-arming would restore a ceiling
      # lower than the one this machine actually came with.
      if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 1 2>/dev/null > /sys/devices/system/cpu/cpufreq/boost || true
      fi

      for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] || continue
        echo performance 2>/dev/null > "$p/scaling_governor" || true
        # Usually redundant and allowed to fail: on the active drivers the
        # performance governor pins EPP to performance by itself, and then
        # refuses writes to this file.
        echo performance 2>/dev/null > "$p/energy_performance_preference" || true
        m=$(cat "$p/amd_pstate_max_freq" 2>/dev/null \
              || cat "$p/cpuinfo_max_freq" 2>/dev/null || echo 0)
        [ "$m" -gt 0 ] && { echo "$m" 2>/dev/null > "$p/scaling_max_freq" || true; }
      done

      echo "rig-cpu-tune: governor $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor), ceiling $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) kHz."
      exit 0
    fi

    if [ ! -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]; then
      echo "rig-cpu-tune: no cpufreq driver bound (kernel VM?); nothing to tune."
      exit 0
    fi

    driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)

    case "$driver" in
      intel_pstate|amd-pstate-epp) gov=powersave; epp=power ;;
      *)                           gov=performance; epp= ;;
    esac

    echo "rig-cpu-tune: driver $driver -> governor $gov, ceiling $pct% of range."

    # Re-arm boost before reading anything, so this is idempotent.
    #
    # cpuinfo_max_freq is not the hardware constant it looks like: with boost
    # disabled the cpufreq core reports the *non-boost* maximum instead. Since
    # the tail of this script disables boost, a second run would compute its
    # ceiling from a range the first run had already shrunk -- 70% of 5.75 GHz
    # once, then 70% of the 4.3 GHz base, and lower again on every resume,
    # with nothing in the logs to say why the rig kept slowing down. Putting
    # the full range back first makes every run land on the same number.
    if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
      echo 1 2>/dev/null > /sys/devices/system/cpu/cpufreq/boost || true
    fi

    for p in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "$p" ] || continue

      # stderr is redirected *before* the target, not after: the shell applies
      # redirections left to right and reports a failed one on whatever stderr
      # is at that moment, so the usual `> file 2>/dev/null` still prints
      # "Permission denied" for a read-only sysfs node.
      echo "$gov" 2>/dev/null > "$p/scaling_governor" || true

      # Only written where the driver exposes it. On the active drivers this,
      # not the governor, is what tells the hardware to prefer efficiency.
      if [ -n "$epp" ] && [ -w "$p/energy_performance_preference" ]; then
        echo "$epp" 2>/dev/null > "$p/energy_performance_preference" || true
      fi

      # Expressed against this CPU's own min..max rather than as a fixed MHz,
      # so the same percentage lands sensibly on a 4.8 GHz desktop part and on
      # whatever else ends up in the fleet.
      min=$(cat "$p/cpuinfo_min_freq" 2>/dev/null || echo 0)

      # amd_pstate_max_freq first where it exists: it is the boost maximum
      # regardless of whether boost is currently armed, so it is a stable
      # reference even if the re-arm above did not take effect in time.
      max=$(cat "$p/amd_pstate_max_freq" 2>/dev/null \
              || cat "$p/cpuinfo_max_freq" 2>/dev/null || echo 0)
      [ "$max" -gt 0 ] || continue

      target=$(( min + (max - min) * pct / 100 ))
      echo "$target" 2>/dev/null > "$p/scaling_max_freq" || true
    done

    # Turbo/boost is a separate switch on acpi-cpufreq and on amd-pstate in
    # passive mode: the ceiling above is clamped to the non-boost range there,
    # so leaving boost armed lets the CPU exceed what we just asked for.
    if [ "$pct" -lt 100 ] && [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
      echo 0 2>/dev/null > /sys/devices/system/cpu/cpufreq/boost || true
    fi

    now=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || echo "?")
    echo "rig-cpu-tune: per-core ceiling now $now kHz."
  '';

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

  # Merges the per-machine bits into the config at start time, in a 0700
  # runtime dir outside the Nix store. Using `jq --rawfile` (filename on the
  # command line, not the token itself) keeps the secret out of this process's
  # argv and out of `ps`/`/proc/<pid>/cmdline`, unlike a CLI flag.
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

    ${pkgs.jq}/bin/jq \
      --rawfile token /etc/xmrig/token \
      --arg worker "$worker" \
      --argjson onegb "$onegb" \
      '.http["access-token"] = ($token | rtrimstr("\n"))
       | .pools[0].pass = $worker
       | .randomx["1gb-pages"] = $onegb' \
      ${xmrigConfig} > /run/xmrig/config.json

    exec ${pkgs.xmrig}/bin/xmrig --config=/run/xmrig/config.json
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

    efficiency = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Tune the CPU for hashes per watt instead of for peak hashrate.

          On by default because that is what a rig paid for in electricity
          wants, and because the alternative -- the `performance` governor
          this module used to set unconditionally -- means "draw the whole
          power budget the firmware allows" on the modern pstate drivers. On
          a board whose PPT is set by a PBO profile that is a 200 W+ ceiling,
          reached for a hashrate a fraction of that would have bought.

          Set false on a rig where the electricity is free or already paid
          for (a solar surplus that would otherwise be exported for nothing),
          where peak hashrate really is the thing to maximise.
        '';
      };

      maxFreqPercent = lib.mkOption {
        type = lib.types.either (lib.types.ints.between 10 100) (lib.types.enum [ "off" ]);
        default = 70;
        description = ''
          Fleet default for the frequency ceiling, as a percentage of this
          CPU's own cpuinfo_min_freq..cpuinfo_max_freq range, applied at
          runtime so one image suits a mixed fleet.

          Also accepts the string "off", which skips tuning entirely and hands
          the CPU back untouched: performance governor, EPP performance, boost
          armed, no ceiling. That is not the same as 100 -- see below -- and it
          is the setting for a fleet running on solar surplus, where the
          electricity has no marginal cost and hashes per watt stop being the
          thing worth maximising.

          Overridden per machine by /etc/rig/max-freq-percent, which takes the
          same two forms -- which is where a measured value
          belongs, because the optimum is not a fleet constant. Measured here:
          30 on a 9950X, but 70, 50 and 70 on an i7-6700K, an i5-10600K and an
          i5-6600K. A rig whose CPU is a small share of what it draws at the
          wall has its optimum much higher up, since slowing the CPU stops
          saving watts long before it stops costing hashes.

          70 as the default because it was the best of the four measured on
          two of them, and because it is a mild setting to inherit: a rig that
          picks it up without anyone having measured that rig loses a few
          percent, not half its hashrate.

          Measure at the wall rather than in package power -- PSU, RAM and
          board losses are a real share of the meter reading, and they are
          what moves the optimum between machines. 100 disables the ceiling
          (and leaves boost armed) while still keeping the efficiency-side
          governor and EPP -- so it is emphatically not "maximum hashrate":
          measured on a 9950X, 16743 H/s at 100 against 18941 H/s with the
          plain performance governor. Ask for "off" when that is what you
          want. The floor is 10 rather than 0 so that a typo cannot park a rig
          at its minimum clock.
        '';
      };
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

    # Left unset when the efficiency tuning is on: NixOS applies this option
    # from a boot-time unit that writes every policy's scaling_governor, and
    # on intel_pstate/amd-pstate-epp "performance" is precisely the setting
    # that pins the CPU to its full power budget. rig-cpu-tune below decides
    # the governor from the driver it finds instead.
    #
    # With the tuning off, the old unconditional behaviour is what remains:
    # these machines otherwise come up on `powersave`, which trades sustained
    # clock for idle power on a box that is never idle, and RandomX is
    # latency-bound enough that the clock it runs at *is* the hashrate.
    powerManagement.cpuFreqGovernor = lib.mkIf (!cfg.efficiency.enable) "performance";

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

    systemd.services.rig-cpu-tune = lib.mkIf cfg.efficiency.enable {
      description = "Tune the CPU for hashes per watt";
      wantedBy = [ "multi-user.target" ];
      before = [ "xmrig.service" ];

      # NixOS's own cpufreq unit is what powerManagement.cpuFreqGovernor
      # builds, and it exists whenever that option is set to anything. It is
      # not set while this unit is enabled -- so the ordering is only here to
      # keep the two from racing if someone turns the option back on by hand
      # in a local override, in which case last writer wins and it should be
      # this one.
      after = [ "cpufreq.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${rigCpuTune}";
      };
    };

    # sysfs cpufreq settings do not reliably survive S3: a policy that comes
    # back re-initialised from the driver defaults lands on the firmware's
    # idea of the ceiling, which on the boards this fleet runs is the full PBO
    # budget. Since rig-power suspend is the normal way the solar automation
    # parks a rig, a rig would then spend most of its life un-tuned -- and the
    # symptom is only visible at the wattmeter, since it still mines fine.
    #
    # Same post-resume.target idiom as rig-wol-resume in modules/power.nix,
    # and deliberately without RemainAfterExit for the same reason: the unit
    # has to be re-runnable on every wake, not just the first.
    systemd.services.rig-cpu-tune-resume = lib.mkIf cfg.efficiency.enable {
      description = "Re-apply the hash-per-watt CPU tuning after resume";
      wantedBy = [ "post-resume.target" ];
      after = [ "suspend.target" "post-resume.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${rigCpuTune}";
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
        RuntimeDirectory = "xmrig";
        RuntimeDirectoryMode = "0700";
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
