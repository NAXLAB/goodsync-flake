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
    in
    {
      packages.${system} = {
        default = pkgs.callPackage ./package.nix { };
        goodsync = self.packages.${system}.default;
      };

      # For anyone who wants goodsync in their own nixpkgs instance instead 
      # (e.g. to use services.goodsync.package themselves, or just
      # `pkgs.goodsync` elsewhere) covered by their own allowUnfree.
      overlays.default = final: prev: {
        goodsync = final.callPackage ./package.nix { };
      };

      # Package already built above with unfree allowed, so enabling the
      # service needs nothing else from you: no overlay, no allowUnfree.
      nixosModules.default = { lib, ... }: {
        imports = [ ./module.nix ];
        services.goodsync.package = lib.mkDefault self.packages.${system}.default;
      };
    };
}
