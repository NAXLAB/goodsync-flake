{ config, lib, pkgs, ... }:

let
  cfg = config.services.goodsync;

  profileTop = "/etc/goodsync";
  profile = "${profileTop}/server";
  resources = "${profileTop}/resources";
  group = config.users.users.${cfg.user}.group;

  setupDirs = pkgs.writeShellScript "goodsync-server-setup-dirs" ''
    set -eu
    mkdir -p ${profile} ${resources}
    chown ${cfg.user}:${group} ${profileTop} ${profile} ${resources}
    chmod 0775 ${profileTop} ${profile} ${resources}
  '';

  prepare = pkgs.writeShellScript "goodsync-server-prepare" ''
    set -eu

    if [ ! -e ${profile}/users.tix ]; then
      home=$(mktemp -d)
      HOME="$home" ${cfg.package}/bin/gsync /generate-local-server-user ${profile}
      rm -rf "$home"
    fi

    if [ -e ${profile}/settings.tix ]; then
      sed -i \
        -e 's/^CheckNewVersion[[:blank:]]*=.*/CheckNewVersion = No/' \
        -e 's/^InstallNewVersion[[:blank:]]*=.*/InstallNewVersion = No/' \
        ${profile}/settings.tix
    fi

    # Refresh static resources (web assets, vendor certs) from the package on
    # every start, so upgrades take effect. cp never deletes, so this never
    # touches job-server.key, which the Job Server generates into this same
    # directory at runtime and which isn't part of the package's own tree.
    cp -r ${cfg.package}/share/goodsync-server/. ${resources}/
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
        ExecStart = "${cfg.package}/bin/gs-server /profile=${profile} /resources=${resources}";
        Restart = "on-failure";
        RestartSec = 20;
      };
    };
  };
}
