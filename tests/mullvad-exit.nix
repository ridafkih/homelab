{ pkgs, self, lib }:
let
  fakeTailscale = pkgs.writeShellApplication {
    name = "tailscale";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      case "$1 ''${2:?}" in
        "status --json") cat "$FAKE_DIR/status.json" ;;
        "debug prefs") cat "$FAKE_DIR/prefs.json" ;;
        "exit-node suggest") cat "$FAKE_DIR/suggest.txt" ;;
        set*) shift; printf '%s\n' "$*" >> "$FAKE_DIR/set.log" ;;
        *) echo "unexpected tailscale call: $*" >&2; exit 64 ;;
      esac
    '';
  };

  watchdog = pkgs.writeShellApplication {
    name = "mullvad-exit";
    runtimeInputs = [ fakeTailscale pkgs.jq pkgs.gnused pkgs.coreutils ];
    text = builtins.readFile (self + "/modules/mullvad-exit.sh");
  };

  mullvadTag = [ "tag:mullvad-exit-node" ];

  peer = id: dns: ip: tags: priority: online: {
    ID = id;
    DNSName = dns;
    TailscaleIPs = [ ip "fd7a:115c:a1e0::${id}" ];
    ExitNodeOption = true;
    Online = online;
    Tags = tags;
    Location = { Priority = priority; };
  };

  mullvadNear = peer "mnear" "relay-near.example." "100.64.0.11" mullvadTag 100 true;
  mullvadFar = peer "mfar" "relay-far.example." "100.64.0.12" mullvadTag 50 true;
  mullvadDown = peer "mdown" "relay-down.example." "100.64.0.13" mullvadTag 200 false;
  laptop = peer "laptop" "laptop.example." "100.64.0.21" [ ] 0 true;

  status = state: exit: peers: builtins.toJSON {
    BackendState = state;
    ExitNodeStatus = if exit == null then null else { ID = exit; Online = true; };
    Peer = lib.listToAttrs (map (p: lib.nameValuePair "key-${p.ID}" p) peers);
  };

  scenario = name: { state ? "Running", exit, peers, auto ? "", suggest ? "", expectSet, expectExit ? 0 }: ''
    dir=$PWD/${name}
    mkdir -p "$dir"
    cat > "$dir/status.json" <<'JSON'
    ${status state exit peers}
    JSON
    printf '%s\n' ${lib.escapeShellArg (builtins.toJSON { AutoExitNode = auto; })} > "$dir/prefs.json"
    printf 'Suggested exit node: %s\nTo accept this suggestion, use `tailscale set --exit-node=%s`.\n' ${lib.escapeShellArg suggest} ${lib.escapeShellArg suggest} > "$dir/suggest.txt"
    code=0
    FAKE_DIR=$dir ${lib.getExe watchdog} > "$dir/out" 2>&1 || code=$?
    if [ "$code" != ${toString expectExit} ]; then
      echo "${name}: exit $code, expected ${toString expectExit}"; cat "$dir/out"; exit 1
    fi
    got=$(cat "$dir/set.log" 2>/dev/null || true)
    if [ "$got" != ${lib.escapeShellArg expectSet} ]; then
      echo "${name}: tailscale set [$got], expected [${expectSet}]"; cat "$dir/out"; exit 1
    fi
    echo "ok: ${name}"
  '';

  scenarios = {
    mullvadPinnedLeftAlone = { exit = "mnear"; peers = [ mullvadNear laptop ]; expectSet = ""; };
    autoModeOnMullvadGetsPinned = { exit = "mnear"; auto = "any"; peers = [ mullvadNear laptop ]; expectSet = "--exit-node=100.64.0.11"; };
    nonMullvadExitReplacedBySuggestion = {
      exit = "laptop";
      auto = "any";
      peers = [ mullvadFar mullvadNear laptop ];
      suggest = "relay-far.example.";
      expectSet = "--exit-node=100.64.0.12";
    };
    nonMullvadSuggestionIgnored = {
      exit = "laptop";
      peers = [ mullvadFar mullvadNear mullvadDown laptop ];
      suggest = "laptop.example.";
      expectSet = "--exit-node=100.64.0.11";
    };
    noExitNodeGetsMullvad = { exit = null; peers = [ mullvadNear laptop ]; expectSet = "--exit-node=100.64.0.11"; };
    offlineMullvadNeverChosen = { exit = "laptop"; peers = [ mullvadDown laptop ]; expectSet = ""; expectExit = 1; };
    notRunningDoesNothing = { state = "Stopped"; exit = "laptop"; peers = [ mullvadNear laptop ]; expectSet = ""; };
  };
in
pkgs.runCommand "mullvad-exit" { } ''
  ${lib.concatStrings (lib.mapAttrsToList scenario scenarios)}
  echo ok > $out
''
