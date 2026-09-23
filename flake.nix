{
  description = "GoodSync for Linux, packaged for Nix/NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [ "goodsync" ];
        };
      in
      {
        packages.default = pkgs.callPackage ./package.nix { };
        packages.goodsync = self.packages.${system}.default;
      }
    ) // {
      overlays.default = final: prev: {
        goodsync = final.callPackage ./package.nix { };
      };

      # Defaults services.goodsync.package to this flake's own build, so the
      # unfree exception above applies and you don't need to allow it yourself.
      nixosModules.default = { lib, pkgs, ... }: {
        imports = [ ./module.nix ];
        services.goodsync.package = lib.mkDefault
          self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      };
    };
}
