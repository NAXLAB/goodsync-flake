# goodsync-nix

A Nix flake that packages [GoodSync for Linux](https://www.goodsync.com/for-linux) (a proprietary file sync/backup tool) from the vendor's `.run` installer, plus a NixOS module that runs the GoodSync server (`gs-server`) as a systemd service backing the local Web UI.

GoodSync ships as a binary-only Linux release with no source available, so this packages the upstream `.run` archive directly (`autoPatchelfHook` handles the dynamic linking) rather than building from source.

## What you get

- The `goodsync`, `gsync`, and `gs-gscp` CLI tools
- A desktop entry that launches the Web UI
- A `services.goodsync` NixOS module that runs `gs-server` as a background systemd service, so sync jobs keep running whether or not you're logged into a desktop session
- `goodsync` auto-opens the Web UI in your default browser on the LAN URL, augmenting the lazy work of the goodsync devs who just pasted the URLs into the CLI output. (JK I love you goodsync devs)

## Requirements

- `x86_64-linux` only (matches the vendor's release)
- GoodSync's license is **unfree**

## Quick start

### 1. Add the flake as an input

```nix
{
  inputs.goodsync.url = "github:<you>/goodsync-nix";
}
```

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

`nixosModules.default` sets `services.goodsync.package` to this flake's own build by default, and that build is what carries the unfree exception below — so you don't need to separately `allowUnfree` your whole system just for this package.

### 3. Rebuild

```
sudo nixos-rebuild switch
```

### 4. Open the Web UI

Log in as the user you set above and run:

```
goodsync
```

This starts the client, connects to the already-running `gs-server` service, and opens the Web UI in your browser automatically. (First run of the *service* also silently generates a local server user and self-signed certs — this happens once, on the service's first start, not something you need to do yourself.)

## Options

| Option | Type | Description |
|---|---|---|
| `services.goodsync.enable` | bool | Enables the `gs-server` systemd service. |
| `services.goodsync.package` | package | The GoodSync package to run. Defaults to this flake's build when using `nixosModules.default`. |
| `services.goodsync.user` | string | The user `gs-server` runs as, and whose file access sync jobs use. Must also be the user who runs the `goodsync` client, since it needs read access to the server profile. |

## Using without the flake's NixOS module

If you only want the package (no managed service — e.g. you'll run `gs-server` some other way), use the overlay instead:

```nix
nixpkgs.overlays = [ inputs.goodsync.overlays.default ];
```

or reference `inputs.goodsync.packages.${system}.goodsync` directly. Note you'll then need to handle the unfree-license allowance and any `gs-server` startup/profile setup yourself — the module in this flake does both for you.

## Where things live

| Path | Contents |
|---|---|
| `/etc/goodsync/server` | `gs-server`'s own profile: local server user, auto-update settings. |
| `/etc/goodsync/resources` | Writable copy of static Web UI assets and certs, refreshed from the package on every service start. Not meant to be edited by hand. |
| `/etc/goodsync/gsweb` | **Your actual sync job definitions** (`jobs-groups-options.tix`). Back this up if you want to preserve your configured jobs. |
| `~/.goodsync` (per user) | Client-side profile used when running `goodsync`/`gsync` directly from a terminal. |

All of the above under `/etc/goodsync` are created and owned by `services.goodsync.user` automatically; you shouldn't need to touch permissions there yourself.

## Troubleshooting

- **`goodsync` says "Waiting for Job Server to respond" and times out.**
  Check `systemctl status goodsync-server` and `journalctl -u goodsync-server -e --no-pager -o cat`. The service must be `enable`d and successfully running before the client can connect; a failed `ExecStartPre` or a crashed `gs-server` will produce exactly this symptom.

- **Service fails at startup with a de-elevation or `getgrnam`/`setgid` error.**
  This build's module already works around GoodSync's assumption that a group named identically to the service user exists (NixOS doesn't create one by default) and that the process's primary group matches it. If you're modifying the module, keep `users.groups.${cfg.user}` and `serviceConfig.Group = cfg.user;` in place — removing either reintroduces this failure.

- **`Permission denied` writing into `/etc/goodsync/resources`.**
  This can happen if that directory was left in an inconsistent state from manual testing (e.g. created under a different user before the module owned it). It's safe to delete — it gets rebuilt from the package on every service start:
  ```
  sudo rm -rf /etc/goodsync/resources
  sudo systemctl restart goodsync-server
  ```

## Updating to a new GoodSync release

The vendor's download URL is unversioned, so bumping the package means:

1. Update `version` in `package.nix` to match the new release (visible in `gsync`'s own startup banner, e.g. `=== Started GoodSync (R) Ver 12.11.7.7 ...`).
2. Replace `src.hash` — set it to `lib.fakeHash` temporarily, run a build, and copy the "got:" hash from the resulting error into `package.nix`.

## License

This flake's own files (`flake.nix`, `module.nix`, `package.nix`) are provided as-is. GoodSync itself is proprietary software with an unfree license (`lib.licenses.unfree`); by enabling this package you accept GoodSync's own license terms, not a Nix/open-source one.
