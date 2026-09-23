# goodsync-flake

Unofficial Nix flake packaging [GoodSync for Linux](https://www.goodsync.com/for-linux) — a file sync/backup tool with a local browser-based Web UI (`http://localhost:11000`).

GoodSync doesn't ship source or a nixpkgs package, so this repackages their official `.deb` and patches the resulting binaries to run under Nix's non-FHS layout, using `autoPatchelfHook`.

> community-maintained, unofficial, not affiliated with GoodSync/Siber Systems. GoodSync itself is proprietary and requires a license (30-day free trial available). This repo only packages and downloads their official binary — it doesn't redistribute it.

## Requirements

- Nix with flakes enabled
- `x86_64-linux` (GoodSync doesn't publish an aarch64 Linux build as of this version.
- Unfree packages allowed

## Usage

### Quick try

```console
$ nix run github:NAXLAB/goodsync-flake
```

### As an input to your system flake

```nix
{
  inputs = {
    goodsync = {
        url                         = "github:NAXLAB/goodsync-flake";
        inputs.nixpkgs.follows      = "nixpkgs";
      };
  };

  outputs = { nixpkgs, goodsync, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        {
          environment.systemPackages = [
            goodsync.packages.x86_64-linux.default
          ];
        }
      ];
    };
  };
}
```

### Or just vendor `package.nix`

If you'd rather not add another flake input, copy `package.nix` into your own repo (e.g. `pkgs/goodsync/package.nix`) and call it directly:

```nix
environment.systemPackages = [
  (pkgs.callPackage ./pkgs/goodsync/package.nix { })
];
```

Either way, `nixpkgs.config.allowUnfreePredicate` (or `allowUnfree = true;`) needs to cover `goodsync` somewhere in your config, or the build refuses to proceed.

### Running it

```console
$ goodsync
```

starts the job server and opens your browser to the Web UI. First run asks you to sign in / start a trial.

To keep the Web UI available at `localhost:11000` in the background without launching a browser every time, run `gs-server` as a systemd user service:

```nix
systemd.user.services.goodsync-server = {
  description = "GoodSync job server";
  wantedBy = [ "default.target" ];
  serviceConfig = {
    ExecStart = "${pkgs.goodsync}/bin/gs-server";
    Restart = "on-failure";
  };
};
```

## Updating to a new GoodSync version

1. Check the current version at [goodsync.com/for-linux](https://www.goodsync.com/for-linux) and bump `version` in `package.nix`.
2. Re-fetch the hash, since the `.deb` at that URL changes with each release:
   ```console
   $ nix-prefetch-url https://www.goodsync.com/download/goodsync.x86_64.deb
   $ nix hash convert --to sri --type sha256 <hash-from-above>
   ```
3. Paste the result into `src.hash` in `package.nix`.
4. `nix build .#goodsync -L` and fix up `buildInputs` if `autoPatchelfHook` reports anything new as missing.

## Troubleshooting

**`auto-patchelf could not satisfy dependency foo.so.N`** — add the nixpkgs package providing that library to `buildInputs` in `package.nix`. `nix-locate <libname.so>` (from `nix-index`) or search.nixos.org will tell you which package to use.

**GoodSync looks for config/state under `/etc` or another path Nix can't write to** — check with:
```console
$ strace -f -e trace=openat $(nix build .#goodsync --no-link --print-out-paths)/bin/goodsync 2>&1 | grep ENOENT
```
If it's hardcoding a system path rather than respecting `$HOME`, you may need to `wrapProgram` an env var it accepts, or fall back to `pkgs.buildFHSEnv` instead of `autoPatchelfHook` — a heavier but more forgiving approach for binaries that assume a full Debian-like filesystem.

## Repo layout

```
flake.nix     — flake outputs: packages.goodsync, overlays.default
package.nix   — the actual derivation (dpkg-deb extraction + autoPatchelfHook)
```

## License

The packaging code in this repo (`flake.nix`, `package.nix`) is MIT-licensed — see [LICENSE](./LICENSE). GoodSync itself remains proprietary software owned by Siber Systems; using it is subject to their own license and trial/purchase terms.
