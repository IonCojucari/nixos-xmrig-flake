{ config, pkgs, lib, ... }:

let
  cfg = config.rig.mqtt;
  power = config.rig.power;

  # Bearer token for the local XMRig API. Not an option here because it is not
  # one in modules/mining.nix either: xmrig-start reads this exact path.
  xmrigToken = "/etc/xmrig/token";

  # Holds the mosquitto client configuration written at start time. Not a
  # systemd RuntimeDirectory=, deliberately: two units need the same file, and
  # a RuntimeDirectory belongs to one unit and is wiped when that unit stops --
  # which is precisely the moment the shutdown announcer still needs it.
  runtimeDir = "/run/rig-mqtt";

  # Everything both scripts below need, and none of it knowable at build time.
  #
  # The password goes into mosquitto's own options file rather than onto the
  # command line. `mosquitto_pub --pw` puts the credential in argv, where any
  # local user reads it out of /proc/<pid>/cmdline for as long as the process
  # lives -- and the agent's subscriber lives forever. mosquitto_pub and
  # mosquitto_sub each read `$XDG_CONFIG_HOME/<their own name>` as a file of
  # `-option value` lines before parsing argv, which is the mechanism upstream
  # documents for exactly this. (Not `-o <file>`: that flag arrived in
  # mosquitto 2.1, and nixos-25.11 ships 2.0.22.)
  setup = ''
    umask 077
    install -d -m 700 ${runtimeDir}

    # The worker name is the hostname, which hosts/miner/default.nix derives
    # from the machine-id at boot -- and therefore the same string XMRig
    # reports to the pool, since modules/mining.nix computes it the same way.
    # The fallback is that module's backstop for the same reason: a rig still
    # answering "localhost" would publish onto a topic every other rig also
    # publishes onto.
    worker=$(cat /proc/sys/kernel/hostname)
    if [ -z "$worker" ] || [ "$worker" = "localhost" ]; then
      worker="miner-$(cut -c1-8 /etc/machine-id)"
    fi
    base="rig/$worker"

    # A file that exists but is empty, which the unit's ConditionPathExists
    # cannot catch. Nothing here is retryable, so exit 0 and let
    # Restart=on-failure leave the unit dead, rather than have it reconnect
    # every ten seconds forever to be rejected every ten seconds forever.
    if [ ! -s ${cfg.passwordFile} ]; then
      echo "rig-mqtt: ${cfg.passwordFile} is empty — not connecting." >&2
      exit 0
    fi

    printf -- '-h %s\n-p %s\n-u %s\n--pw %s\n' \
      ${lib.escapeShellArg cfg.broker} ${toString cfg.port} \
      ${lib.escapeShellArg cfg.username} "$(cat ${cfg.passwordFile})" \
      > ${runtimeDir}/mosquitto_pub
    cp ${runtimeDir}/mosquitto_pub ${runtimeDir}/mosquitto_sub
    export XDG_CONFIG_HOME=${runtimeDir}

    # Every message this rig sends is retained. A rig that spoke only at its
    # own start would be an unknown device to a Home Assistant that restarted
    # since -- and for availability, would stay unknown until it died.
    pub() { ${pkgs.mosquitto}/bin/mosquitto_pub -q 1 -r -t "$1" -m "$2"; }
  '';

  # One retained message describing the whole device, so unregistering a rig
  # means clearing one topic rather than five.
  #
  # `restart` and `sleep` appear only where the rig accepts the verb behind
  # them, which is the rule the SSH probe already followed: rig-power does not
  # even parse the verbs that are switched off, so publishing those buttons
  # would offer Home Assistant a control whose only effect is a journal error.
  #
  # They are decided inside the jq program rather than by
  # assembling this string from pieces in Nix: an indented Nix string has its
  # own indentation stripped, so concatenated fragments come out ragged in the
  # middle of a program where indentation is the only thing making it readable.
  discovery = ''
    ${pkgs.jq}/bin/jq -nc --arg w "$worker" --arg mac "$mac" \
      --arg tpl "{{ 'ON' if value == 'ready' else 'OFF' }}" \
      --argjson reboot ${lib.boolToString power.allowReboot} \
      --argjson suspend ${lib.boolToString power.allowSuspend} '
      {
        dev: { ids: ["rig-\($w)"], name: $w, mf: "XMRig", mdl: "NixOS mining rig",
               cns: (if $mac == "" then [] else [["mac", $mac]] end) },
        o: { name: "rig-mqtt-agent" },
        avty_t: "rig/\($w)/availability",
        cmps: ({
          state: { p: "sensor", name: "State", stat_t: "rig/\($w)/state",
                   uniq_id: "rig-\($w)-state", dev_cla: "enum",
                   options: ["starting","mining","ready","paused","shutting-down"] },

          # A template, where the protocol sketch had payload_on: "ready".
          # payload_on on its own says nothing about the other states, so the
          # binary sensor would hold "on" right through a pause instead of
          # falling back to "off". This also covers states added later.
          ready: { p: "binary_sensor", name: "Ready", stat_t: "rig/\($w)/state",
                   uniq_id: "rig-\($w)-ready", dev_cla: "running", val_tpl: $tpl },

          shutdown: { p: "button", name: "Shutdown", cmd_t: "rig/\($w)/cmd",
                      uniq_id: "rig-\($w)-shutdown", pl_prs: "shutdown" }
        }
        + (if $reboot then
             { restart: { p: "button", name: "Restart", cmd_t: "rig/\($w)/cmd",
                          uniq_id: "rig-\($w)-restart", pl_prs: "restart" } }
           else {} end)
        + (if $suspend then
             { sleep: { p: "button", name: "Sleep", cmd_t: "rig/\($w)/cmd",
                        uniq_id: "rig-\($w)-sleep", pl_prs: "sleep" } }
           else {} end)
        )
      }' \
      | ${pkgs.mosquitto}/bin/mosquitto_pub -q 1 -r \
          -t "homeassistant/device/rig-$worker/config" -s || true
  '';

  agent = pkgs.writeShellScript "rig-mqtt-agent" ''
    set -euo pipefail
    ${setup}

    # The XMRig token gets the same treatment as the broker password, and for
    # the same reason a `-H "Authorization: Bearer ..."` on the command line
    # would not: curl's -K file keeps it out of argv.
    printf 'header = "Authorization: Bearer %s"\n' "$(cat ${xmrigToken})" \
      > ${runtimeDir}/curl

    # The MAC of the interface holding the default route -- what the
    # integration used to read over SSH (const.py, MAC_PROBE) and what Home
    # Assistant's Wake-on-LAN now takes from the device registry instead. A
    # board with several ethernet ports and one cable has exactly one right
    # answer here, and this is it.
    #
    # Left out of the payload entirely when it cannot be read, rather than
    # published empty: an empty connection tuple is something the device
    # registry could match another device on.
    iface=$(${pkgs.iproute2}/bin/ip -o route get 1.1.1.1 2>/dev/null \
              | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    mac=$(${pkgs.iproute2}/bin/ip -o link show "$iface" 2>/dev/null \
            | sed -n 's|.*link/ether \([0-9a-f:]*\).*|\1|p')
    [ -n "$mac" ] || echo "rig-mqtt: no MAC on the default route — this rig cannot be woken." >&2

    # Reduces the XMRig summary to one word, keeping no state of its own.
    #
    # `mining` and `ready` are separate on purpose. XMRig reports a hashrate
    # within a second of starting, but RandomX spends another minute or two
    # finishing its dataset and the power draw climbs with it -- so treating
    # the first hash as "working" is how a rig's consumption gets measured on
    # a machine that is still starting up. A non-zero 60 s average says the
    # climb began; the 10 s average no longer running ahead of it says the
    # climb is over.
    #
    # An unreachable API means the agent is up and XMRig is not, which is what
    # `starting` means -- so that fallback is not an error path.
    state() {
      ${pkgs.curl}/bin/curl -fsS -K ${runtimeDir}/curl \
        http://127.0.0.1:${toString config.rig.mining.apiPort}/1/summary 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r '
            (.hashrate.total[0] // 0) as $h10 | (.hashrate.total[1] // 0) as $h60
            | if (.paused // false) then "paused"
              elif $h60 > 0 and $h10 <= $h60 * 1.1 then "ready"
              elif $h10 > 0 then "mining"
              else "starting" end' \
        || echo starting
    }

    # Publishing runs beside the subscription rather than after it, because
    # mosquitto_sub does not return while the broker is up. The subscriber is
    # the process that matters -- it holds the session carrying the will, so
    # its death is what has to fail the unit -- which is why this loop
    # swallows publish errors instead: a broker blip the subscriber survives
    # should not silently stop the state updates. systemd tears this down with
    # the rest of the cgroup once the subscriber goes.
    (
      # Nothing may claim `online` before the will is armed, and the will is
      # armed by the subscriber below. Retrying here is what waits for it, and
      # incidentally what waits for a broker that is not up yet.
      until pub "$base/availability" online; do sleep 5; done

      ${discovery} || true

      while :; do
        pub "$base/state" "$(state)" || true
        sleep ${toString cfg.interval}
      done
    ) &

    # The one long-lived connection, and the reason the will works at all: a
    # will belongs to a session, and the broker publishes it when *this*
    # socket dies unannounced -- power cut, network gone, kernel panic. A
    # mosquitto_pub that connects, publishes and disconnects politely takes
    # its will with it and would arm nothing.
    ${pkgs.mosquitto}/bin/mosquitto_sub -q 1 -t "$base/cmd" \
      --will-topic "$base/availability" --will-payload offline \
      --will-qos 1 --will-retain \
    | while read -r cmd; do
        echo "rig-mqtt: received $cmd"
        # The three words are HASS.Agent's, not this repo's: the Home
        # Assistant integration presses Windows machines and NixOS rigs
        # through one table, so translating them into rig-power's spelling is
        # this end's job.
        #
        # /run/current-system/sw/bin and not the store path, for the reason
        # modules/power.nix gives for its sudo rule: the store path changes
        # every time that script is edited, and this one is stable.
        case "$cmd" in
          shutdown) /run/current-system/sw/bin/rig-power off ;;
          restart)  /run/current-system/sw/bin/rig-power reboot ;;
          sleep)    /run/current-system/sw/bin/rig-power suspend ;;
          *)        echo "rig-mqtt: ignoring unknown command $cmd" >&2 ;;
        esac
      done

    # Reached when the subscription ends *without* an error of its own -- a
    # clean DISCONNECT from the broker, say. `set -o pipefail` already carries
    # a failing mosquitto_sub out of the pipeline, but a successful one would
    # leave the agent subscribed to nothing and exit 0, which
    # Restart=on-failure would honour by never bringing it back.
    echo "rig-mqtt: subscription ended, restarting." >&2
    exit 1
  '';

  announce = pkgs.writeShellScript "rig-mqtt-shutdown" ''
    set -euo pipefail

    # This is an ExecStop, so it also runs on `systemctl restart` during a
    # rebuild. Announcing an extinction there would be a lie, and an expensive
    # one: Home Assistant is being taught to trust this message over its own
    # inference.
    [ "$(${pkgs.systemd}/bin/systemctl is-system-running || true)" = "stopping" ] || exit 0

    ${setup}

    pub "$base/state" shutting-down

    # Availability retracted by hand, which the will cannot do here: the agent
    # is stopped with a SIGTERM that mosquitto_sub handles, so it disconnects
    # cleanly and the broker discards its will. Without this line the tidy
    # shutdown would be the one case that lies -- a rig switched off properly
    # would sit at a retained `online` until someone powered it back on.
    pub "$base/availability" offline
  '';

