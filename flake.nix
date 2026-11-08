{
  description = "GoodSync for Linux, packaged for Nix/NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      # ---------------------------------------------------------------------
      # Where the installer comes from.
      #
      # The package is built from a local copy of the vendor's installer,
      # saved next to this file (`nix run .#update-installer` downloads it).
      # That keeps builds pure and reproducible: nothing is downloaded during
      # a build, and the installer never changes unless you replace the file.
      #
      # New-release warning: when evaluated with `--impure` (and only then),
      # the vendor's current installer is also downloaded and its version
      # compared with the local one. If the vendor's is newer, a warning is
      # printed and the build carries on with the local file. Pure
      # evaluation (the default) never touches the network and never warns.
      # ---------------------------------------------------------------------
      installerName = "goodsync-linux-x86_64-release.run";
      localInstaller = ./goodsync-linux-x86_64-release.run;
      upstreamUrl = "https://www.goodsync.com/download/${installerName}";

      # Read the version from an installer's own header (`--info` prints
      # "Identification: ... version X"). Needs a tiny derivation, so this is
      # import-from-derivation.
      versionOf =
        final: installer:
        lib.removeSuffix "\n" (
          builtins.readFile (
            final.runCommand "goodsync-version" { } ''
              sh ${installer} --info | sed -n 's/^Identification:.* version //p' > $out
            ''
          )
        );

      mkSource =
        final:
        if !(builtins.pathExists localInstaller) then
          throw (
            "goodsync-flake: ${installerName} not found next to flake.nix.\n"
            + "Download it with `nix run .#update-installer` (or curl -fL -o ${installerName} ${upstreamUrl}).\n"
            + "In a git checkout the file must be visible to Nix: use a `path:` flake reference, or `git add -f ${installerName}`."
          )
        else
          let
            version =
              let
                v = versionOf final localInstaller;
              in
              if v == "" then
                throw "goodsync-flake: could not read a version from ${installerName} (not a GoodSync installer, or did the vendor change the format?)"
              else
                v;

            # `builtins.currentSystem` only exists in impure evaluation.
            checkUpstream = builtins ? currentSystem;
            upstreamVersion = versionOf final (builtins.fetchurl upstreamUrl);
          in
          {
            src = localInstaller;
            version =
              if checkUpstream && lib.versionOlder version upstreamVersion then
                lib.warn (
                  "goodsync-flake: GoodSync ${upstreamVersion} is available; you have ${version}. "
                  + "Continuing with the local installer. Run `nix run .#update-installer` to fetch the new one."
                ) version
              else
                version;
          };

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
        # Unfree is allowed for this one package only, and only inside this
        # flake's own nixpkgs instance.
        config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "goodsync" ];
      };
    in
    {
      overlays.default = final: _prev: {
        goodsync = final.callPackage ./package.nix {
          inherit (mkSource final) version src;
        };
      };

      packages.${system} = {
        default = pkgs.goodsync;
        goodsync = pkgs.goodsync;
      };

      # Downloads the vendor's current installer and, if it is newer than the
      # local one (or there is none), saves it as ./${installerName}. Run it
      # from the flake's directory.
      apps.${system}.update-installer = {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = "goodsync-update-installer";
            runtimeInputs = [
              pkgs.curl
              pkgs.coreutils
              pkgs.gnused
            ];
            text = ''
              file=${installerName}
              tmp=$(mktemp -d)
              trap 'rm -rf "$tmp"' EXIT

              curl -fL ${upstreamUrl} -o "$tmp/gs.run"
              latest=$(sh "$tmp/gs.run" --info | sed -n 's/^Identification:.* version //p')
              [ -n "$latest" ] || { echo "could not read a version from the download" >&2; exit 1; }

              have=""
              if [ -e "$file" ]; then
                have=$(sh "$file" --info | sed -n 's/^Identification:.* version //p')
              fi

              if [ "$have" = "$latest" ]; then
                echo "Up to date ($latest)."
                exit 0
              fi
              if [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$have" "$latest" | sort -V | tail -n1)" != "$latest" ]; then
                echo "Local $have is newer than the vendor's download ($latest); leaving it alone."
                exit 0
              fi

              cp "$tmp/gs.run" "$file"
              echo "Saved version $latest as $file (previous: $have)."
              echo "Rebuild to use it. If Nix complains about a changed input hash, run: nix flake update goodsync"
            '';
          }
        );
      };

      # Throwaway VM for hand-testing, fully separate from the host's own
      # goodsync (own kernel, filesystem, /etc and network):
      #   nix run path:.#nixosConfigurations.vm.config.system.build.vm
      # Log in as alice / test. Delete ./nixos.qcow2 for a fresh start.
      nixosConfigurations.vm = lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.default
          {
            system.stateVersion = "25.05";
            users.users.alice = {
              isNormalUser = true;
              initialPassword = "test";
              extraGroups = [
                "wheel"
                "systemd-journal"
              ];
            };
            security.sudo.wheelNeedsPassword = false;
            services.goodsync = {
              enable = true;
              user = "alice";
            };
            virtualisation.vmVariant.virtualisation = {
              graphics = false;
              memorySize = 2048;
            };
          }
        ];
      };

      # Automated version of the same thing: `nix flake check` (needs KVM).
      checks.${system}.service = pkgs.testers.runNixOSTest {
        name = "goodsync-service";
        nodes.machine = _: {
          imports = [ self.nixosModules.default ];
          users.users.alice.isNormalUser = true;
          services.goodsync = {
            enable = true;
            user = "alice";
            networkWaitTimeout = 0;
          };
        };
        testScript = ''
          machine.wait_for_unit("goodsync-server.service")
          machine.wait_for_open_port(11000)  # Web UI (port seen in gs-server's log)
          # nothing under /etc/goodsync may be owned by anyone but the service user
          machine.succeed('test -z "$(find /etc/goodsync ! -user alice)"')
          machine.succeed("systemctl is-active goodsync-server.service")
        '';
      };

      # Uses the package built above (unfree already allowed), so enabling
      # the service needs no overlay and no allowUnfree from the consumer.
      nixosModules.default =
        { lib, ... }:
        {
          imports = [ ./module.nix ];
          services.goodsync.package = lib.mkDefault self.packages.${system}.default;
        };
    };
}