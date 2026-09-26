# goodsync-nix

A Nix flake that packages [GoodSync for Linux](https://www.goodsync.com/for-linux) (a proprietary file sync/backup tool) from the vendor's `.run` installer, plus a NixOS module that runs the GoodSync server (`gs-server`) as a systemd service backing the local Web UI.

GoodSync ships as a binary-only Linux release with no source available, so this packages the upstream `.run` archive directly (`autoPatchelfHook` handles the dynamic linking) rather than building from source.

## This project Does:

- The `goodsync`, `gsync`, and `gs-gscp` CLI tools
- A desktop entry that launches the Web UI
- A `services.goodsync` NixOS module that runs `gs-server` as a background systemd service
- `goodsync` auto-opens the Web UI in your default browser on the LAN URL, augmenting the lazy work of the goodsync devs who just pasted the URLs into the CLI output. (JK I love you goodsync devs)

## Requirements

- `x86_64-linux` only (matches the vendor's release)
- GoodSync's license is **unfree** — this flake allows it internally

## Quick start

### 1. Add the flake as an input

```nix
{
  inputs.goodsync.url = "github:NAXLAB/goodsync-nix";
}
```

### 2. Import the module and enable the service

```nix
{
  imports = [ inputs.goodsync.nixosModules.default ];

  services.goodsync = {
    enable = true;
    user = "nax";  # the user who owns sync jobs and runs `goodsync`
  };
}
```

### 3. Rebuild

```
sudo nixos-rebuild switch
```

### 4. Open the Web UI

Log in as the user you set above and run:

```
goodsync
```

This starts the client, connects to the already-running `gs-server` service, and opens the Web UI in your browser automatically. First run of the *service* generates a local server user and self-signed certs.

## Options

| Option | Type | Description |
|---|---|---|
| `services.goodsync.enable` | bool | Enables the `gs-server` systemd service. |
| `services.goodsync.package` | package | The GoodSync package to run. Defaults to this flake's own build when using `nixosModules.default`, already built with unfree allowed. |
| `services.goodsync.user` | string | The user `gs-server` runs as, and whose file access sync jobs use. Must also be the user who runs the `goodsync` client, since it needs read access to the server profile. |


## Where things Are

| Path | Contents |
|---|---|
| `/etc/goodsync/server` | `gs-server`'s own profile: local server user, auto-update settings. |
| `/etc/goodsync/resources` | Writable copy of static Web UI assets and certs, refreshed from the package on every service start. Not meant to be edited by hand. |
| `/etc/goodsync/gsweb` | **Your actual sync job definitions** (`jobs-groups-options.tix`). Back this up if you want to preserve your configured jobs. |
| `~/.goodsync` (per user) | Client-side profile used when running `goodsync`/`gsync` directly from a terminal. |

All of the above under `/etc/goodsync` are created and owned by `services.goodsync.user` automatically; you shouldn't need to touch permissions there yourself.

## License

This flake's own files (`flake.nix`, `module.nix`, `package.nix`) are provided as-is. GoodSync itself is proprietary software with an unfree license (`lib.licenses.unfree`); by enabling this package you accept GoodSync's own license terms, not a Nix/open-source one.