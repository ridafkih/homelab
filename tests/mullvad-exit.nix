{ pkgs, self, lib }:
let
  fakeTailscale = pkgs.writeShellApplication {
    name = "tailscale";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      case "$1 ''${2:?}" in
        "status --json") cat "$FAKE_DIR/status.json" ;;
        "debug prefs") cat "$FAKE_DIR/prefs.json" ;;
        "exit-node suggest")
          if [ -e "$FAKE_DIR/suggest-fails" ]; then echo "no preferred DERP region" >&2; exit 1; fi
          cat "$FAKE_DIR/suggest.txt"
          ;;
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

  peer = id: dns: ip: tags: country: city: priority: online: {
    ID = id;
    DNSName = dns;
    TailscaleIPs = [ ip "fd7a:115c:a1e0::${id}" ];
    ExitNodeOption = true;
    Online = online;
    Tags = tags;
    Location = { CountryCode = country; CityCode = city; Priority = priority; };
  };

  mullvadNear = peer "mnear" "relay-near.example." "100.64.0.11" mullvadTag "FR" "MRS" 100 true;
  mullvadFar = peer "mfar" "relay-far.example." "100.64.0.12" mullvadTag "SE" "STO" 50 true;
  mullvadDown = peer "mdown" "relay-down.example." "100.64.0.13" mullvadTag "DE" "FRA" 200 false;
  laptop = peer "laptop" "laptop.example." "100.64.0.21" [ ] "CA" "VAN" 0 true;

  vancouverA = peer "vana" "ca-van-a.example." "100.64.1.1" mullvadTag "CA" "VAN" 100 true;
  vancouverB = peer "vanb" "ca-van-b.example." "100.64.1.2" mullvadTag "CA" "Van" 100 true;
  vancouverDown = peer "vandown" "ca-van-down.example." "100.64.1.3" mullvadTag "CA" "VAN" 100 false;
  seattle = peer "sea" "us-sea.example." "100.64.1.11" mullvadTag "US" "SEA" 100 true;
  toronto = peer "tor" "ca-tor.example." "100.64.1.21" mullvadTag "CA" "TOR" 100 true;
  denver = peer "den" "us-den.example." "100.64.1.31" mullvadTag "US" "DEN" 100 true;
  untaggedVancouver = peer "untagged" "untagged-van.example." "100.64.1.41" [ ] "CA" "VAN" 100 true;

  preferences = pkgs.writeText "preferences.json" (builtins.toJSON [
    { countryCode = "CA"; cityCode = "VAN"; }
    { countryCode = "US"; cityCode = "SEA"; }
    { countryCode = "CA"; cityCode = null; }
    { countryCode = "US"; cityCode = null; }
  ]);

  status = state: exit: peers: builtins.toJSON {
    BackendState = state;
    ExitNodeStatus = if exit == null then null else { ID = exit; Online = true; };
    Peer = lib.listToAttrs (map (p: lib.nameValuePair "key-${p.ID}" p) peers);
  };

  scenario = name: { state ? "Running", exit, peers, auto ? "", suggest ? "", suggestFails ? false, expectSet, expectExit ? 0 }: ''
    dir=$PWD/${name}
    mkdir -p "$dir"
    cat > "$dir/status.json" <<'JSON'
    ${status state exit peers}
    JSON
    printf '%s\n' ${lib.escapeShellArg (builtins.toJSON { AutoExitNode = auto; })} > "$dir/prefs.json"
    printf 'Suggested exit node: %s\nTo accept this suggestion, use `tailscale set --exit-node=%s`.\n' ${lib.escapeShellArg suggest} ${lib.escapeShellArg suggest} > "$dir/suggest.txt"
    ${lib.optionalString suggestFails ''touch "$dir/suggest-fails"''}
    code=0
    FAKE_DIR=$dir ${lib.getExe watchdog} ${preferences} > "$dir/out" 2>&1 || code=$?
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
    failedSuggestionFallsBackToPriority = {
      exit = "laptop";
      auto = "any";
      peers = [ mullvadFar mullvadNear laptop ];
      suggestFails = true;
      expectSet = "--exit-node=100.64.0.11";
    };
    noExitNodeGetsMullvad = { exit = null; peers = [ mullvadNear laptop ]; expectSet = "--exit-node=100.64.0.11"; };
    offlineMullvadNeverChosen = { exit = "laptop"; peers = [ mullvadDown laptop ]; expectSet = "--exit-node="; expectExit = 1; };
    noMullvadClearsAutoMode = { exit = null; auto = "any"; peers = [ mullvadDown laptop ]; expectSet = "--exit-node="; expectExit = 1; };
    noMullvadAndNoExitNodeStaysClear = { exit = null; peers = [ mullvadDown laptop ]; expectSet = ""; expectExit = 1; };
    notRunningDoesNothing = { state = "Stopped"; exit = "laptop"; peers = [ mullvadNear laptop ]; expectSet = ""; };

    firstPreferenceLeftAlone = { exit = "vanb"; peers = [ vancouverA vancouverB seattle mullvadNear ]; expectSet = ""; };
    europeanExitMovesToFirstPreference = {
      exit = "mnear";
      peers = [ mullvadNear seattle vancouverA ];
      suggest = "relay-near.example.";
      expectSet = "--exit-node=100.64.1.1";
    };
    lowerPreferenceMovesUp = { exit = "sea"; peers = [ seattle vancouverA ]; expectSet = "--exit-node=100.64.1.1"; };
    offlineFirstPreferenceFallsToSecond = { exit = "mnear"; peers = [ vancouverDown seattle toronto mullvadNear ]; expectSet = "--exit-node=100.64.1.11"; };
    countryPreferenceMatchesAnyCity = { exit = "mnear"; peers = [ mullvadNear denver toronto ]; expectSet = "--exit-node=100.64.1.21"; };
    lastPreferenceBeatsUnlisted = { exit = "mnear"; peers = [ mullvadNear denver ]; expectSet = "--exit-node=100.64.1.31"; };
    untaggedPeerNeverPreferred = { exit = "mnear"; peers = [ mullvadNear untaggedVancouver ]; expectSet = ""; };
    noExitNodeGetsFirstPreference = { exit = null; peers = [ mullvadNear seattle vancouverA ]; expectSet = "--exit-node=100.64.1.1"; };
    suggestionWithinPreferenceTaken = {
      exit = "mnear";
      peers = [ vancouverA vancouverB mullvadNear ];
      suggest = "ca-van-b.example.";
      expectSet = "--exit-node=100.64.1.2";
    };
    suggestionOutsidePreferenceIgnored = {
      exit = null;
      peers = [ vancouverB seattle ];
      suggest = "us-sea.example.";
      expectSet = "--exit-node=100.64.1.2";
    };
    autoModeOnPreferredGetsPinned = { exit = "vana"; auto = "any"; peers = [ vancouverA seattle ]; expectSet = "--exit-node=100.64.1.1"; };
  };
in
pkgs.runCommand "mullvad-exit" { } ''
  ${lib.concatStrings (lib.mapAttrsToList scenario scenarios)}
  if FAKE_DIR=$PWD ${lib.getExe watchdog} > missing.out 2>&1; then
    echo "missingPreferencesFails: exited 0"; exit 1
  fi
  if [ -e "$PWD/set.log" ]; then
    echo "missingPreferencesFails: called tailscale set"; exit 1
  fi
  echo "ok: missingPreferencesFails"
  echo ok > $out
''
