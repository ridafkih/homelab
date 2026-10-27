{ pkgs, self, lib }:
let
  host = self.nixosConfigurations.homelab;
  hostCfg = host.config;
  hostOpts = host.options;

  optionsModule = self + "/modules/options.nix";
  networkModule = self + "/modules/network.nix";
  tailscaleModule = self + "/modules/tailscale.nix";
  egressModule = self + "/modules/egress-policy.nix";
  ownedSources = [ tailscaleModule egressModule (self + "/tests/egress.nix") ];
  modulesPresent = builtins.pathExists tailscaleModule && builtins.pathExists egressModule;

  sourceOf = path: if builtins.pathExists path then builtins.readFile path else "";
  hashChar = builtins.fromJSON ''"\u0023"'';
  shellDefault = builtins.fromJSON ''":\u002d"'';

  edge = (lib.evalModules { modules = [ optionsModule ]; }).config.homelab.cloudflareTunnelEdge;

  evalWith = extra: lib.nixosSystem {
    modules = [
      { nixpkgs.hostPlatform = "x86_64-linux"; system.stateVersion = "26.05"; }
      optionsModule
      networkModule
    ]
    ++ lib.optionals modulesPresent [ tailscaleModule egressModule ]
    ++ extra;
  };
  bare = lib.nixosSystem {
    modules = [
      { nixpkgs.hostPlatform = "x86_64-linux"; system.stateVersion = "26.05"; }
      optionsModule
      networkModule
    ];
  };
  failingCount = system: builtins.length (builtins.filter (a: !a.assertion) system.config.assertions);

  base = evalWith [ ];
  cfg = base.config;
  disabled = (evalWith [ { homelab.egress.enable = false; } ]).config;
  svc = cfg.systemd.services.egress-policy or { };
  unit = svc.unitConfig or { };
  serviceConfig = svc.serviceConfig or { };
  ts = cfg.services.tailscale;
  asList = value: if builtins.isList value then value else [ value ];
  mentionsTailscaled = attr: builtins.any (lib.hasInfix "tailscaled") (asList (svc.${attr} or [ ]));
  isTrue = value: value == true || value == "yes" || value == "true";
  isFalse = value: value == false || value == "no" || value == "false";

  expectations = {
    tailscaleModulePresent = builtins.pathExists tailscaleModule;
    egressModulePresent = builtins.pathExists egressModule;

    tailscaleEnabled = modulesPresent && ts.enable;
    tailscaleClientRouting = modulesPresent && ts.useRoutingFeatures == "client";
    tailscaleOpenFirewall = modulesPresent && ts.openFirewall;
    tailscaleSetFlags = modulesPresent && builtins.all (flag: builtins.elem flag ts.extraSetFlags) [
      "--exit-node=auto:any"
      "--exit-node-allow-lan-access"
      "--accept-dns=false"
    ];
    tailscaleNoAuthKey = modulesPresent && ts.authKeyFile == null;
    tailscaleMtu = modulesPresent && (cfg.systemd.services.tailscaled.environment.TS_DEBUG_MTU or null) == "1500";

    egressEnableOption = modulesPresent && (hostOpts.homelab ? egress) && hostOpts.homelab.egress.enable.default == true;
    egressServiceDeclared = modulesPresent && cfg.systemd.services ? egress-policy;
    egressServiceOffWhenDisabled = modulesPresent && !(disabled.systemd.services ? egress-policy);
    egressOneshot = (serviceConfig.Type or null) == "oneshot";
    egressRemainAfterExit = isTrue (serviceConfig.RemainAfterExit or null);
    egressNoDefaultDependencies = isFalse (unit.DefaultDependencies or null);
    egressWantedBySysinit = builtins.elem "sysinit.target" (svc.wantedBy or [ ]);
    egressWantsNetworkPre = builtins.elem "network-pre.target" (svc.wants or [ ]);
    egressBeforeNetworkPre = builtins.elem "network-pre.target" (svc.before or [ ]);
    egressBeforeTailscaled = builtins.elem "tailscaled.service" (svc.before or [ ]);
    egressBeforeDocker = builtins.elem "docker.service" (svc.before or [ ]);
    egressNotTiedToTailscaled = modulesPresent && !(builtins.any mentionsTailscaled [ "after" "requires" "bindsTo" "partOf" "requisite" "upholds" ]);
    egressNoExecStop =
      modulesPresent
      && !(serviceConfig ? ExecStop)
      && !(serviceConfig ? ExecStopPost)
      && (svc.preStop or "") == ""
      && (svc.postStop or "") == "";
    egressStopIfChangedFalse = (svc.stopIfChanged or true) == false;

    assertsEdgeV4NonEmpty = modulesPresent && failingCount (evalWith [ { homelab.cloudflareTunnelEdge.ipv4 = lib.mkForce [ ]; } ]) > failingCount base;
    assertsEdgeV6NonEmpty = modulesPresent && failingCount (evalWith [ { homelab.cloudflareTunnelEdge.ipv6 = lib.mkForce [ ]; } ]) > failingCount base;
    assertsForeignRulesKept = modulesPresent && failingCount (evalWith [
      { systemd.network.config.networkConfig.ManageForeignRoutingPolicyRules = lib.mkForce true; }
    ]) > failingCount base;
    noFailingAssertionsOfItsOwn = modulesPresent && failingCount base == failingCount bare;

    hostRunsEgressPolicy = hostCfg.systemd.services ? egress-policy && (hostCfg.homelab.egress.enable or false);
    hostRunsTailscale = hostCfg.services.tailscale.enable;
    noLanCidrOption = !(hostOpts.homelab.lan ? ipv4Cidr);
    noDockerCidrOption = !(hostOpts.homelab ? dockerCidr);
    noTailnetOption = !(hostOpts.homelab ? tailnet);

    noComments = builtins.all (path: !(lib.hasInfix hashChar (sourceOf path))) ownedSources;
    noShellDefaults = builtins.all (path: !(lib.hasInfix shellDefault (sourceOf path))) ownedSources;
  };

  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) expectations);

  probeImage = pkgs.dockerTools.buildImage {
    name = "egress-probe";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "egress-probe-root";
      paths = [ pkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [ "/bin/sleep" "36000" ];
  };

  pyList = values: "[" + lib.concatMapStringsSep ", " (value: "\"${value}\"") values + "]";

  vmTest = pkgs.testers.runNixOSTest {
    name = "egress";

    nodes.homelab = { ... }: {
      imports = [ optionsModule networkModule tailscaleModule egressModule ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      virtualisation.vlans = [ ];
      virtualisation.docker = {
        enable = true;
        daemon.settings = {
          ipv6 = true;
          fixed-cidr-v6 = "fd00:d0c::/64";
        };
      };
      boot.kernelModules = [ "dummy" ];
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
      };
      environment.systemPackages = [ pkgs.iproute2 ];
    };

    testScript = ''
      import re
      import time

      edge4 = ${pyList edge.ipv4}
      edge6 = ${pyList edge.ipv6}

      def expected_rules(edges):
          rules = [f"5200: from all to {prefix} lookup main" for prefix in edges]
          rules += [
              "5205: from all fwmark 0x80000/0xff0000 lookup main",
              "5280: from all lookup main suppress_prefixlength 0",
              "5300: from all unreachable",
          ]
          return sorted(rules)

      def our_rules(family):
          lines = homelab.succeed(f"ip {family} rule show").splitlines()
          found = []
          for line in lines:
              text = " ".join(line.split())
              text = re.sub(r" proto \S+", "", text)
              if re.match(r"^(5200|5205|5280|5300):", text):
                  found.append(text)
          return sorted(found)

      def assert_rules_exact(context):
          four = our_rules("-4")
          six = our_rules("-6")
          assert four == expected_rules(edge4), (context, four)
          assert six == expected_rules(edge6), (context, six)

      def route_dev(command):
          out = homelab.succeed(command)
          match = re.search(r" dev (\S+)", out)
          assert match, (command, out)
          return match.group(1)

      def assert_via(dev, family, dest, extra=""):
          got = route_dev(f"ip {family} route get {dest} {extra}")
          assert got == dev, (family, dest, extra, got)

      def assert_unreachable(family, dest, extra=""):
          status, out = homelab.execute(f"ip {family} route get {dest} {extra} 2>&1")
          assert status != 0, (family, dest, extra, out)
          assert "unreachable" in out.lower(), (family, dest, extra, out)

      def tx(dev):
          return int(homelab.succeed(f"cat /sys/class/net/{dev}/statistics/tx_packets").strip())

      def container_ping(dest):
          homelab.execute(f"docker exec probe ping -c 5 -i 0.2 -W 1 {dest}")
          time.sleep(1)

      from4 = "from 172.17.0.2 iif docker0"
      from6 = "from fd00:d0c::2 iif docker0"

      homelab.start()
      homelab.wait_for_unit("egress-policy.service")
      homelab.wait_for_unit("tailscaled.service")
      homelab.wait_for_unit("docker.service")
      homelab.wait_for_unit("systemd-networkd.service")

      with subtest("egress-policy is active at boot, ordered before tailscaled and docker, and has no stop action"):
          assert_rules_exact("boot")
          policy_up = int(homelab.succeed("systemctl show -P ActiveEnterTimestampMonotonic egress-policy.service").strip())
          tailscaled_start = int(homelab.succeed("systemctl show -P ExecMainStartTimestampMonotonic tailscaled.service").strip())
          docker_start = int(homelab.succeed("systemctl show -P ExecMainStartTimestampMonotonic docker.service").strip())
          assert 0 < policy_up <= tailscaled_start, (policy_up, tailscaled_start)
          assert policy_up <= docker_start, (policy_up, docker_start)
          assert homelab.succeed("systemctl show -P ExecStop egress-policy.service").strip() == ""
          assert "tailscaled" not in homelab.succeed("systemctl show --value -p BindsTo -p PartOf -p Requires egress-policy.service")

      with subtest("rules persist after systemctl stop tailscaled"):
          homelab.succeed("systemctl stop tailscaled.service")
          homelab.succeed("systemctl is-active egress-policy.service")
          assert_rules_exact("tailscaled stopped")

      homelab.succeed("docker load < ${probeImage}")
      homelab.succeed("docker run -d --name probe egress-probe:latest")
      homelab.wait_until_succeeds("docker exec probe true")
      probe_ip = homelab.succeed("docker inspect -f '{{.NetworkSettings.Networks.bridge.IPAddress}}' probe").strip()
      assert probe_ip == "172.17.0.2", probe_ip

      for dev in ["wan0", "lan0", "wg0"]:
          homelab.succeed(f"ip link add {dev} type dummy")
          homelab.succeed(f"ip link set {dev} multicast off")
          homelab.succeed(f"ip link set {dev} up")
      homelab.succeed("ip addr add 203.0.113.2/24 dev wan0")
      homelab.succeed("ip -6 addr add 2001:db8:ffff::2/64 dev wan0 nodad")
      homelab.succeed("ip addr add 10.0.0.98/24 dev lan0")
      homelab.succeed("ip -6 addr add 2001:db8:98::98/64 dev lan0 nodad")
      homelab.succeed("ip addr add 100.100.1.1/32 dev wg0")
      homelab.succeed("ip -6 addr add fd7a:115c:a1e0::1/128 dev wg0 nodad")
      homelab.execute("while ip -4 route del default 2>/dev/null; do :; done")
      homelab.execute("while ip -6 route del default 2>/dev/null; do :; done")
      homelab.succeed("ip route add default dev wan0")
      homelab.succeed("ip -6 route add default dev wan0")

      def fake_tailscale_up():
          for family in ["-4", "-6"]:
              homelab.succeed(f"ip {family} route add default dev wg0 table 52")
          homelab.succeed("ip route add 100.64.0.0/10 dev wg0 table 52")
          homelab.succeed("ip -6 route add fd7a:115c:a1e0::/48 dev wg0 table 52")
          homelab.succeed("ip route add throw 10.0.0.0/24 table 52")
          for family in ["-4", "-6"]:
              homelab.succeed(f"ip {family} rule add pref 5210 fwmark 0x80000/0xff0000 lookup main")
              homelab.succeed(f"ip {family} rule add pref 5230 lookup main suppress_prefixlength 0")
              homelab.succeed(f"ip {family} rule add pref 5270 lookup 52")
          homelab.succeed("ip rule add pref 5250 to 100.64.0.0/10 lookup 52")
          homelab.succeed("ip -6 rule add pref 5250 to fd7a:115c:a1e0::/48 lookup 52")

      def fake_tailscale_down():
          for family in ["-4", "-6"]:
              homelab.succeed(f"ip {family} route flush table 52")
              for pref in ["5210", "5230", "5250", "5270"]:
                  homelab.execute(f"while ip {family} rule del pref {pref} 2>/dev/null; do :; done")
              assert homelab.succeed(f"ip {family} route show table 52").strip() == ""

      fake_tailscale_up()
      time.sleep(3)

      with subtest("up: the internet goes via table 52 from the host and from a bridge container"):
          for extra in ["", from4]:
              assert_via("wg0", "-4", "1.1.1.1", extra)
              assert_via("wg0", "-4", "100.64.1.1", extra)
              assert_via("wan0", "-4", "198.41.192.7", extra)
              assert_via("lan0", "-4", "10.0.0.5", extra)
          for extra in ["", from6]:
              assert_via("wg0", "-6", "2001:4860::8888", extra)
              assert_via("wan0", "-6", "2606:4700:a0::8", extra)
              assert_via("lan0", "-6", "2001:db8:98::5", extra)
          assert_via("docker0", "-4", "172.17.0.2")
          assert_via("docker0", "-6", "fd00:d0c::2")
          assert_via("wan0", "-4", "1.1.1.1", "mark 0x80000")
          assert_via("wan0", "-6", "2001:4860::8888", "mark 0x80000")

      with subtest("up: real container packets to the internet leave on wg0, edge packets on wan0"):
          wg_before, wan_before = tx("wg0"), tx("wan0")
          container_ping("1.1.1.1")
          wg_after, wan_after = tx("wg0"), tx("wan0")
          assert wg_after - wg_before >= 5, (wg_before, wg_after)
          assert wan_after == wan_before, (wan_before, wan_after)
          wg_before, wan_before = tx("wg0"), tx("wan0")
          container_ping("198.41.192.7")
          wg_after, wan_after = tx("wg0"), tx("wan0")
          assert wan_after - wan_before >= 5, (wan_before, wan_after)
          assert wg_after == wg_before, (wg_before, wg_after)

      fake_tailscale_down()

      def assert_down_state(context):
          for extra in ["", from4]:
              for dest in ["1.1.1.1", "100.64.1.1", "172.31.255.1", "8.8.8.8"]:
                  assert_unreachable("-4", dest, extra)
              assert_via("wan0", "-4", "198.41.192.7", extra)
              assert_via("lan0", "-4", "10.0.0.5", extra)
          for extra in ["", from6]:
              for dest in ["2001:4860::8888", "fd7a:115c:a1e0::5"]:
                  assert_unreachable("-6", dest, extra)
              assert_via("wan0", "-6", "2606:4700:a0::8", extra)
              assert_via("lan0", "-6", "2001:db8:98::5", extra)
          assert_via("docker0", "-4", "172.17.0.2")
          assert_via("docker0", "-6", "fd00:d0c::2")
          assert_via("wan0", "-4", "1.1.1.1", "mark 0x80000")
          assert_via("wan0", "-6", "2001:4860::8888", "mark 0x80000")

      with subtest("down: table 52 gone fails closed while LAN, docker, edge and the control bootstrap still route"):
          assert_down_state("down")

      with subtest("down: real container packets to the internet go nowhere"):
          wg_before, wan_before = tx("wg0"), tx("wan0")
          status, out = homelab.execute("docker exec probe ping -c 3 -W 1 1.1.1.1 2>&1")
          time.sleep(1)
          assert status != 0, out
          assert tx("wan0") == wan_before, (wan_before, tx("wan0"))
          assert tx("wg0") == wg_before, (wg_before, tx("wg0"))

      with subtest("rules survive networkd reload and restart without duplicates"):
          homelab.succeed("networkctl reload")
          time.sleep(3)
          assert_rules_exact("networkctl reload")
          homelab.succeed("systemctl restart systemd-networkd.service")
          homelab.wait_for_unit("systemd-networkd.service")
          time.sleep(3)
          assert_rules_exact("networkd restart")
          assert_down_state("after networkd")

      with subtest("restarting egress-policy never opens a gap in the floor, prunes stale rules and adds no duplicates"):
          homelab.succeed("rm -f /tmp/floor-missing")
          homelab.succeed(
              "systemd-run --unit floor-poll --setenv=PATH=/run/current-system/sw/bin ${pkgs.bash}/bin/sh -c '"
              "while true; do "
              "ip -4 rule show pref 5300 | grep -q unreachable || echo v4 >> /tmp/floor-missing; "
              "ip -6 rule show pref 5300 | grep -q unreachable || echo v6 >> /tmp/floor-missing; "
              "done'"
          )
          homelab.wait_until_succeeds("systemctl is-active floor-poll.service")
          homelab.succeed("ip rule add pref 5200 to 192.0.2.0/24 lookup main")
          homelab.succeed("ip -6 rule add pref 5280 to 2001:db8:dead::/48 lookup main")
          for _ in range(5):
              homelab.succeed("systemctl restart egress-policy.service")
              homelab.succeed("systemctl is-active egress-policy.service")
          homelab.succeed("systemctl stop floor-poll.service")
          status, missing = homelab.execute("cat /tmp/floor-missing 2>/dev/null")
          assert missing.strip() == "", missing
          assert_rules_exact("egress-policy restart")
          assert_down_state("after egress-policy restart")

      with subtest("starting tailscaled again leaves exactly one of each rule"):
          homelab.succeed("systemctl start tailscaled.service")
          homelab.wait_for_unit("tailscaled.service")
          time.sleep(3)
          assert_rules_exact("tailscaled started again")
          homelab.succeed("systemctl stop tailscaled.service")
          assert_rules_exact("tailscaled stopped again")
          assert_unreachable("-4", "1.1.1.1")
          assert_unreachable("-6", "2001:4860::8888")
    '';
  };
in
if failed == [ ] then
  vmTest
else
  throw "homelab egress expectations failed: ${lib.concatStringsSep ", " failed}"
