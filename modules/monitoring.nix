{ config, pkgs, lib, ... }:

let
  cfg = config.rig.monitoring;

  # Where the service keeps the credential Glances actually reads. RuntimeDirectory
  # gives us this path at 0700, owned by the DynamicUser, wiped on stop.
  runtimeDir = "/run/glances";

  # `-C` is what points Glances at the password file. Without it the path comes
  # from user_config_dir(), i.e. $XDG_CONFIG_HOME/glances -- and a DynamicUser
  # has no meaningful home, so the lookup would land somewhere unwritable and
  # Glances would fall back to prompting on a terminal that does not exist.
  glancesConf = pkgs.writeText "glances.conf" ''
    [passwords]
    local_password_path=${runtimeDir}
  '';

  # Turns the plaintext password into the digest Glances stores, into the
  # runtime dir, before the server starts.
  #
  # Glances only prompts when <local_password_path>/<username>.pwd is missing;
  # when it exists the file is read as-is. That is the whole reason a
  # non-interactive server is possible, and it is why this runs as ExecStartPre
  # rather than being baked at build time -- the plaintext must stay out of
  # /nix/store, which is world-readable.
  #
  # The file format is Glances' own (glances/password.py):
  #
  #   <salt>$pbkdf2_hmac(sha256, pbkdf2_hmac(sha256, plaintext, "", 100k, 128),
  #                      salt, 100k, 128)
  #
  # i.e. the plaintext is hashed once unsalted -- that inner digest is what a
  # Glances *client* puts on the wire -- and the result is hashed again with a
  # per-file random salt. Reimplemented here in stdlib hashlib rather than by
  # importing glances, so this stays a five-line script instead of a Python
  # environment. If upstream ever changes the derivation the symptom is a clean
  # 401 from every request, not a silently open port.
  #
  # `pkgs.python3` and not python3Minimal: against this nixpkgs it is the very
  # interpreter Glances is built against (both resolve to the same
  # python3-3.13.12 store path), so it costs nothing here, whereas the minimal
  # one would add a second Python to the closure.
  mkPassword = pkgs.writeShellScript "glances-password" ''
    set -euo pipefail
    umask 077

    src="''${CREDENTIALS_DIRECTORY:-}/password"
    if [ ! -s "$src" ]; then
      echo "glances: ${cfg.passwordFile} is missing or empty — refusing to start" >&2
      echo "  sudo install -Dm600 /dev/stdin ${cfg.passwordFile} <<< \"\$(openssl rand -hex 24)\"" >&2
      exit 1
    fi

    ${pkgs.python3}/bin/python3 - "$src" ${runtimeDir}/${cfg.username}.pwd <<'PY'
    import hashlib, sys, uuid

    plain = open(sys.argv[1]).read().strip()

    def kdf(value, salt=""):
        return hashlib.pbkdf2_hmac(
            "sha256", value.encode(), salt.encode(), 100000, dklen=128
        ).hex()

    salt = uuid.uuid4().hex
    with open(sys.argv[2], "w") as out:
        out.write(salt + "$" + kdf(kdf(plain), salt))
    PY
  '';

  # `-u` without a password file is not something Glances offers: it would
  # prompt. So an open API is a real configuration rather than an oversight,
  # and the only honest thing to do is say so once per start instead of letting
  # it look identical to the protected one.
  warnOpen = pkgs.writeShellScript "glances-open-warning" ''
    echo "glances: rig.monitoring.passwordFile is null — the API is open to" >&2
    echo "  ${lib.concatStringsSep ", " config.rig.lanCidrs} with no credential." >&2
  '';