in
{
  imports = [ ./mining.nix ./power.nix ];

  options.rig.mqtt = {
    enable = lib.mkEnableOption "MQTT presence, state and power commands";

    broker = lib.mkOption {
      type = lib.types.str;
      example = "192.168.1.24";
      description = ''
        Address of the MQTT broker — the Mosquitto add-on on the Home
        Assistant box. No default on purpose: there is no address that is
        right anywhere, and a rig pointed at the wrong one looks perfectly
        healthy while publishing where nobody listens.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1883;
      description = "Broker port. Plain MQTT, LAN only.";
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "miner";
      description = ''
        Broker account, shared by the whole fleet. Shared deliberately: a rig
        publishes under its own worker name whichever account it uses, so one
        account per rig would buy six credentials to rotate and no separation
        that means anything.
      '';
    };

    passwordFile = lib.mkOption {
      # str and not path, for the reason spelled out in modules/monitoring.nix:
      # a Nix path literal is copied into the world-readable store.
      type = lib.types.str;
      default = "/etc/mqtt/password";
      description = ''
        File holding the broker password, outside the Nix store, written per
        rig by scripts/mk-secrets.sh and shipped by `nixos-anywhere
        --extra-files` exactly like the XMRig token.

        Missing, the agent does not start at all rather than crash-looping —
        see the ConditionPathExists below.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = ''
        Seconds between state publications. One local HTTP call and one
        retained message, so it is cheap; what it really sets is how long Home
        Assistant can be wrong about a rig that has just reached `ready`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    assertions = [{
      assertion = power.enable;
      message = ''
        rig.mqtt.enable requires rig.power.enable: the buttons this agent
        publishes are pressed by running `rig-power`, which modules/power.nix
        only installs when it is enabled.
      '';
    }];

    systemd.services.rig-mqtt = {
      description = "Announce rig state over MQTT and take power commands";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # A missing password file means a rig installed without its secrets, and
      # no amount of restarting fixes that. A failed condition leaves one line
      # in the journal and an inactive unit, where Restart= would leave a unit
      # failing every ten seconds for the life of the machine.
      unitConfig.ConditionPathExists = cfg.passwordFile;

      serviceConfig = {
        Type = "simple";
        # Root, rather than a dedicated user with a sudo grant. That
        # alternative needs the account, a LoadCredential for each of the two
        # 0600 secrets it reads, and a sudo rule for rig-power -- and
        # rig-power powers the machine off, so the grant is root's authority
        # reached through one more moving part. What is given up is the caller
        # in rig-power's journal line, which would name a service account
        # either way; what asked is an MQTT topic, and the agent logs the
        # command it received one line before it runs it.
        User = "root";
        ExecStart = "${agent}";
        # on-failure and not always: the script exits 0 in exactly one case,
        # an empty password file, and that is the case where restarting is
        # pointless.
        Restart = "on-failure";
        RestartSec = 10;
      };
    };

    # `shutting-down`, and the unit ordering that is the whole difficulty.
    #
    # The obvious shape -- DefaultDependencies=no, WantedBy=poweroff.target,
    # Before=poweroff.target -- publishes nothing, ever. Units pulled in that
    # way run at the very end of the shutdown transaction, once the network
    # units have been stopped and the link is down, so mosquitto_pub blocks
    # until it times out and the machine powers off regardless. The message
    # never leaves, and nothing about the unit looks wrong.
    #
    # So this is an ordinary service and its ExecStop is the hook. systemd
    # stops units in the reverse of the order it started them, which makes
    # After=network-online.target on the way up mean "before the network goes
    # away" on the way down. Its default dependencies already carry
    # Conflicts=shutdown.target and Before=shutdown.target -- that *is* the
    # "before poweroff" that was wanted, with a working network, which the
    # literal reading does not have.
    #
    # RemainAfterExit is what makes ExecStop run at all: without it the unit
    # is already inactive by then and systemd has nothing left to stop.
    systemd.services.rig-mqtt-shutdown = {
      description = "Announce a clean shutdown over MQTT";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "rig-mqtt.service" ];
      wants = [ "network-online.target" ];
      unitConfig.ConditionPathExists = cfg.passwordFile;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/true";
        ExecStop = "${announce}";
      };
    };

    # Coming back from `rig-power suspend`, on the same NixOS-specific target
    # modules/power.nix explains at length for rig-wol-resume.
    #
    # A restart rather than a couple of publishes, because what S3 broke is
    # the socket and not the messages. Suspend freezes the agent with its
    # connection open; the broker gives up on it after a keepalive or two and
    # publishes the will, so Home Assistant already believes this rig is gone,
    # and the thawed mosquitto_sub is holding a session the broker has
    # forgotten. Publishing `online` from a fresh mosquitto_pub would answer
    # that and leave the rig with no armed will at all. Restarting reconnects,
    # re-arms it, and republishes availability, discovery and state.
    #
    # Not strictly required -- mosquitto_sub's keepalive notices the dead
    # socket eventually and the unit restarts on its own. This turns "within a
    # minute or two" into "on resume", which matters because a rig is usually
    # woken by something that wants to use it now.
    systemd.services.rig-mqtt-resume = {
      description = "Reconnect the MQTT agent after resume from suspend";
      wantedBy = [ "post-resume.target" ];
      after = [ "suspend.target" "post-resume.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl restart rig-mqtt.service";
      };
    };

    # For `mosquitto_sub -h <broker> -t '#' -v` from the rig itself, which is
    # how you find out whether the fleet's messages look like the protocol
    # says they should.
    environment.systemPackages = [ pkgs.mosquitto ];

    # Same reasoning as the XMRig token and the Glances password: the file
    # lives outside the store by design, so its absence is only knowable on
    # the running machine -- and here the unit simply never starts, which is
    # quiet enough to miss.
    system.activationScripts.rigMqttPassword = ''
      if [ ! -f ${cfg.passwordFile} ]; then
        echo "WARNING: ${cfg.passwordFile} is missing — this rig will not announce itself over MQTT."
        echo "  sudo install -Dm600 /dev/stdin ${cfg.passwordFile} <<< 'the fleet password'"
      fi
    '';
  };
}
