{ pkgs, self, lib }:
let
  host = self.nixosConfigurations.homelab;
  cfg = host.config;
  opts = host.options;

  bundleEtcName = "homelab-ca/certs/ca-certificates.crt";
  bundleEtcPath = "/etc/${bundleEtcName}";
  bundleEntry = cfg.environment.etc.${bundleEtcName} or null;
  bundleSource = if bundleEntry == null then "" else bundleEntry.source;

  fixture = ./fixtures/emudhra-intermediate.pem;
  fixtureSha256 = "45:A8:83:F3:49:AE:DF:D5:F3:A6:49:B5:49:8F:FB:12:17:12:BA:8B:44:8F:3F:2A:91:DB:C5:A7:66:FC:DD:BE";
  verifyAt = "1793059200";
  stockBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  aaaSha256 = "D7:A7:A0:FB:5D:7E:27:31:D7:71:E9:48:4E:BC:DE:F7:1D:5F:0C:3E:0A:29:48:78:2B:C8:3E:E0:EA:69:9E:F4";

  defaultSchedule = "-a -n standby,q -s (S/../.././02|L/../01/./03)";
  archSmartdLines = [
    "DEFAULT ${defaultSchedule}"
    "/dev/disk/by-id/ata-ST12000VN0008-2YS101_ZRT2GJKS -o on -S on -W 4,50,60"
    "/dev/disk/by-id/ata-ST16000NT001-3LV101_ZRS26FDA -o on -S on -W 4,50,60"
    "/dev/disk/by-id/ata-ST2000DM006-2DM164_Z4Z9LD0N -o on -S on -W 4,50,60"
    "/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_23523B800268 -d nvme -W 4,75,82"
  ];

  archFiles = [
    "host/etc/smartd.conf"
    "host/etc/systemd/journald.conf.d/size.conf"
    "host/etc/ca-certificates/trust-source/blocklist/emudhra-compromised-intermediates-2026-10.pem"
    "host/etc/pacman.d/hooks/90-homelab-ca-sync.hook"
  ];

  smartd = cfg.services.smartd;
  notifiers = smartd.notifications;

  expectations = {
    bundleEtcPathOption = (cfg.homelab.trust.bundleEtcPath or null) == bundleEtcPath;
    bundleEtcPathReadOnly = opts.homelab.trust.bundleEtcPath.readOnly or false;
    bundleSourceOption = bundleEntry != null && (cfg.homelab.trust.bundleSource or null) == bundleSource;
    bundleSourceReadOnly = opts.homelab.trust.bundleSource.readOnly or false;
    bundlePublished = bundleEntry != null && bundleEntry.enable;
    bundleCopiedReadOnly = bundleEntry != null && bundleEntry.mode == "0444";
    bundleWithoutTrustRules = lib.hasSuffix "/etc/ssl/certs/ca-no-trust-rules-bundle.crt" bundleSource;

    smartdEnabled = smartd.enable;
    smartdNoAutodetect = !smartd.autodetect;
    smartdDefaultSchedule = smartd.defaults.monitored == defaultSchedule;
    smartdDevices = map (d: "${d.device} ${d.options}") smartd.devices == lib.drop 1 archSmartdLines;
    smartdNotifiersOff = !notifiers.mail.enable && !notifiers.wall.enable && !notifiers.x11.enable && !notifiers.test;
    productionKeepsDefaultQuitPolicy = !(builtins.elem "never" smartd.extraOptions);

    journaldCapped = builtins.elem "SystemMaxUse=1G" (lib.splitString "\n" cfg.services.journald.extraConfig);

    archFilesDeleted = builtins.all (file: !builtins.pathExists (self + "/${file}")) archFiles;
    noBlocklistShipped = !builtins.pathExists (self + "/host/etc/ca-certificates");
  };

  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) expectations);

  config = pkgs.runCommand "host-basics-config" { } ''
    failed='${lib.concatStringsSep " " failed}'
    if [ -n "$failed" ]; then
      echo "host-basics expectations failed: $failed" >&2
      exit 1
    fi
    touch $out
  '';

  trust = pkgs.runCommand "host-basics-trust" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    bundle='${bundleSource}'
    fixture=${fixture}

    fingerprint=$(openssl x509 -in "$fixture" -noout -fingerprint -sha256 | cut -d= -f2)
    if [ "$fingerprint" != '${fixtureSha256}' ]; then
      echo "fixture fingerprint is $fingerprint, expected ${fixtureSha256}" >&2
      exit 1
    fi

    if [ -z "$bundle" ] || [ ! -s "$bundle" ]; then
      echo "host publishes no CA bundle at ${bundleEtcPath}" >&2
      exit 1
    fi
    if grep -q 'BEGIN TRUSTED CERTIFICATE' "$bundle"; then
      echo "host bundle carries trust rules" >&2
      exit 1
    fi

    mkdir stock
    awk '/-----BEGIN/{n++; on=1; f=sprintf("stock/%03d.pem", n)} on{print > f} /-----END/{on=0; close(f)}' ${stockBundle}
    for cert in stock/*.pem; do
      if openssl x509 -in "$cert" -noout -subject | grep -q 'CN *= *AAA Certificate Services$'; then
        openssl x509 -in "$cert" -out aaa.pem
      fi
    done
    if [ ! -s aaa.pem ]; then
      echo "stock cacert carries no AAA Certificate Services root" >&2
      exit 1
    fi
    aaa=$(openssl x509 -in aaa.pem -noout -fingerprint -sha256 | cut -d= -f2)
    if [ "$aaa" != '${aaaSha256}' ]; then
      echo "AAA root fingerprint is $aaa, expected ${aaaSha256}" >&2
      exit 1
    fi
    if ! openssl verify -attime ${verifyAt} -CAfile aaa.pem "$fixture"; then
      echo "positive control failed: fixture does not chain to the stock AAA root" >&2
      exit 1
    fi

    if openssl verify -attime ${verifyAt} -CAfile "$bundle" "$fixture" > verify.log 2>&1; then
      cat verify.log >&2
      echo "eMudhra intermediate still verifies against the host bundle" >&2
      exit 1
    fi
    cat verify.log
    if ! grep -q 'error 20 ' verify.log; then
      echo "expected error 20 (unable to get local issuer certificate)" >&2
      exit 1
    fi
    touch $out
  '';

  moduleFiles = builtins.filter builtins.pathExists [
    (self + "/modules/monitoring.nix")
    (self + "/modules/trust.nix")
  ];

  vm = pkgs.testers.runNixOSTest {
    name = "host-basics";
    nodes.machine = {
      imports = [ self.nixosModules.options ] ++ moduleFiles;
      virtualisation.memorySize = 1024;
      services.smartd.extraOptions = [ "-q" "never" ];
    };
    testScript = ''
      expected = ${builtins.toJSON archSmartdLines}

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("smartd.service")
      machine.succeed("systemctl is-active smartd.service")

      unit = machine.succeed("systemctl cat smartd.service")
      configfile = unit.split("--configfile=", 1)[1].split()[0]
      rendered = machine.succeed(f"cat {configfile}")
      lines = [line.strip() for line in rendered.splitlines() if line.strip() and not line.strip().startswith(chr(35))]
      assert lines == expected, f"smartd.conf lines {lines!r} != {expected!r}"
      assert "DEVICESCAN" not in rendered, rendered
      assert "-M exec" not in rendered and "-m " not in rendered, rendered

      machine.succeed("grep -Eqx '[[:space:]]*SystemMaxUse=1G[[:space:]]*' /etc/systemd/journald.conf")

      machine.succeed("test -f ${bundleEtcPath}")
      machine.succeed("test ! -L ${bundleEtcPath}")
      mode = machine.succeed("stat -c %a ${bundleEtcPath}").strip()
      assert mode == "444", f"bundle mode {mode} != 444"
      machine.succeed("test -s ${bundleEtcPath}")
    '';
  };
in
pkgs.runCommand "host-basics" { } ''
  echo ${config} ${trust} ${vm} > $out
''
