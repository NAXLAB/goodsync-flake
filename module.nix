{ config, lib, pkgs, ... }:

let
  cfg = config.services.goodsync;

  # gsync hardcodes /etc/goodsync/server, so the layout has to match the vendor installer
  profileTop = "/etc/goodsync";
  profile = "${profileTop}/server";
  # Static Web UI assets + certs, copied out of the read-only Nix store so the Job Server 
  #can write its own generated job-server.key alongside them.
  resources = "${profileTop}/resources";
  # Job Server's own profile: this is where job definitions
  # (jobs-groups-options.tix) live. Declared and owned explicitly rather
  # than left to be auto-created implicitly by the Job Server at runtime.
  gsweb = "${profileTop}/gsweb";

  # Runs as root: create the profile dirs with the right owner, and refresh
  # the writable copy of the package's static resources on every start.
  setupDirs = pkgs.writeShellScript "goodsync-server-setup-dirs" ''
    set -eu
    mkdir -p ${profile} ${resources} ${gsweb}

    # Mirror the package's static resources (web assets, vendor certs) into
    # place on every start, so upgrades take effect and files removed by a
    # newer release don't linger forever. Never touches job-server.key: the
    # Job Server generates that file into this same directory at runtime,
    # and it isn't part of the package's own tree, so --exclude leaves it
    # alone regardless of --delete.

    ${pkgs.rsync}/bin/rsync -a --delete --chmod=Du=rwx,Fu=rw,go= \
      --exclude=job-server.key \
      ${cfg.package}/share/goodsync-server/ ${resources}/

    chown -R ${cfg.user}:${cfg.user} ${profileTop}
    chmod 0750 ${profileTop} ${profile} ${resources} ${gsweb}
  '';

  # Runs as cfg.user, same as the installer does after "Copying server
  # configuration files".
  
  prepare = pkgs.writeShellScript "goodsync-server-prepare" ''
    set -eu

    # Local server user, needed by `gsync /gsweb`. Only generate it once so
    # restarts don't rotate it. gsync also drops client state in $HOME, so
    # point that at a throwaway dir like the installer does.
    home=$(mktemp -d)
    trap 'rm -rf "$home"' EXIT
    if [ ! -e ${profile}/users.tix ]; then
      HOME="$home" ${cfg.package}/bin/gsync /generate-local-server-user ${profile}
    fi

    # settings.tix doesn't exist until gs-server's first-ever start, so this
    # can't take effect until the *second* start of a fresh install; nothing
    # to do about that without touching gs-server's own file format.
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

    # No default here: nixosModules.default supplies one, built with unfree
    # allowed internally so nothing extra is required from your own config.
    # Only needs setting by hand if you're importing this module some other
    # way (e.g. standalone, or from the overlay-provided package instead).
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
        read the server profile in ${profile}. Must be an existing
        users.users.<name> definition.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.users.users ? ${cfg.user};
        message = "services.goodsync.user (\"${cfg.user}\") is not a defined users.users.<name>.";
      }
    ];

    # gs-server internally does getgrnam(cfg.user) to de-elevate; NixOS
    # doesn't create a same-named group by default, so ensure one exists.
    users.groups.${cfg.user} = {};

    # Gives you the `goodsync` / `gsync` commands and the desktop entry.
    environment.systemPackages = [ cfg.package ];

    systemd.services.goodsync-server = {
      description = "GoodSync Server";
      documentation = [ "https://www.goodsync.com/for-linux" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment.GS_OS_SERVER_PROFILE = profileTop;

      serviceConfig = {
        User = cfg.user;
        # Must match gs-server's hardcoded getgrnam(cfg.user)/setgid(nax)
        # expectation during de-elevation; without this the process starts
        # with the user's real primary group (e.g. "users") and the
        # setgid() call to the "cfg.user" group fails with EPERM.
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
