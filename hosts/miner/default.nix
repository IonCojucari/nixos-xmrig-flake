{ config, pkgs, lib, ... }:

{
  imports = [
    ./rig.nix
  ]
  # Optional, and absent on almost every rig: settings true of exactly one
  # machine. Copy hosts/miner/local.nix.example to hosts/miner/local.nix on the
  # rig that needs one; see modules/quirks.nix for what belongs in it.
  #
  # `git add` it. In a git working tree Nix only copies *tracked* files into the
  # store, so an untracked or ignored local.nix does not exist as far as this
  # line is concerned -- pathExists returns false, the import is skipped, and
  # the build succeeds while quietly doing nothing.
  ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;

  # ---------------------------------------------------------------------------
  # Boot / kernel
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ---------------------------------------------------------------------------
  # Basics
  # ---------------------------------------------------------------------------
  # Empty means "do not set a hostname declaratively" — rig-hostname below
  # derives a unique one per machine at boot. Hardcoding "miner" would give
  # every rig installed from this image the same name, and most routers
  # register the DHCP hostname in local DNS.
  networking.hostName = "";
  networking.networkmanager.enable = false;
  networking.useDHCP = lib.mkDefault true;

  # ---------------------------------------------------------------------------
  # DNS: resolve over TLS, to a resolver this config chooses.
  #
  # Whatever the local network hands out over DHCP cannot be trusted to
  # resolve a mining pool. Two independent mechanisms break it, and both fail
  # silently -- XMRig just logs
  # `connect error: "connection refused"` every five seconds forever, because
  # it is dutifully dialling the 0.0.0.0 it was handed:
  #
  #   1. Filtering resolvers. Quad9's *filtered* endpoint (9.9.9.9) NXDOMAINs
  #      pool hostnames as cryptojacking infrastructure, while still resolving
  #      the pool's website -- so the network looks perfectly healthy.
  #   2. VPN gateways that transparently redirect port 53. Behind the tunnel,
  #      queries addressed to any resolver are answered by the VPN's own,
  #      which makes `networking.nameservers` advisory rather than binding:
  #      whatever you put there, the answer comes from somewhere else.
  #
  # Port 853 with strict TLS is what actually settles it. The `#hostname`
  # suffixes are not cosmetic -- under dnsovertls = "true" they are the SNI
  # and certificate-validation target, so a redirected query fails to
  # authenticate instead of quietly returning someone else's answer.
  #
  # Trade-off, stated plainly: strict mode has no plaintext fallback. If 853
  # is ever blocked outright the rig gets no DNS at all rather than degraded
  # DNS, and that is a console trip. Accepted here because the failure is
  # loud and diagnosable, whereas the failure it replaces was neither.
  services.resolved = {
    enable = true;
    dnsovertls = "true";
    # Upstreams already validate DNSSEC. Enabling it in resolved as well buys
    # nothing here and adds a second way for resolution to hard-fail.
    dnssec = "false";
    fallbackDns = [ "9.9.9.10#dns.quad9.net" "1.1.1.1#cloudflare-dns.com" ];
  };

  networking.nameservers = [ "9.9.9.10#dns.quad9.net" "1.1.1.1#cloudflare-dns.com" ];

  # Without this, dhcpcd keeps publishing the network's DHCP-supplied resolver
  # to resolved as a per-link server. resolved prefers per-link DNS over the
  # global list, so the router's filtering resolver would win and everything
  # above would be dead config.
  networking.dhcpcd.extraConfig = "nohook resolv.conf";

  # One image, many rigs: name each machine after its own machine-id. That is
  # generated on first boot and persists, so the name is stable per machine and
  # distinct across machines. It also becomes the XMRig worker name, which is
  # what keeps the rigs separate in the pool's worker list.
  systemd.services.rig-hostname = {
    description = "Derive a unique hostname from the machine ID";
    wantedBy = [ "network-pre.target" ];
    before = [ "network-pre.target" ];
    unitConfig.ConditionPathExists = "/etc/machine-id";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      id=$(cut -c1-8 /etc/machine-id)
      # Write the kernel hostname directly: this runs before systemd-hostnamed
      # and dbus are up, so hostnamectl is not available yet.
      echo "miner-$id" > /proc/sys/kernel/hostname
      echo "rig-hostname: hostname set to miner-$id"
    '';
  };

  # Required by modules/mining.nix and modules/monitoring.nix: both open their
  # LAN-only ports with `networking.firewall.extraInputRules`, which is an
  # nftables-backend option. Under the default iptables backend those rules are
  # not applied, and the default-deny input policy would silently block Home
  # Assistant from reaching the XMRig API (8080) and Glances (61208).
  networking.nftables.enable = true;

  time.timeZone = "Europe/Paris";

  # Clock, and why it is left alone here.
  #
  # This rig validates certificates twice over -- TLS to the pool, strict DoT
  # to the resolver above -- and both check validity *windows*, so a clock far
  # enough out produces `certificate is not yet valid` and retrying never
  # fixes it. Worth checking before Home Assistant starts cycling rigs on
  # solar surplus several times a day.
  #
  # Checked, and nothing needed doing: NixOS turns systemd-timesyncd on by
  # default (`services.timesyncd.enable = !config.boot.isContainer`, and
  # nothing here enables a competing NTP daemon), so the rigs already
  # discipline their clock. Not restated as an explicit `= true` on purpose:
  # chrony and ntpd both turn timesyncd off with `mkDefault false`, and a
  # non-default `true` here would silently outrank that and leave two NTP
  # clients fighting over the clock if one is ever added.
  #
  # Suspending does not make this worse either, which is the point worth
  # recording: in S3 the RTC keeps running on standby power and the kernel
  # re-reads it through the persistent-clock path on resume, so a sleep cycle
  # costs RTC drift -- seconds -- not a stopped clock. The case that actually
  # bites is a flat CMOS battery on a rig that is fully powered off every
  # night; that one shows up as a boot that cannot resolve or connect, and it
  # is a battery, not a config change.
  i18n.defaultLocale = "en_GB.UTF-8";
  console.keyMap = "fr";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Headless box: no GUI, no sound, no bluetooth.
  services.xserver.enable = false;
  hardware.bluetooth.enable = false;

  # Generic image: no hardware-configuration.nix is generated per machine, so
  # cover both CPU vendors and load a broad set of storage drivers in the
  # initrd. Without these the installed system can fail to find its root
  # filesystem on a controller the default initrd does not include.
  hardware.cpu.intel.updateMicrocode = true;
  hardware.cpu.amd.updateMicrocode = true;

  # Pulls in all of linux-firmware (~770 MB download, and it lands in the ISO
  # too). Kept deliberately: this image is meant to install onto machines that
  # have not been inspected yet, and a rig whose NIC needs firmware cannot
  # reach the pool or Home Assistant at all.
  hardware.enableRedistributableFirmware = true;

  boot.initrd.availableKernelModules = [
    # SATA / IDE
    "ahci"
    "ata_piix"
    "sata_nv"
    "sata_via"
    "sd_mod"
    "sr_mod"
    # NVMe
    "nvme"
    # USB (installer media, and USB-attached system disks)
    "ehci_pci"
    "xhci_pci"
    "usbhid"
    "usb_storage"
    "uas"
    # RAID / SCSI controllers seen on older desktop boards
    "ata_generic"
    "megaraid_sas"
    "mpt3sas"
    # VM guests, for `nix build .#vm`
    "virtio_blk"
    "virtio_pci"
    "virtio_scsi"
  ];

  # ---------------------------------------------------------------------------
  # Users / SSH
  # ---------------------------------------------------------------------------
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];

    # Console fallback, shipped by `nixos-anywhere --extra-files` at install
    # time (scripts/mk-secrets.sh writes it; `!` when you skip the password).
    #
    # Not a hash in this file, because everything in /nix/store is
    # world-readable: a hash committed here would be published to every local
    # user on every rig. Out-of-store means the flake stays public-safe.
    #
    # Only ever applied to an account that is NOT already in /etc/shadow, i.e.
    # at first install — with mutableUsers left at true, update-users-groups
    # rewrites an existing shadow entry only when mutableUsers is false. So a
    # password later set with `passwd` survives every rebuild, and rebuilding
    # a rig installed before this file existed just logs
    # `warning: password file /etc/admin.passwd does not exist` and changes
    # nothing.
    hashedPasswordFile = "/etc/admin.passwd";

    openssh.authorizedKeys.keys = [
      # ==== PUT YOUR OWN KEYS HERE ====
      #
      # This list ships empty on purpose, and the assertion at the bottom of
      # this file fails the build while it stays that way. Installing a rig
      # whose only authorized key belongs to someone else is not a mistake
      # worth making quietly.
      #
      # Every key here is passwordless root: `wheel` plus
      # wheelNeedsPassword = false. Keep this list to machines you administer
      # from. The homeassistant key is deliberately NOT listed; it gets the
      # unprivileged `ha` account below.
      #
      # This list is the only thing that decides who can log into an installed
      # rig. Being able to install one says nothing about it: nixos-anywhere
      # copies the keys of whatever account you connect as into the kexec'd
      # installer, so the machine you install from gets in for the duration of
      # the install and then only if its key is also below. List every
      # workstation you administer from, not just the one you install from.
      #
      # "ssh-ed25519 AAAA... you@workstation"
    ];
  };

  # Dedicated low-privilege user for Home Assistant to SSH in as.
  users.users.ha = {
    isNormalUser = true;
    description = "Home Assistant remote control";
    openssh.authorizedKeys.keys = [
      # Home Assistant's own key, plus any workstation you want to reach this
      # account from directly. Unlike the list above, this one is not asserted
      # on: leaving it empty gives a working rig that simply cannot be powered
      # off or woken from Home Assistant.
      #
      # "ssh-ed25519 AAAA... homeassistant"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  security.sudo.wheelNeedsPassword = false;

  # sshd here is key-only with root login disabled, and nixos-anywhere leaves
  # root with no password. If `admin` has no key either, the only way into the
  # installed rig is the console — and only if a password was set at install
  # time, which is optional. Fail the build instead of discovering that after
  # the disk has been erased.
  assertions = [{
    assertion = config.users.users.admin.openssh.authorizedKeys.keys != [ ];
    message = ''
      users.users.admin has no SSH keys: the installed rig would be
      unreachable (key-only sshd, PermitRootLogin=no, no admin password).
      Add your public key in hosts/miner/default.nix before installing.
    '';
  }];

  environment.systemPackages = with pkgs; [
    htop
    tmux
    lm_sensors
    pciutils
    git
  ];

  system.stateVersion = "25.11";
}
