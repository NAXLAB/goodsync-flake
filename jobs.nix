# DRAFT, untested: declarative GoodSync jobs.
#
# Add `imports = [ ./jobs.nix ];` at the top of module.nix.
#
# Example:
#
#   services.goodsync.jobs.ZaiGoMaat = {
#     side1.dir = "/mnt/xdrive";
#     side2.dir = "/mnt/zaigomaat";
#     direction = 0;
#     reconnectSeconds = 120;
#     syncParallelThreads = true;
#     workerThreads = 3;
#     deleteEmptyFoldersMove = false;
#     filters = {
#       excludeHidden = true;
#       excludeSystem = true;
#       excluded = [ "/Games/" "/Programs/" ];
#     };
#     onFileChangeAction = 2;
#     onFileChangeDelay = 10;
#     onTimerAction = 2;
#     limitChangesPercent = 50;
#     copyExtendedAttrs = false;
#     linksOption = 1;
#   };
#
# Behaviour:
#  * Every option except the two directories defaults to null, meaning the
#    line is left out and GoodSync uses its own default.
#  * If no jobs are defined here, nothing happens and the file stays yours
#    (managed through the Web UI).
#  * If any job is defined here, the `Jobs = { ... }` section of the file is
#    replaced at every service start. Jobs made in the Web UI are lost on the
#    next restart. Accounts, global options and the deleted-jobs list are left
#    alone. The previous file is kept as jobs-groups-options.tix.bak.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.goodsync;

  # Same location module.nix calls `gsweb`; worth sharing one definition.
  jobsFile = "/etc/goodsync/gsweb/jobs-groups-options.tix";

  # ---------------------------------------------------------------- rendering
  renderValue = v:
    if builtins.isBool v then (if v then "Yes" else "No")
    else if builtins.isInt v then toString v
    else builtins.toJSON v; # quoted string

  kv = k: v: { inherit k v; };

  # "<indent>Key = value" per pair; null values are skipped.
  lines = indent: pairs: lib.concatMapStrings
    (p: lib.optionalString (p.v != null) "${indent}${p.k} = ${renderValue p.v}\n")
    pairs;

  extraLines = indent: extra: lines indent (lib.mapAttrsToList kv extra);

  mask = items:
    "<FileMask>\nMatches = (\n"
    + lib.concatMapStrings (i: "    ${builtins.toJSON i}\n") items
    + ") </FileMask>";

  renderSide = tag: s:
    "${tag} = <SideOptions>\n"
    + lines "  " [ (kv "AcctKey" s.account) (kv "ServerDir" s.dir) (kv "TimeStamp" s.timeStamp) ]
    + "</SideOptions>\n";

  renderFolderOptions = tag: extra:
    "${tag} = <FolderOptions>\n" + extraLines "  " extra + "</FolderOptions>\n";

  renderFilters = f:
    "Filters = <Filters>\n"
    + lines "  " [ (kv "ExcludeHidden" f.excludeHidden) (kv "ExcludeSystem" f.excludeSystem) ]
    + "Included = ${mask f.included}\n"
    + "Excluded = ${mask f.excluded}\n"
    + extraLines "  " f.extra
    + "</Filters>\n";

  renderJob = j:
    "Name = ${builtins.toJSON j.name}\n"
    + renderSide "Side1" j.side1
    + renderSide "Side2" j.side2
    + renderFolderOptions "SideOptions1" j.sideOptions1
    + renderFolderOptions "SideOptions2" j.sideOptions2
    + lines "" [
      (kv "TimeStamp" j.timeStamp)
      (kv "Direction" j.direction)
      (kv "ReconnectSeconds" j.reconnectSeconds)
      (kv "SyncParallelThreads" j.syncParallelThreads)
      (kv "WorkerThreads" j.workerThreads)
      (kv "DeleteEmptyFoldersMove" j.deleteEmptyFoldersMove)
    ]
    + renderFilters j.filters
    + lines "" [
      (kv "OnFileChangeAction" j.onFileChangeAction)
      (kv "OnFileChangeDelay" j.onFileChangeDelay)
      (kv "OnTimerAction" j.onTimerAction)
      (kv "LimitChangesPercent" j.limitChangesPercent)
      (kv "CopyExtendedAttrs" j.copyExtendedAttrs)
      (kv "LinksOption" j.linksOption)
    ]
    + extraLines "" j.extra;

  # Exactly the text between (and including) "Jobs = {" and "DelJobs = {".
  jobsText =
    "Jobs = {"
    + lib.concatMapStrings (j: " | <Job>\n${renderJob j}</Job>\n") (lib.attrValues cfg.jobs)
    + " } DelJobs = {";

  # Used only when no file exists yet: just the "Local" account plus our jobs.
  skeletonText = ''
    <GoodSyncSettings>
    ServerAccounts = <AccountManager>
    Servers = { | <ServerAcct>
      Key = "file://@"
      TimeStamp = 0
      Name = "Local"
    Conn = <Connect>
        Url = "file://"
    </Connect>
    ServerBmks = { } DelServerBmks = { }   time = 0
    </ServerAcct>
     } DelServers = { } Bookmarks = { } DelBookmarks = { } </AccountManager>
  '' + jobsText + " } Groups = { } DelGroups = { } </GoodSyncSettings>\n";

  jobsTextFile = pkgs.writeText "goodsync-jobs.txt" jobsText;
  skeletonFile = pkgs.writeText "goodsync-skeleton.tix" skeletonText;

  mergeScript = pkgs.writeText "goodsync-merge-jobs.py" ''
    import os, re, sys, tempfile

    target, jobs_path, skeleton_path = sys.argv[1:4]
    jobs = open(jobs_path).read()

    if os.path.exists(target):
        old = open(target).read()
        pat = re.compile(r"^Jobs = \{.*?\} DelJobs = \{", re.M | re.S)
        if not pat.search(old):
            sys.exit("goodsync: no 'Jobs = { ... } DelJobs = {' section in "
                     + target + "; refusing to touch it")
        new = pat.sub(lambda m: jobs, old, count=1)
    else:
        old = None
        new = open(skeleton_path).read()

    if new == old:
        sys.exit(0)

    if old is not None:
        with open(target + ".bak", "w") as f:
            f.write(old)

    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target))
    with os.fdopen(fd, "w") as f:
        f.write(new)
    os.chmod(tmp, 0o640)
    os.replace(tmp, target)
  '';

  # Runs as cfg.user, after setupDirs has created and chowned the directory.
  installJobs = pkgs.writeShellScript "goodsync-install-jobs" ''
    exec ${pkgs.python3}/bin/python3 -I ${mergeScript} \
      ${jobsFile} ${jobsTextFile} ${skeletonFile}
  '';

  # ------------------------------------------------------------------ options
  inherit (lib) mkOption types;

  optional' = type: description: mkOption {
    type = types.nullOr type;
    default = null;
    inherit description;
  };

  extraOption = what: mkOption {
    type = types.attrsOf (types.oneOf [ types.bool types.int types.str ]);
    default = { };
    example = { SomeSetting = true; };
    description = ''
      Settings of ${what} not covered by a dedicated option. Written verbatim
      as `Key = value` (bool -> Yes/No, int -> number, string -> quoted).
    '';
  };

  sideModule = { ... }: {
    options = {
      account = mkOption {
        type = types.str;
        default = "file://@";
        description = ''
          Account key (AcctKey). `file://@` is the built-in local filesystem
          account; other keys must exist in the file's account list.
        '';
      };
      dir = mkOption {
        type = types.str;
        example = "/mnt/data";
        description = "Folder to synchronize (ServerDir).";
      };
      timeStamp = mkOption {
        type = types.int;
        default = 0;
        description = "TimeStamp field; 0 in your existing file.";
      };
    };
  };

  filtersModule = { ... }: {
    options = {
      excludeHidden = optional' types.bool "ExcludeHidden.";
      excludeSystem = optional' types.bool "ExcludeSystem.";
      included = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Include masks (Included). Empty means include everything.";
      };
      excluded = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "/Games/" "Thumbs.db" ];
        description = "Exclude masks (Excluded).";
      };
      extra = extraOption "the Filters block";
    };
  };

  jobModule = { name, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = name;
        description = "Job name; defaults to the attribute name.";
      };
      side1 = mkOption { type = types.submodule sideModule; description = "Side1."; };
      side2 = mkOption { type = types.submodule sideModule; description = "Side2."; };
      sideOptions1 = extraOption "SideOptions1 (an empty block in your file; contents unknown to me)";
      sideOptions2 = extraOption "SideOptions2 (an empty block in your file; contents unknown to me)";

      timeStamp = mkOption {
        type = types.int;
        default = 0;
        description = "Job TimeStamp. Your file has a Unix time; I don't know whether GoodSync cares.";
      };
      direction = optional' types.int
        "Direction. Your job uses 0; I haven't verified what other values mean.";
      reconnectSeconds = optional' types.int "ReconnectSeconds.";
      syncParallelThreads = optional' types.bool "SyncParallelThreads.";
      workerThreads = optional' types.int "WorkerThreads.";
      deleteEmptyFoldersMove = optional' types.bool "DeleteEmptyFoldersMove.";

      filters = mkOption {
        type = types.submodule filtersModule;
        default = { };
        description = "Filters block.";
      };

      onFileChangeAction = optional' types.int "OnFileChangeAction (2 in your file).";
      onFileChangeDelay = optional' types.int "OnFileChangeDelay (10 in your file; probably seconds).";
      onTimerAction = optional' types.int "OnTimerAction (2 in your file).";
      limitChangesPercent = optional' types.int "LimitChangesPercent.";
      copyExtendedAttrs = optional' types.bool "CopyExtendedAttrs.";
      linksOption = optional' types.int "LinksOption (1 in your file).";

      extra = extraOption "the job";
    };
  };
in
{
  options.services.goodsync.jobs = mkOption {
    type = types.attrsOf (types.submodule jobModule);
    default = { };
    description = ''
      Jobs to define declaratively. Leave empty to manage jobs in the Web UI.
      See the comment at the top of jobs.nix for how this interacts with it.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.jobs != { }) {
    # mkAfter: must run after setupDirs (creates/chowns the directory).
    systemd.services.goodsync-server.serviceConfig.ExecStartPre =
      lib.mkAfter [ "${installJobs}" ];
  };
}
