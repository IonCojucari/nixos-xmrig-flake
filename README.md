# Monero CPU mining rig on NixOS

A CPU-only XMRig rig you drive from somewhere else: hashrate and telemetry out
over HTTP, pause, shutdown and wake back in. Everything that varies per machine
— core count, 1 GB page support, hostname, NIC name, worker name — is detected
at boot, so every rig runs the identical system and differs only in which disk
it was installed on.

Installing is one command from your laptop, over SSH, onto whatever Linux the
target is running right now. No ISO to build, no USB stick to write.

```bash
git clone https://github.com/IonCojucari/nixos-xmrig-flake
cd nixos-xmrig-flake

# 1. Edit three things (see "Configure" below)
#      hosts/miner/rig.nix       your wallet address
#      hosts/miner/default.nix   your SSH public key — the build fails without one
#      flake.nix                 the disk to erase, if it isn't /dev/sda

# 2. Generate this rig's credentials
scripts/mk-secrets.sh miner-a1b2c3d4

# 3. Install. This erases the disk named in step 1.
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miner-a1b2c3d4 \
  --target-host admin@192.168.1.42 \
  --extra-files secrets/miner-a1b2c3d4 \
  --no-substitute-on-destination
```

It kexecs a NixOS installer into RAM over the running system, partitions, copies
the closure, drops the credentials in, and reboots into a mining rig.

`--no-substitute-on-destination` sends the closure over SSH from your machine
rather than having the rig fetch it from `cache.nixos.org`, so the rig needs only
the LAN and no internet. Drop it if the rig's connection is better than yours.

---

## What you need

**On your machine:** Nix with flakes. Not NixOS — just Nix.

```bash
nix --extra-experimental-features 'nix-command flakes' flake metadata
```

That reads the flake without evaluating a rig, which is what you want here:
until you add an SSH key below, evaluating one deliberately fails.

**On the rig:** x86-64, kexec support, ≥ 1.5 GB RAM (excluding swap), **wired**
networking (nixos-anywhere does not do wifi), and any Linux already running,
reachable over SSH as root or as a user with passwordless sudo.

| Situation | What to boot on the target |
|---|---|
| Already running this config | nothing — target it as it is |
| Running some other distro | nothing — target it as it is |
| Bare machine | the **stock** NixOS minimal ISO, or any live USB |

For mining rather than just a working install, give it ≥ 8 GB of RAM: the config
reserves 2.5 GB of hugepages plus 3 GB of 1 GB pages at boot.

## Configure

**`hosts/miner/rig.nix`** — replace `YOUR_MONERO_ADDRESS`. The other defaults in
that file are sensible as they are.

**`hosts/miner/default.nix`** — your SSH public keys. The list ships empty and an
assertion fails the build until you fill it in.

> List every machine you administer from, not just the one you install from.
> nixos-anywhere copies the keys of the account you connect as into the
> installer, so the install works either way — but the installed rig accepts
> only what is in this file, and sshd is key-only with root login disabled.

**`flake.nix`** — the disk to erase. If the target has one SATA disk, skip this
and install `.#miner`, which partitions `/dev/sda`. Otherwise ask the target
what it has:

```bash
ssh admin@192.168.1.42 'ls -l /dev/disk/by-id/ | grep -v part'
```

and add an entry:

```nix
miner-a1b2c3d4 = mkMiner "/dev/disk/by-id/ata-SAMSUNG_SSD_860_EVO_500GB_S3Z2NB0K123456A";
```

Use `by-id`, not `/dev/sdX`. The partitioner runs inside a kexec'd installer
where enumeration order — and so which disk is `sda` — need not match what you
saw on the running machine.

## Credentials

`scripts/mk-secrets.sh <rig>` writes a tree that `--extra-files` copies onto the
new root before first boot:

```
secrets/<rig>/etc/xmrig/token       0600  XMRig API bearer token      (generated)
secrets/<rig>/etc/glances/password  0600  Glances HTTP Basic password (generated)
secrets/<rig>/etc/mqtt/password     0600  MQTT broker password         (prompted)
secrets/<rig>/etc/admin.passwd      0600  console password hash, or `!` (prompted)
```

The MQTT one is prompted rather than generated because it is the broker's, not
the rig's: one `miner` account serves the whole fleet, so a value invented per
rig is a value the broker refuses.

