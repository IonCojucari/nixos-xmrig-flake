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
secrets/<rig>/etc/admin.passwd      0600  console password hash, or `!` (prompted)
```

They stay out of the Nix store, which is world-readable. Both services fail
closed: XMRig will not start without its token, Glances will not start without
its password.

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

## What listens, and on what

| Want | Mechanism | Auth |
|---|---|---|
| Hashrate, shares, pool | XMRig HTTP API, port 8080 | bearer token |
| CPU, temps, RAM, disk | Glances, port 61208 | HTTP Basic |
| Pause / resume | XMRig API `pause`/`resume` | token, `restricted = false` |
| Shut down | `rig-power off` over SSH | `ha` user |
| Reboot | `rig-power reboot` over SSH | `ha` user, `allowReboot` |
| Power on | Wake-on-LAN magic packet | BIOS set to wake on LAN |

Both HTTP ports require a credential and are firewalled to `rig.lanCidrs` —
RFC1918 by default, so never internet-facing. sshd is key-only with root login
disabled. `admin` is passwordless-sudo root; `ha` may run one wrapper,
`rig-power`, and nothing else.

Pause is instant and keeps the pool connection and the RandomX dataset alive.
Shutdown is not: a cold start pays the dataset init again, a few seconds with
1 GB pages and longer without.

`allowReboot` is off by default. Worth remembering when testing: a reboot comes
back on its own, a poweroff only comes back if Wake-on-LAN works.

**Wake-on-LAN** is armed at runtime on whatever the wired NIC turns out to be
called, along with PCI PME — `wake-on: g` with PME disabled looks armed and wakes
nothing. The board has to cooperate too: *Power On By PCI-E* enabled and
**ErP/EuP Ready disabled**, since ErP cuts the standby rail the NIC needs. On a
board with several ports, the BIOS must wake on the one that is cabled.
`journalctl -u rig-wol` shows what was armed.

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
hosts/miner/disko.nix        partition layout + rig.disk.device option
modules/mining.nix           XMRig + hugepages + MSR
modules/monitoring.nix       Glances telemetry, behind HTTP Basic
modules/power.nix            Wake-on-LAN in, remote shutdown out
modules/lan.nix              the one list of LAN ranges both services trust
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
