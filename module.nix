{ config, lib, pkgs, ... }:

let
  cfg = config.services.goodsync;

  # gsync hardcodes /etc/goodsync/server, so the layout has to match the
  # vendor installer (this is the "server profile not found" error).
  profileTop = "/etc/goodsync";
  profile = "${profileTop}/server";
  group = config.users.users.${cfg.user}.group;

  # Runs as root: create the profile dirs with the right owner.
  setupDirs = pkgs.writeShellScript "goodsync-server-setup-dirs" ''
    set -eu
    mkdir -p ${profile}
    chown ${cfg.user}:${group} ${profileTop} ${profile}
    chmod 0775 ${profileTop} ${profile}
  '';

  # Runs as cfg.user, same as the installer does after "Copying server
  # configuration files".
  prepare = pkgs.writeShellScript "goodsync-server-prepare" ''
    set -eu

    # Local server user, needed by `gsync /gsweb`. Only generate it once so
    # restarts don't rotate it. gsync also drops client state in $HOME, so
    # point that at a throwaway dir like the installer does.
    if [ ! -e ${profile}/users.tix ]; then
      home=$(mktemp -d)
      HOME="$home" ${cfg.package}/bin/gsync /generate-local-server-user ${profile}
      rm -rf "$home"
    fi

    # The self-updater can't do anything useful in the read-only Nix store.
    # settings.tix is created by gs-server on its first start, so this takes
    # effect from the second start onwards.
    if [ -e ${profile}/settings.tix ]; then
      sed -i \
        -e 's/^CheckNewVersion[[:blank:]]*=.*/CheckNewVersion = No/' \
        -e 's/^InstallNewVersion[[:blank:]]*=.*/InstallNewVersion = No/' \
        ${profile}/settings.tix
    fi
  '';
in
{
  options.services.goodsync = {
    enable = lib.mkEnableOption "the GoodSync server (gs-server), which backs the local Web UI";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The goodsync package to use.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = ''
        User to run gs-server as. Sync jobs run with this user's file access,
        and this user must also be the one running `goodsync`, so that it can
        read the server profile in ${profile}.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    # gs-server internally does getgrnam(cfg.user) to de-elevate; NixOS doesn't
    # create a same-named group by default, so ensure one exists.
    users.groups.${cfg.user} = lib.mkDefault {};

    # Gives you the `goodsync` / `gsync` commands and the desktop entry.
    environment.systemPackages = [ cfg.package ];

    systemd.services.goodsync-server = {
      description = "GoodSync Server";
      documentation = [ "https://www.goodsync.com/for-linux" ];
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      path = [ pkgs.coreutils pkgs.gnused ];
      environment.GS_OS_SERVER_PROFILE = profileTop;

      serviceConfig = {
        User = cfg.user;
        Group = cfg.user;
        # "+" = run this one as root regardless of User=
        ExecStartPre = [ "+${setupDirs}" "${prepare}" ];
        ExecStart = "${cfg.package}/bin/gs-server /profile=${profile} /resources=${cfg.package}/share/goodsync-server";
        Restart = "on-failure";
        RestartSec = 20;
      };
    };
  };
}
