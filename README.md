# goodsync-flake

A Nix flake that packages [GoodSync for Linux](https://www.goodsync.com/for-linux) (a proprietary file sync/backup tool) from the vendor's `.run` installer, plus a NixOS module that runs the GoodSync server (`gs-server`) as a systemd service backing the local Web UI.

GoodSync ships as a binary-only Linux release with no source available, so this packages the upstream `.run` archive directly rather than building from source.

## What's included

- The `goodsync`, `gsync`, `gs-server` and `gs-gscp` commands
- A desktop entry that launches the Web UI
- A `services.goodsync` NixOS module that runs `gs-server` as a background systemd service, so sync jobs keep running whether or not you're logged into a desktop session
- `goodsync` auto-opens the Web UI in your default browser, augmenting the lazy work of the goodsync devs who just pasted the URLs into the CLI output. (JK I love you goodsync devs)

## Requirements

- `x86_64-linux` only (matches the vendor's release)
- GoodSync's license is **unfree**. This flake allows it internally, scoped only to this one package, so it doesn't affect unfree settings anywhere else in your system config.

## Quick start

### 1. Add the flake as an input

```nix
{
  inputs.goodsync.url = "github:NAXLAB/goodsync-flake";

  # Optional: reuse your own nixpkgs instead of pulling in a second one.
  inputs.goodsync.inputs.nixpkgs.follows = "nixpkgs";
}
```

(If you want the local-installer fallback described under [Updating](#updating-to-a-new-goodsync-release), use a local checkout instead: `inputs.goodsync.url = "path:/path/to/goodsync-flake";`.)

### 2. Import the module and enable the service

```nix
{
  imports = [ inputs.goodsync.nixosModules.default ];

  services.goodsync = {
    enable = true;
    user = "alice";  # the user who owns sync jobs and runs `goodsync`
  };
}
```

### 3. Rebuild

```sh
sudo nixos-rebuild switch
```

### 4. Open the Web UI

Log in as the user you set above and run `goodsync` (or use the desktop entry).

This starts the client, connects to the already-running `gs-server`, and opens the Web UI in your browser. On the service's very first start it generates a local server user (once; restarts don't rotate it).

The Web UI is served over HTTPS with the certificate/key pair shipped in the vendor archive, which is the same for every install. Treat it as you would any service with a well-known key, and think before opening its port in your firewall. (The module does not open any ports.)

## Options

| Option | Type | Description |
|---|---|---|
| `services.goodsync.enable` | bool | Enables the `gs-server` systemd service. |
| `services.goodsync.package` | package | The GoodSync package to run. Defaults to this flake's own build when using `nixosModules.default`. |
| `services.goodsync.user` | string | The user `gs-server` runs as, and whose file access sync jobs use. Must also be the user who runs the `goodsync` client, since it needs read access to the server profile. Must be an existing `users.users.<name>`. |
| `services.goodsync.networkWaitTimeout` | unsigned int | Seconds to wait at startup for a default route before launching `gs-server` anyway (default `60`; `0` disables). `gs-server` enumerates network interfaces once at startup, so starting before the network is up can leave the Web UI unreachable. On a machine with no default route you pay the full timeout each boot. |

Notes:

- `gs-server` expects a group with the same name as its user, so the module creates one. Files created by sync jobs will therefore belong to group `<user>`, not your usual primary group.
- Update checks and auto-install are switched off in `settings.tix` on every service start (self-updating can't work inside the Nix store). Because the file doesn't exist until `gs-server`'s first-ever start, this takes effect from the second start of a fresh install.

## Using without the flake's NixOS module

If you only want the package (no managed service, for example because you'll run `gs-server` some other way), use the overlay:

```nix
nixpkgs.overlays = [ inputs.goodsync.overlays.default ];
```

or reference `inputs.goodsync.packages.${system}.goodsync` directly. The overlay path uses *your* nixpkgs instance, so you'll need your own `allowUnfree`, and you'll need to handle `gs-server`'s startup and profile setup yourself; the module in this flake does that for you.

## Where things live

| Path | Contents |
|---|---|
| `/etc/goodsync/server` | `gs-server`'s own profile: local server user, auto-update settings. |
| `/etc/goodsync/resources` | Writable copy of static Web UI assets and certs, refreshed from the package on every service start. Not meant to be edited by hand. |
| `/etc/goodsync/gsweb` | **Your sync job definitions** (`jobs-groups-options.tix`). Back this up if you want to preserve your configured jobs. Jobs are managed through the Web UI; this flake does not manage them declaratively. |
| `~/.goodsync` (per user) | Client-side profile used when running `goodsync`/`gsync` directly from a terminal. |

Everything under `/etc/goodsync` is created and owned by `services.goodsync.user`.

## How the flake is laid out

- `flake.nix` decides where the installer comes from (version, URL, hash, or a local file) and wires up the overlay, package, module and the `check-update` app.
- `package.nix` is just the derivation. It takes `version` and `src` and knows nothing about where they came from.
- `module.nix` is the NixOS module.

## How the package works

- The `.run` is a Makeself archive. It is extracted with `--noexec` so the vendor's `install-script.sh` (which wants root, `/usr/bin`, systemd, ...) never runs. `package.nix` mirrors what that script installs; the imperative parts live in the NixOS module.
- The vendor binaries are not run through `autoPatchelfHook` or `patchelf`. Instead a small embedded Python script rewrites `PT_INTERP` in place (see the docstring in `package.nix`), and wrapper scripts supply the two extra libraries (`libgcc_s`, `libcrypt`) via `LD_LIBRARY_PATH`.
- Build-time checks fail the build if: the archive's own version doesn't match the version the flake claims; any binary has an unresolved shared library; or the vendor's own `gs-gscp /sanity-check` fails on the patched binary.

## Updating to a new GoodSync release

By default the flake downloads the installer from GoodSync's website and verifies it against the version and hash pinned in the `upstream` block at the top of `flake.nix`.

The vendor's download URL is unversioned, so when they publish a new build the pinned hash stops matching. Nix can't see that happening during evaluation (builds are hash-pinned and sandboxed), so **the signal is a hash-mismatch error from the build**, or you can check on demand:

```sh
nix run .#check-update
```

That downloads the vendor's current installer and compares it to the pin. If it changed, it saves it into the current directory (run it from the flake's directory) as `goodsync-<version>.run`.

### Using a local installer instead of the download

1. Put the new installer next to `flake.nix`, named `goodsync-<version>.run`, for example `goodsync-12.11.9.0.run`. The version in the filename must match what the installer itself reports (the build checks this).
2. Rebuild. The flake sees the file, prints a warning that it is using the local installer instead of downloading, and uses it. If several `goodsync-*.run` files are present, the newest version wins.
3. When you want to go back to downloading, set `version` and `hash` in the `upstream` block of `flake.nix` (`check-update` prints both) and delete the local file.

Things to know:

- **Nix only sees files it's been given.** In a git checkout, untracked files are invisible to flakes. Either build from a path input (`nix build path:.`, or `inputs.goodsync.url = "path:/path/to/goodsync-flake"`), or `git add` the file. If you don't see the warning, Nix can't see the file.
- **Don't commit the installer.** It's about 24 MB, and redistributing a proprietary installer may not be permitted. Use the `path:` approach above so it never needs to be committed.
- **The fallback only works when you build from a local directory.** Consuming the flake as `github:NAXLAB/goodsync-flake` can only ever download.
- Because the vendor replaces the file at a fixed URL, older revisions of this flake stop being buildable from scratch once a new release ships. If that matters to you, keep your own binary cache.
- If a new release changes the installer's layout (new files, renamed binaries, new library dependencies), the build will fail loudly: missing files in the `install` lines, or an unresolved library reported by the install check. Update `package.nix` accordingly.

## Testing without touching your own GoodSync

Everything here can be tried in a throwaway QEMU VM that shares nothing with the host (own kernel, `/etc`, network), so it can't collide with a goodsync you already have running:

```sh
nix run .#nixosConfigurations.vm.config.system.build.vm
```

Log in as `alice` / `test` and run `systemctl status goodsync-server`, `goodsync`, etc. The VM keeps its disk in `./nixos.qcow2`; delete it for a clean slate. `nix flake check` runs an automated version (starts the service, checks it stays up and that `/etc/goodsync` is owned by the service user); both need KVM to be reasonably fast.

To exercise the two installer sources, use the same command with either `.` (git-tracked files only: downloads the pinned release) or `path:.` (sees an untracked or git-ignored local `goodsync-<version>.run`: prints the warning and uses it), for example `nix run path:.#nixosConfigurations.vm.config.system.build.vm`.

## License

This flake's own files are provided as-is (see `LICENSE`). GoodSync itself is proprietary software with an unfree license (`lib.licenses.unfree`); by enabling this package you accept GoodSync's own license terms, not a Nix/open-source one.