in
{
  imports = [ ./lan.nix ];

  options.rig.monitoring = {
    enable = lib.mkEnableOption "Glances telemetry for Home Assistant";

    port = lib.mkOption {
      type = lib.types.port;
      default = 61208;
      description = "Glances web/API port — this is what the HA Glances integration talks to.";
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "glances";
      description = ''
        HTTP Basic username the Glances API expects. Glances derives its
        password filename from this (`<username>.pwd`), so changing it after
        install just means the next start writes a different file.
      '';
    };

    passwordFile = lib.mkOption {
      # str, deliberately, and not path: a `path` accepts a Nix path literal,
      # which Nix copies into /nix/store -- publishing the plaintext password
      # world-readable on every rig, i.e. exactly what putting it outside the
      # store was for. A string is only ever a location on the running machine.
      type = lib.types.nullOr lib.types.str;
      default = "/etc/glances/password";
      description = ''
        File holding the plaintext HTTP Basic password, outside the Nix store
        because everything in /nix/store is world-readable. Written per rig by
        scripts/mk-secrets.sh and shipped by `nixos-anywhere --extra-files`.

        Glances' REST API is unauthenticated by default, and `-w` serves rather
        more than a hashrate: the process list, logged-in users, network
        counters and mounted filesystems. The XMRig API next door has required
        a bearer token from the start; this is the same decision applied to the
        service that describes the machine rather than the one that drives it.

        Set to null to run Glances open on the LAN. The service then logs a
        warning at every start, because that is a choice worth seeing.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    # lm_sensors needs to be able to read the coretemp module for CPU temps.
    boot.kernelModules = [ "coretemp" ];

    systemd.services.glances = {
      description = "Glances telemetry server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # Glances shells out to these for sensor and disk data.
      path = with pkgs; [ lm_sensors smartmontools ];

      serviceConfig = {
        Type = "simple";
        ExecStart =
          "${pkgs.glances}/bin/glances -w --disable-webui -p ${toString cfg.port}"
            + lib.optionalString (cfg.passwordFile != null)
            " -C ${glancesConf} -u ${cfg.username}";
        Restart = "always";
        RestartSec = 10;
        DynamicUser = true;
        # NOTE: this service used to join the `disk` group with the comment
        # "needed to read hwmon temperatures". That was wrong on both counts:
        # hwmon temps live in /sys/class/hwmon/*/temp*_input and are
        # world-readable, while the `disk` group grants read/write on every
        # raw block device (/dev/sd*, root:disk 0660) — i.e. full disk access,
        # and effectively root, for a network-facing telemetry daemon.
        # Only SMART data needs it; add it back only if you want smartmontools
        # output in Home Assistant and accept that trade.
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        PrivateTmp = true;

        ExecStartPre = if cfg.passwordFile != null then "${mkPassword}" else "${warnOpen}";
      } // lib.optionalAttrs (cfg.passwordFile != null) {
        # LoadCredential is what lets a DynamicUser read a 0600 root-owned file
        # without that file having to be chowned to a UID which changes on
        # every start. systemd copies it into $CREDENTIALS_DIRECTORY, readable
        # by this service and nothing else.
        LoadCredential = "password:${cfg.passwordFile}";
        RuntimeDirectory = "glances";
        RuntimeDirectoryMode = "0700";
      };
    };

    # An empty list would emit `ip saddr { }`, which nft rejects at ruleset
    # load time -- taking the whole firewall down, not just this rule.
    networking.firewall.extraInputRules =
      lib.optionalString (config.rig.lanCidrs != [ ]) ''
        ip saddr { ${lib.concatStringsSep ", " config.rig.lanCidrs} } tcp dport ${toString cfg.port} accept
      '';

    # Same reasoning as the XMRig token: the file lives outside the store by
    # design, so its absence is only knowable on the running machine. Without
    # it the service refuses to start, and this is what tells you why.
    system.activationScripts.glancesPassword =
      lib.mkIf (cfg.passwordFile != null) ''
        if [ ! -f ${cfg.passwordFile} ]; then
          echo "WARNING: ${cfg.passwordFile} is missing — Glances will fail to start."
          echo "  sudo install -Dm600 /dev/stdin ${cfg.passwordFile} <<< 'your-secret'"
        fi
      '';
  };
}
