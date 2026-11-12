{ pkgs, self, lib }:
let
  host = self.nixosConfigurations.homelab;
  cfg = host.config;
  opts = host.options;
  nft = "${host.pkgs.nftables}/bin/nft";

  dnsModule = self + "/modules/dns.nix";
  firewallModule = self + "/modules/firewall.nix";
  ingressModule = self + "/modules/ipv6-ingress.nix";
  ingressRules = self + "/modules/ipv6-ingress.nft";
  ingressRulesSha256 = "33dc80806c053e8da46aa64e6a743265e5ec3c85f97ce0ad869d597cc99cb19b";
  archFiles = [
    "host/etc/homelab-firewall/ipv6-ingress.nft"
    "host/etc/systemd/system/homelab-ipv6-ingress.service"
  ];
  ownedModules = [ dnsModule firewallModule ingressModule ];
  ownedSources = ownedModules ++ [ (self + "/tests/dns-firewall.nix") ];
  sourceOf = path: if builtins.pathExists path then builtins.readFile path else "";
  presentModules = builtins.filter builtins.pathExists ownedModules;
  hashChar = builtins.fromJSON ''"\u0023"'';

  tcpPorts = [ 22 53 80 443 3000 3389 4317 4318 4327 4328 8006 ];
  udpPorts = [ 53 3389 ];
  normalise = ports: lib.sort lib.lessThan (lib.unique ports);
  firewall = cfg.networking.firewall;
  udpWithoutTailscale = builtins.filter (port: port != cfg.services.tailscale.port) firewall.allowedUDPPorts;

  ingress = cfg.systemd.services.homelab-ipv6-ingress or null;
  ingressField = field: if ingress == null then null else ingress.${field} or null;
  ingressService = field: if ingress == null then null else ingress.serviceConfig.${field} or null;
  ingressUnit = field: if ingress == null then null else ingress.unitConfig.${field} or null;
  ingressList = field: let value = ingressField field; in if value == null then [ ] else value;
  isFalse = value: value == false || value == "no" || value == "false";
  isTrue = value: value == true || value == "yes" || value == "true";

  repoPath = toString self;
  repoDefinitions = option: builtins.filter (definition: lib.hasPrefix repoPath definition.file) option.definitionsWithLocations;

  failingMessages = extraModule:
    let
      extended = host.extendModules {
        modules = [ (self + "/secrets/test-module.nix") extraModule ];
      };
      failing = builtins.filter (assertion: !assertion.assertion) extended.config.assertions;
    in
    map (assertion: lib.toLower assertion.message) failing;
  guards = needle: extraModule:
    let
      result = builtins.tryEval (builtins.any (message: lib.hasInfix needle message) (failingMessages extraModule));
    in
    result.success && result.value;

  expectations = {
    dnsModulePresent = builtins.pathExists dnsModule;
    firewallModulePresent = builtins.pathExists firewallModule;
    ingressModulePresent = builtins.pathExists ingressModule;
    ingressRulesMovedByteIdentical =
      builtins.pathExists ingressRules && builtins.hashFile "sha256" ingressRules == ingressRulesSha256;
    archIngressFilesDeleted = builtins.all (file: !builtins.pathExists (self + "/${file}")) archFiles;

    resolvedDisabled = cfg.services.resolved.enable == false;
    nameserversLocalThenCloudflare = cfg.networking.nameservers == [ "127.0.0.1" "1.1.1.1" ];
    dockerHasNoDnsKey = !(cfg.virtualisation.docker.daemon.settings ? dns);
    dockerDnsKeyGuarded = guards "dns" { virtualisation.docker.daemon.settings.dns = [ "1.1.1.1" ]; };

    firewallEnabled = firewall.enable;
    tailscaleTrusted = builtins.elem "tailscale0" firewall.trustedInterfaces;
    tcpPortsAsToday = normalise firewall.allowedTCPPorts == tcpPorts;
    udpPortsAsToday = normalise udpWithoutTailscale == udpPorts;
    nmbdPortsDropped = !(builtins.elem 137 firewall.allowedUDPPorts) && !(builtins.elem 138 firewall.allowedUDPPorts);
    nftablesOff = cfg.networking.nftables.enable == false;
    nftablesNeverSet = repoDefinitions opts.networking.nftables.enable == [ ];
    nftablesGuarded = guards "nftables" { networking.nftables.enable = lib.mkForce true; };

    ingressUnitDefined = ingress != null && ingress.enable;
    ingressOneshot = ingressService "Type" == "oneshot";
    ingressRemainsAfterExit = isTrue (ingressService "RemainAfterExit");
    ingressLoadsMovedFile = builtins.pathExists ingressRules && ingressService "ExecStart" == "${nft} -f ${builtins.path { path = ingressRules; name = "ipv6-ingress.nft"; }}";
    ingressStopDeletesTable = ingressService "ExecStop" == "${nft} delete table ip6 homelab_ingress";
    ingressNoDefaultDependencies = isFalse (ingressUnit "DefaultDependencies");
    ingressBeforeNetworkAndDocker = builtins.all (unit: builtins.elem unit (ingressList "before")) [ "network-pre.target" "docker.service" ];
    ingressWantsNetworkPre = builtins.elem "network-pre.target" (ingressList "wants");
    ingressAfterLocalFsAndModules = builtins.all (unit: builtins.elem unit (ingressList "after")) [ "local-fs.target" "systemd-modules-load.service" ];
    ingressWantedByMultiUser = builtins.elem "multi-user.target" (ingressList "wantedBy");

    noComments = builtins.all (path: !(lib.hasInfix hashChar (sourceOf path))) ownedSources;
    noVarDefaults = builtins.all (path: !(lib.hasInfix ":-" (sourceOf path))) ownedModules;
  };

  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) expectations);

  listener = port: {
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind :: ${toString port}";
  };

  tailnetSource = "fd7a:115c:a1e0::5";
  lanAddress = addresses: (lib.findFirst (entry: entry.address != tailnetSource) { address = ""; } addresses).address;

  vmTest = pkgs.testers.runNixOSTest {
    name = "dns-firewall";

    nodes.client = { lib, ... }: {
      virtualisation.memorySize = 1024;
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.firewall.enable = false;
      networking.interfaces.eth1.ipv6.addresses = [ { address = tailnetSource; prefixLength = 128; } ];
      environment.systemPackages = [ pkgs.netcat ];
    };

    nodes.server = { nodes, ... }: {
      imports = [ self.nixosModules.options ] ++ presentModules;
      virtualisation.memorySize = 1024;
      virtualisation.vlans = [ ];
      virtualisation.interfaces.eno1 = { vlan = 1; assignIP = true; };
      networking.useNetworkd = true;
      networking.useDHCP = false;
      networking.interfaces.eno1.ipv6.routes = [
        {
          address = tailnetSource;
          prefixLength = 128;
          via = lanAddress nodes.client.networking.interfaces.eth1.ipv6.addresses;
        }
      ];
      environment.systemPackages = [ pkgs.nftables ];
      systemd.services.listen-80 = listener 80;
      systemd.services.listen-3000 = listener 3000;
      systemd.services.listen-9999 = listener 9999;
    };

    testScript = { nodes, ... }:
      let
        eno1 = nodes.server.networking.interfaces.eno1;
        v4 = lanAddress eno1.ipv4.addresses;
        v6 = lanAddress eno1.ipv6.addresses;
      in
      ''
        start_all()
        server.wait_for_unit("multi-user.target")
        client.wait_for_unit("multi-user.target")
        for port in (80, 3000, 9999):
            server.wait_for_unit(f"listen-{port}.service")
            server.wait_for_open_port(port)

        with subtest("the test NIC is named eno1"):
            assert "${v4}" != "" and "${v6}" != "", "server LAN addresses are unknown"
            server.succeed("ip link show eno1")
            server.succeed("ip -4 -o addr show dev eno1 | grep -q '${v4}/'")
            server.wait_until_succeeds("ip -6 -o addr show dev eno1 | grep -v tentative | grep -q '${v6}'", timeout=60)
            client.wait_until_succeeds("ip -6 -o addr show dev eth1 | grep -v tentative | grep -q '${tailnetSource}'", timeout=60)

        def assert_tables(when):
            ruleset = server.succeed("nft list ruleset")
            assert "table ip6 homelab_ingress" in ruleset, f"{when}: {ruleset}"
            assert "chain nixos-fw" in ruleset, f"{when}: {ruleset}"
            assert "tcp dport { 80, 443 } drop" in ruleset, f"{when}: {ruleset}"

        with subtest("ip6 homelab_ingress sits alongside the iptables firewall"):
            server.wait_for_unit("homelab-ipv6-ingress.service")
            server.wait_for_unit("firewall.service")
            assert_tables("boot")

        with subtest("both survive a firewall restart"):
            server.succeed("systemctl restart firewall.service")
            server.wait_for_unit("firewall.service")
            assert_tables("after firewall restart")
            server.succeed("systemctl is-active homelab-ipv6-ingress.service")

        with subtest("port 3000 is reachable over IPv4 and IPv6"):
            client.wait_until_succeeds("nc -4 -z -w2 ${v4} 3000", timeout=60)
            client.wait_until_succeeds("nc -6 -z -w2 ${v6} 3000", timeout=60)

        with subtest("an unlisted port is refused over both families"):
            client.fail("nc -4 -z -w2 ${v4} 9999")
            client.fail("nc -6 -z -w2 ${v6} 9999")

        with subtest("port 80: IPv4 open, LAN IPv6 dropped, tailnet IPv6 open"):
            client.succeed("nc -4 -z -w2 ${v4} 80")
            client.fail("nc -6 -z -w2 ${v6} 80")
            client.wait_until_succeeds("nc -6 -z -w2 -s ${tailnetSource} ${v6} 80", timeout=60)

        with subtest("resolv.conf lists 127.0.0.1 then 1.1.1.1"):
            resolv = server.succeed("cat /etc/resolv.conf")
            nameservers = [line.split()[1] for line in resolv.splitlines() if line.startswith("nameserver")]
            assert nameservers == ["127.0.0.1", "1.1.1.1"], resolv

        with subtest("systemd-resolved is not running"):
            server.fail("systemctl is-active systemd-resolved.service")
      '';
  };
in
if failed == [ ] then
  vmTest
else
  throw "homelab dns-firewall expectations failed: ${lib.concatStringsSep ", " failed}"
