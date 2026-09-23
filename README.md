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

## Repo layout

```
flake.nix     — flake outputs: packages.goodsync, overlays.default
package.nix   — the actual derivation (dpkg-deb extraction + autoPatchelfHook)
```

## License

The packaging code in this repo (`flake.nix`, `package.nix`) is MIT-licensed — see [LICENSE](./LICENSE). GoodSync itself remains proprietary software owned by Siber Systems; using it is subject to their own license and trial/purchase terms.