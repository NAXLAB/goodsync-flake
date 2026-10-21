{
  description = "GoodSync for Linux, packaged for Nix/NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [ "goodsync" ];
      };

      version = "12.11.8.8";
      src = pkgs.fetchurl {
        url = "https://www.goodsync.com/download/goodsync-linux-x86_64-release.run";
        hash = "sha256-31ujLBPLqKvSvdgHykvY/Pj8yg7tL1FmsrsJtLTtIvw=";
      };
    in
    {
      packages.${system} = {
        default = pkgs.callPackage ./package.nix { inherit version src; };
        goodsync = self.packages.${system}.default;
      };

      # For anyone who wants goodsync in their own nixpkgs instance instead
      # (e.g. to use services.goodsync.package themselves, or just
      # `pkgs.goodsync` elsewhere) covered by their own allowUnfree.
      overlays.default = final: prev: {
        goodsync = final.callPackage ./package.nix { inherit version src; };
      };

      # Package already built above with unfree allowed, so enabling the
      # service needs nothing else from you: no overlay, no allowUnfree.
      nixosModules.default = { lib, ... }: {
        imports = [ ./module.nix ];
        services.goodsync.package = lib.mkDefault self.packages.${system}.default;
      };
    };
}