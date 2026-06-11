{
  description = "Declarative, modded Squad dedicated server fleets on NixOS";

  outputs = { self, ... }: {
    nixosModules = {
      squad-servers = import ./squad-servers.nix;
      squadjs = import ./squadjs.nix;
      default = {
        imports = [ ./squad-servers.nix ./squadjs.nix ];
      };
    };
  };
}
