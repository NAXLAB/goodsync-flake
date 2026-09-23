{
  description = "GoodSync for Linux, packaged for Nix/NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
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
    };
}
