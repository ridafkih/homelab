{ pkgs, self, lib }:
let
  host = self.nixosConfigurations.homelab;
  cfg = host.config;
  opts = host.options;

  networkModule = self + "/modules/network.nix";
  hardwareModule = self + "/hosts/homelab/hardware.nix";
  sourceOf = path: if builtins.pathExists path then builtins.readFile path else "";
  sourceLines = path: lib.splitString "\n" (sourceOf path);
  ownedSources = [ networkModule hardwareModule (self + "/tests/network.nix") ];

  hashChar = builtins.fromJSON ''"\u0023"'';
  hexRun = "[0-9a-fA-F]";
  machineIdLike = line: builtins.match ".*${hexRun}{32}.*" line != null;
  macLike = line: builtins.match ".*${hexRun}{2}(:${hexRun}{2}){5}.*" line != null;

  wired = cfg.systemd.network.networks."20-wired" or { };
  wireless = cfg.systemd.network.networks."10-wlp9s0" or { };
  networkd = cfg.systemd.network.config;
  kernelParams = cfg.boot.kernelParams;
  paramMentions = needle: builtins.any (param: lib.hasInfix needle param) kernelParams;
  initrdModules = cfg.boot.initrd.availableKernelModules;

  expectations = {
    networkModulePresent = builtins.pathExists networkModule;
    hardwareModulePresent = builtins.pathExists hardwareModule;

    kernelIs618 = lib.hasPrefix "6.18." cfg.boot.kernelPackages.kernel.version;
    kernelPinnedExplicitly =
      opts.boot.kernelPackages.highestPrio < 1500
      && cfg.boot.kernelPackages.kernel.version == pkgs.linuxPackages_6_18.kernel.version
      && lib.hasInfix "linuxPackages_6_18" (sourceOf hardwareModule);
    noNomodeset = !(paramMentions "nomodeset");
    noNvidiaDrmParam = !(paramMentions "nvidia_drm") && !(paramMentions "nvidia-drm.modeset=0");
    noNvidiaDrmBlacklist =
      !(builtins.elem "nvidia_drm" cfg.boot.blacklistedKernelModules)
      && !(builtins.elem "nvidia-drm" cfg.boot.blacklistedKernelModules);
    noUasQuirk =
      !(paramMentions "usb-storage.quirks")
      && !(lib.hasInfix "quirks" cfg.boot.extraModprobeConfig);
    initrdModules = builtins.all (name: builtins.elem name initrdModules) [
      "nvme"
      "xhci_pci"
      "ahci"
      "usb_storage"
      "uas"
      "sd_mod"
    ];
    kvmAmd = builtins.elem "kvm-amd" cfg.boot.kernelModules;
    systemdBoot = cfg.boot.loader.systemd-boot.enable && cfg.boot.loader.systemd-boot.configurationLimit == 10;
    efiVariables = cfg.boot.loader.efi.canTouchEfiVariables;
    amdMicrocode = cfg.hardware.cpu.amd.updateMicrocode;
    redistributableFirmware = cfg.hardware.enableRedistributableFirmware;
    hardwareDeclaresNoFilesystemsOrGpu =
      !(lib.hasInfix "fileSystems" (sourceOf hardwareModule))
      && !(lib.hasInfix "nvidia" (lib.toLower (sourceOf hardwareModule)));

    useNetworkd = cfg.networking.useNetworkd;
    noGlobalDhcp = cfg.networking.useDHCP == false;
    tempAddressesDisabled = cfg.networking.tempAddresses == "disabled";
    wiredMatchesLanInterface = (wired.matchConfig.Name or null) == cfg.homelab.lan.interface;
    wiredDhcpV4 = (wired.networkConfig.DHCP or null) == "ipv4";
    wiredAcceptsRa = (wired.networkConfig.IPv6AcceptRA or null) == true;
    wiredClientIdentifier = (wired.dhcpV4Config.ClientIdentifier or null) == "duid";
    wiredIaid = (wired.dhcpV4Config.IAID or null) == 3055685611;
    wiredIgnoresDhcpDns = (wired.dhcpV4Config.UseDNS or null) == false;
    wiredIgnoresRaDns = (wired.ipv6AcceptRAConfig.UseDNS or null) == false;
    wirelessMatched = (wireless.matchConfig.Name or null) == "wlp9s0";
    wirelessUnmanagedOnly = (wireless.linkConfig or null) == { Unmanaged = true; };
    keepsForeignRules = (networkd.networkConfig.ManageForeignRoutingPolicyRules or null) == false;
    keepsForeignRoutes = (networkd.networkConfig.ManageForeignRoutes or null) == false;
    duidTypeVendor = (networkd.dhcpV4Config.DUIDType or null) == "vendor";

    noMachineIdEtc = !(cfg.environment.etc ? "machine-id");
    noMachineIdLikeStrings = !(builtins.any machineIdLike (lib.concatMap sourceLines ownedSources));
    noMacAddresses = !(builtins.any macLike (lib.concatMap sourceLines ownedSources));
    noComments = builtins.all (path: !(lib.hasInfix hashChar (sourceOf path))) ownedSources;
  };

  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) expectations);

  clientIdPrefix = lib.concatStringsSep ":" [ "ff" "b6" "22" "0f" "eb" "00" "02" "00" "00" "ab" "11" "" ];
  raPrefix = "2001:db8:98:";

  vmTest = pkgs.testers.runNixOSTest {
    name = "network";

    nodes.router = { lib, ... }: {
      virtualisation.memorySize = 1024;
      virtualisation.cores = 2;
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.firewall.enable = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ { address = "10.0.0.1"; prefixLength = 24; } ];
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [ { address = "2001:db8:98::1"; prefixLength = 64; } ];
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          port = 0;
          interface = "eth1";
          bind-interfaces = true;
          dhcp-range = "10.0.0.100,10.0.0.199,1h";
          log-dhcp = true;
        };
      };
      services.radvd = {
        enable = true;
        config = ''
          interface eth1 {
            AdvSendAdvert on;
            MinRtrAdvInterval 3;
            MaxRtrAdvInterval 10;
            prefix 2001:db8:98::/64 {
              AdvOnLink on;
              AdvAutonomous on;
            };
          };
        '';
      };
    };

    nodes.homelab = { ... }: {
      imports = [ self.nixosModules.options networkModule ];
      virtualisation.memorySize = 1024;
      virtualisation.cores = 2;
      virtualisation.vlans = [ ];
      virtualisation.interfaces = {
        eno1 = { vlan = 1; assignIP = false; };
        wlp9s0 = { vlan = 2; assignIP = false; };
      };
      boot.kernelModules = [ "dummy" ];
    };

    testScript = ''
      import re

      start_all()
      router.wait_for_unit("dnsmasq.service")
      router.wait_for_unit("radvd.service")
      homelab.wait_for_unit("systemd-networkd.service")

      with subtest("rendered units carry the pinned DHCP identity and foreign-state settings"):
          wired = homelab.succeed("cat /etc/systemd/network/20-wired.network")
          assert "IAID=3055685611" in wired, wired
          assert "ClientIdentifier=duid" in wired, wired
          assert "UseDNS=false" in wired or "UseDNS=no" in wired, wired
          conf = homelab.succeed("cat /etc/systemd/networkd.conf")
          assert re.search(r"^ManageForeignRoutingPolicyRules=(no|false)$", conf, re.M), conf
          assert re.search(r"^ManageForeignRoutes=(no|false)$", conf, re.M), conf
          assert re.search(r"^DUIDType=vendor$", conf, re.M), conf
          homelab.fail("test -e /etc/machine-id -a -L /etc/machine-id")

      with subtest("eno1 takes a real DHCP lease with the IAID and vendor DUID client id"):
          homelab.wait_until_succeeds("ip -4 -o addr show dev eno1 scope global | grep -q 'inet 10[.]0[.]0[.]'", timeout=120)
          addr = homelab.succeed("ip -4 -o addr show dev eno1 scope global")
          match = re.search(r"inet (10\.0\.0\.\d+)/24", addr)
          assert match, addr
          lease_ip = match.group(1)
          assert "192.168." not in addr, addr
          router.wait_until_succeeds("grep -q ' ${clientIdPrefix}' /var/lib/dnsmasq/dnsmasq.leases", timeout=60)
          lease = router.succeed("grep ' ${clientIdPrefix}' /var/lib/dnsmasq/dnsmasq.leases")
          assert lease.split()[2] == lease_ip, lease

      with subtest("eno1 takes an RA address and no temporary address"):
          homelab.wait_until_succeeds("ip -6 -o addr show dev eno1 scope global | grep -q ' ${raPrefix}'", timeout=120)
          six = homelab.succeed("ip -6 -o addr show dev eno1")
          assert "temporary" not in six, six
          assert homelab.succeed("cat /proc/sys/net/ipv6/conf/eno1/use_tempaddr").strip() == "0"

      with subtest("wlp9s0 is unmanaged and down"):
          state = homelab.succeed("networkctl list --no-legend wlp9s0")
          assert "unmanaged" in state, state
          link = homelab.succeed("ip -o link show dev wlp9s0")
          flag_match = re.search(r"<([^>]*)>", link)
          assert flag_match, link
          flags = flag_match.group(1).split(",")
          assert "UP" not in flags, link

      rule_commands = [
          "ip rule add priority 5200 to 198.41.192.0/24 lookup main",
          "ip rule add priority 5205 fwmark 0x80000/0xff0000 lookup main",
          "ip rule add priority 5280 lookup main suppress_prefixlength 0",
          "ip rule add priority 5300 unreachable",
          "ip -6 rule add priority 5200 to 2606:4700:a0::/48 lookup main",
          "ip -6 rule add priority 5205 fwmark 0x80000/0xff0000 lookup main",
          "ip -6 rule add priority 5280 lookup main suppress_prefixlength 0",
          "ip -6 rule add priority 5300 unreachable",
      ]
      route_commands = [
          "ip link add dummy0 type dummy",
          "ip link set dummy0 up",
          "ip route add default dev dummy0 table 52",
          "ip route add throw 10.0.0.0/24 table 52",
          "ip route add 192.0.2.0/24 dev eno1 proto static",
          "ip -6 route add default dev dummy0 table 52",
      ]

      def foreign_state():
          rules = [
              line.strip()
              for family in ("-4", "-6")
              for line in homelab.succeed(f"ip {family} rule show").splitlines()
              if re.match(r"^52(00|05|80):|^5300:", line.strip())
          ]
          routes = (
              homelab.succeed("ip -4 route show table 52")
              + homelab.succeed("ip -6 route show table 52")
              + homelab.succeed("ip -4 route show 192.0.2.0/24")
          )
          return sorted(rules), sorted(line.strip() for line in routes.splitlines())

      with subtest("foreign policy rules and routes survive networkd reload and restart"):
          for command in rule_commands + route_commands:
              homelab.succeed(command)
          rules, routes = foreign_state()
          assert len(rules) == 8, rules
          assert len(routes) == 4, routes

          homelab.succeed("networkctl reload")
          homelab.sleep(5)
          homelab.wait_until_succeeds("networkctl status eno1 | grep -q 'State: routable'", timeout=60)
          assert foreign_state() == (rules, routes), foreign_state()

          homelab.succeed("systemctl restart systemd-networkd.service")
          homelab.wait_for_unit("systemd-networkd.service")
          homelab.wait_until_succeeds("networkctl status eno1 | grep -q 'State: routable'", timeout=60)
          homelab.sleep(5)
          assert foreign_state() == (rules, routes), foreign_state()
    '';
  };
in
if failed == [ ] then
  vmTest
else
  throw "homelab network expectations failed: ${lib.concatStringsSep ", " failed}"
