{ ... }:
let
  seagate = "-o on -S on -W 4,50,60";
in
{
  services.smartd = {
    enable = true;
    autodetect = false;
    defaults.monitored = "-a -n standby,q -s (S/../.././02|L/../01/./03)";
    devices = [
      {
        device = "/dev/disk/by-id/ata-ST12000VN0008-2YS101_ZRT2GJKS";
        options = seagate;
      }
      {
        device = "/dev/disk/by-id/ata-ST16000NT001-3LV101_ZRS26FDA";
        options = seagate;
      }
      {
        device = "/dev/disk/by-id/ata-ST2000DM006-2DM164_Z4Z9LD0N";
        options = seagate;
      }
      {
        device = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_23523B800268";
        options = "-d nvme -W 4,75,82";
      }
    ];
    notifications = {
      mail.enable = false;
      wall.enable = false;
      x11.enable = false;
      test = false;
    };
  };

  services.journald.extraConfig = "SystemMaxUse=1G";
}
