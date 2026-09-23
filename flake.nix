{
  description = "GoodSync for Linux, packaged for Nix/NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      packages.${system} = {
        default = pkgs.callPackage ./package.nix { };
        goodsync = self.packages.${system}.default;
      };

      overlays.default = final: prev: {
        goodsync = final.callPackage ./package.nix { };
      };

      nixosModules.default = { lib, pkgs, ... }: {
        imports = [ ./module.nix ];
        services.goodsync.package = lib.mkDefault (pkgs.callPackage ./package.nix { });
      };
    };
}