They stay out of the Nix store, which is world-readable. Both services fail
closed: XMRig will not start without its token, Glances will not start without
its password. The MQTT agent is the exception, and deliberately so — without
its password file it does not start at all, and the rig mines on in silence.

`secrets/` is gitignored and is your only record — nothing on the rig will show
you these again. Keep it, or move to [agenix](https://github.com/ryantm/agenix)
or [sops-nix](https://github.com/Mic92/sops-nix) for something fully
declarative.

## Dry run

Optional, needs KVM, about a minute once the system is built:

```bash
nix build .#installTest
```

It partitions a scratch disk in a VM with the script the real install would run,
installs onto it, and boots the result — the whole install path without erasing
anything.

Use this rather than `nixos-anywhere --vm-test`, which hardcodes a 4 GiB scratch
disk and 1 GiB of RAM for the boot check. This layout needs more of both.

## After it's running

Check it's mining:

```bash
journalctl -u xmrig -f            # want "huge pages 100%" and "msr register values set"
cat /proc/meminfo | grep Huge     # hugepages allocated?
lscpu | grep pdpe1gb              # 1 GB page support present?
xmrig --bench=1M                  # actual RandomX hashrate
```

`huge pages 0%` → raise `vm.nr_hugepages`. `MSR mod failed` → check that
`msr.allow_writes=on` reached `/proc/cmdline`; on Intel the MSR mod is worth
only a few percent.

Check what the CPU was actually tuned to:

```bash
journalctl -u rig-cpu-tune        # which driver was found, and the ceiling set
cpupower frequency-info | head    # governor and the max the kernel will request
```

Rebuild after a change, always against `.#miner`:

```bash
nix run nixpkgs#nixos-rebuild -- switch --flake .#miner \
  --target-host admin@192.168.1.42 --use-remote-sudo
```

The per-rig entries differ only in `rig.disk.device`, which only the partitioner
reads — the installed system mounts by partition label, and `nixos-rebuild` never
partitions anything, so every entry produces the same system.

> In a git repo, flake evaluation ignores **untracked** files: a new
> `hosts/miner/*.nix` is invisible until `git add`. Edits to tracked files are
> picked up, with a `Git tree is dirty` warning.

Rotate a credential:

```bash
# XMRig token
ssh admin@<ip> 'sudo install -Dm600 /dev/stdin /etc/xmrig/token <<< "$(openssl rand -hex 24)" \
  && sudo systemctl restart xmrig'

# Glances password — the hashed form it reads is regenerated at every start
ssh admin@<ip> 'sudo install -Dm600 /dev/stdin /etc/glances/password <<< "$(openssl rand -hex 24)" \
  && sudo systemctl restart glances'
```

Then update `secrets/<rig>/…` to match and *Reconfigure* the rig in Home
Assistant, which keeps the entry and its history.

Reinstalling a rig that already runs is the same install command — just check
you are naming the right rig's flake entry, since the disk it erases comes from
there and not from the hostname you connected to.

## Hashes per watt

The rig is tuned for efficiency, not for peak hashrate. This is `rig-cpu-tune`,
a oneshot that runs before XMRig and again after every resume, and it is on by
default (`rig.mining.efficiency`).

It matters more than it sounds. RandomX is memory-latency-bound: past roughly
base clock the core spends most of each hash waiting on RAM, so the last few
hundred MHz buy a couple of percent hashrate and cost a third of the package
power, because boost voltage scales worse than linearly. Left alone these
machines take the whole power budget the firmware offers — on a board running a
PBO profile, that is a 200 W+ ceiling reached for a hashrate a fraction of it
would have bought.

Two things are set, both decided on the running machine so one image suits a
mixed fleet:

| | `intel_pstate` / `amd-pstate-epp` | `intel_cpufreq` / `amd-pstate` passive / `acpi-cpufreq` |
|---|---|---|
| Governor | `powersave` — the *tunable* one here; `performance` pins the P-state request to maximum | `performance` — `powersave` really would sit at the minimum |
| Preference | `energy_performance_preference = power` | not exposed |
| Ceiling | `scaling_max_freq` at `maxFreqPercent` of this CPU's own range | same, plus `boost` off |

The ceiling is the part that reaches a board whose power limit lives in
firmware: Linux cannot lower a PBO PPT, but it can decline to ask for the
clocks that would reach it.

### The optimum is per rig, not per fleet

`rig.mining.efficiency.maxFreqPercent` is only the fleet default. The value a
given rig actually uses goes in **`/etc/rig/max-freq-percent`** on that rig — a
bare number between 10 and 100, or the word `off`, shipped in the
`--extra-files` tree like the XMRig token, or dropped on a running rig followed
by `systemctl restart rig-cpu-tune`. An unreadable or nonsensical file is
ignored with a log line rather than failing the unit: a rig mining at the fleet
default is better than a rig whose tuning never ran.

`off` hands the CPU back untouched — performance governor, EPP back to
performance, boost re-armed, ceiling at the hardware maximum — and is not the
same as `100`. At `100` the ceiling is gone but the governor is still
`powersave` and the EPP is still `power`, which the hardware honours: 16743 H/s
at `100` against 18941 H/s on the plain performance governor, measured on the
same 9950X. Use `off` for a rig running on a surplus that would otherwise be
exported for nothing, where the electricity has no marginal cost and hashrate
is the only thing worth maximising:

```bash
echo off | sudo tee /etc/rig/max-freq-percent && sudo systemctl restart rig-cpu-tune
```

Measured on the 9950X, that is 20568 H/s at 202.8 W (101.4 H/W) against
14342 H/s at 98.5 W (145.6 H/W) at its tuned 30%: 43% more hashrate for twice
the power.

It has to be per rig because the optimum is not a constant. Four rigs, each
swept over its own frequency range, best hashes per watt **at the wall**:

| rig | best | H/s there | W there | H/W |
|---|---|---|---|---|
| Ryzen 9 9950X | **30%** | 14342 | 98.5 | 145.6 |
| Core i5-10600K | **50%** | 3039 | 59.0 | 51.5 |
| Core i7-6700K | **70%** | 2429 | 61.3 | 39.6 |
| Core i5-6600K | **70%** | 1588 | 35.7 | 44.5 |

The spread is structural. A rig burns a fixed amount that is not its CPU — PSU
losses, RAM, board, about 34 W on the Skylake machines — and slowing the CPU
does not reduce it. On the 6700K the package drops to 7.5 W at the bottom of
the range while the wall only drops to 41.6 W, so the last steps down cost
hashes and save nothing, and its optimum sits high. On the 9950X the CPU is
most of the draw, so the trade keeps paying far further down.

Two traps when you retune. Measure the **wall**, not the package: package
efficiency on the 9950X never stops climbing (240 H/W at 25%, still rising at
20%) while wall efficiency peaks and turns over — and the wall is what is
billed. And note that `xmrig --bench=1M` measures hashrate alone, so it will
always prefer 100%.

Two changes are worth more than any of this and are not tuning at all: enable
XMP/EXPO in firmware (RandomX is latency-bound, and JEDEC fallback speed costs
10–20% for no power saving), and confirm `huge pages 100%` in the XMRig log.

Set `rig.mining.efficiency.enable = false` on a rig whose electricity is
already paid for — a solar surplus that would otherwise be exported for
nothing — where peak hashrate really is the thing to maximise.

## What listens, and on what

| Want | Mechanism | Auth |
|---|---|---|
| Hashrate, shares, pool | XMRig HTTP API, port 8080 | bearer token |
| CPU, temps, RAM, disk | Glances, port 61208 | HTTP Basic |
| Pause / resume | XMRig API `pause`/`resume` | token, `restricted = false` |
| Presence and state | MQTT, `rig/<worker>/…` on the broker | `miner` account |
| Shut down | `shutdown` on `rig/<worker>/cmd`, or `rig-power off` over SSH | broker account, or `ha` user |
| Reboot | `restart` on the same topic, or `rig-power reboot` | `allowReboot` |
| Suspend to RAM | `sleep` on the same topic, or `rig-power suspend` | `allowSuspend` |
| Power on, or wake from S3 | Wake-on-LAN magic packet | BIOS set to wake on LAN |

Both HTTP ports require a credential and are firewalled to `rig.lanCidrs` —
RFC1918 by default, so never internet-facing. sshd is key-only with root login
disabled. `admin` is passwordless-sudo root; `ha` may run one wrapper,
`rig-power`, and nothing else.

`allowReboot` is off by default. Worth remembering when testing: a reboot comes
back on its own, a poweroff only comes back if Wake-on-LAN works.

**Wake-on-LAN** is armed at runtime on whatever the wired NIC turns out to be
called, along with PCI PME — `wake-on: g` with PME disabled looks armed and wakes
nothing. The board has to cooperate too: *Power On By PCI-E* enabled and
**ErP/EuP Ready disabled**, since ErP cuts the standby rail the NIC needs. On a
board with several ports, the BIOS must wake on the one that is cabled.
`journalctl -u rig-wol` shows what was armed.

It is armed again after every resume, by a second unit — `rig-wol-resume`,
hanging off NixOS's `post-resume.target`. That is not belt and braces: several
drivers, r8169 among them, drop the WoL flag when the link goes down, which is
exactly what suspending does to it. Without the re-arm a rig wakes from its
first suspend and from no later one, which reads as flaky hardware rather than
as missing configuration. `journalctl -u rig-wol-resume` after a wake is the
check.

## Three ways to stop mining, and what each costs

Home Assistant driving a rig on solar surplus stops and starts it several times
a day, so the cost of *restarting* is what matters, not the cost of stopping.

| | How long to come back | What still draws power |
|---|---|---|
| Pause, via the XMRig API | instant | everything: the box is idle, not off |
| Suspend, `rig-power suspend` | seconds | standby rail only (RAM refresh, NIC) |
| Poweroff, `rig-power off` | a full boot, tens of seconds | standby rail only |

**Pause** (`pause`/`resume` on the HTTP API) stops the hashing threads and
nothing else. The process lives, the pool connection stays up, the RandomX
dataset stays allocated — so resuming is immediate, and the pool never sees the
worker disappear. What it saves is the difference between a CPU at full
RandomX load and the same CPU idle. That is real, and on these boxes it is the
largest single item, but it is not most of the machine: board, RAM, drive, PSU
conversion losses and fans are all still on. Measure your own rig at the wall
before sizing anything on it — the figure depends entirely on the CPU's share
of total draw and is not worth guessing.

**Suspend** (S3, suspend-to-RAM) is the one added for the solar cycle, and the
reason it exists is that it keeps what a poweroff throws away. RAM stays
refreshed, so the RandomX dataset — 2080 MiB of it — and the hugepage pool are
still there on the other side. Resuming does not re-run `rig-hugepages`, does
not re-initialise the dataset, and does not re-run the whole boot: the machine
thaws and XMRig is already hashing. The one thing that does not survive is the
TCP connection to the pool, which the pool has dropped by then; XMRig redials
itself (`retries` / `retry-pause` in `modules/mining.nix`), and the delay is
mostly how long it takes to *notice* the dead socket rather than how long the
reconnect takes. Draw in S3 is the standby rail — near enough to off, and again
worth one plug-meter reading rather than an assumption.

**Poweroff** is the only one that reaches true S5, and it costs a cold boot
plus a dataset re-initialisation on the way back: a few seconds with 1 GB pages
and considerably longer without, on top of firmware POST. For a rig that goes
down at dusk and comes back at dawn, that is nothing. For one following a cloud
passing over the panels, it is most of the window.

Suspend and poweroff come back the same way — the same magic packet, the same
BIOS settings — so a rig that cannot be woken cannot use either. Test the wake
path once per board model before wiring any of this to an automation.

## Home Assistant

Optional — a rig mines fine with nothing watching it. Everything it exposes
reaches Home Assistant through one custom integration,
[homeassistant-xmrig](https://github.com/IonCojucari/homeassistant-xmrig):
install it through HACS (or copy `custom_components/xmrig_remote_miner/` into
`<config>/custom_components/`),
restart, then *Settings → Devices & Services → Add Integration → XMRig Remote
Miner*, once per rig — IP, port 8080, the token, the poll interval, and the Glances username
(`glances`) and password.

> **The integration is not published yet**, so that link may 404. Until it is,
> the same surfaces work without it: the official
> [Glances](https://www.home-assistant.io/integrations/glances/) integration for
> temperature and load, a `rest` sensor against `http://<rig>:8080/2/summary`
> with an `Authorization: Bearer <token>` header for hashrate and shares, and
> `shell_command` running `ssh ha@<rig> sudo -n rig-power off` for the power
> buttons. It adds one device per rig instead of three, and discovers the MAC
> and the permitted power verbs by itself.

Pool earnings come from the pool, not the rig:

```yaml
sensor:
  - platform: rest
    name: XMR Unpaid Balance
    resource: "https://supportxmr.com/api/miner/YOUR_ADDRESS/stats"
    value_template: "{{ (value_json.amtDue | float / 1000000000000) | round(6) }}"
    unit_of_measurement: "XMR"
    scan_interval: 300
```

SupportXMR reports balances in piconero, hence the 1e12 division.

## Layout

```
flake.nix                    one nixosConfigurations entry per rig
hosts/miner/default.nix      system config: boot, users, SSH, DNS
hosts/miner/rig.nix          your settings (wallet, pool)
hosts/miner/local.nix        one machine's own quirks; optional, must be tracked
hosts/miner/disko.nix        partition layout + rig.disk.device option
modules/mining.nix           XMRig + hugepages + MSR + hash/watt CPU tuning
modules/monitoring.nix       Glances telemetry, behind HTTP Basic
modules/power.nix            Wake-on-LAN in, shutdown/suspend out
modules/lan.nix              the one list of LAN ranges both services trust
modules/quirks.nix           per-machine firmware workarounds, all off by default
scripts/mk-secrets.sh        per-rig credentials, for --extra-files
secrets/                     what it writes; gitignored, never leaves your machine
```

## Notes

- **DNS goes over TLS to a fixed resolver**, set in `hosts/miner/default.nix`.
  Filtering resolvers treat pool hostnames as cryptojacking infrastructure, and
  some gateways redirect port 53 regardless of what you configure; strict DoT on
  port 853 avoids both. There is no plaintext fallback, so if 853 is blocked the
  rig gets no DNS rather than the wrong DNS.
- **`rig.lanCidrs` defaults to all of RFC1918** rather than your own /24, so a
  rig keeps answering when it moves to another network. Narrow it if you prefer;
  it covers both HTTP services at once.
- **XMRig runs as root.** MSR writes and hugepage allocation require it; this is
  the documented upstream setup, and systemd hardening limits the rest. The
  service is hand-rolled rather than nixpkgs' `services.xmrig`, for direct
  control over privileges.
- **`restricted = false`** on the XMRig API is what enables pause/resume. It is
  firewalled and token-protected; check both if you change networks. Be clear
  about what the token buys its holder, though, because unrestricted is not
  only pause and resume: it also allows `PUT /2/config`, which replaces the
  *whole* configuration — `pools[0].user` included. Anyone on the LAN holding
  the token can therefore repoint a rig at another wallet; the miner reconnects
  and carries on, and the declared configuration only comes back at the next
  restart, since `xmrig-start` rebuilds it from the flake. This is the price of
  the pause switch, not a misconfiguration — but it makes `/etc/xmrig/token` a
  credential worth the same care as an SSH key.
- **Hugepages are reserved unconditionally**, sized for a real rig: 2.5 GiB of
  2 MB pages plus 3 GiB of 1 GB pages before userspace starts. Below about 4 GiB
  of RAM the machine boots very slowly under memory pressure rather than failing
  outright.
- **A rig that boots intermittently may be a firmware bug, not dying hardware.**
  Some boards ship an ACPI event handler that calls a symbol their own DSDT
  never defines; when the event re-arms in a loop the failing handler floods
  the console and the machine can miss its login prompt entirely. It looks like
  a BIOS that needs reflashing, which on a remote rig is the most irreversible
  thing you could do about it — and consumer boards have no Linux flashing path
  anyway. Check `dmesg | grep -E 'ACPI (BIOS )?Error'` and
  `/sys/firmware/acpi/interrupts/`, and if a GPE is the culprit mask it with
  `rig.quirks.maskGpes` from `hosts/miner/local.nix`. A boot that dies before
  journald flushes leaves nothing behind, so the console is more trustworthy
  than `journalctl -b -1` here.
- **UEFI only** (GPT + ESP + systemd-boot). `hosts/miner/disko.nix` has a BIOS
  variant at the bottom; a BIOS rig needs its own flake entry.
- **`nixpkgs` is pinned to `nixos-25.11`**, and `disko` to the last revision
  whose test harness matches it — see the comment in `flake.nix` before bumping
  either.
- `hosts/miner/default.nix` pulls in a broad initrd module list and all of
  `linux-firmware` (~770 MB) so the image installs on uninspected hardware. To
  trim it, add `--generate-hardware-config nixos-facter facter-<rig>.json` to the
  install and cut both down to what the machine has.
- CI evaluates every rig's toplevel derivation path on push, rather than
  `nix flake check`, which would build the whole closure.

## License

MIT — see [LICENSE](LICENSE). No warranty: this partitions disks and runs a
miner as root.
