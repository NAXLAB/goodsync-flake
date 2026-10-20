{ lib
, stdenv
, glibc
, fetchurl
, makeWrapper
, copyDesktopItems
, makeDesktopItem
, libxcrypt-legacy
, xdg-utils
, coreutils
}:


stdenv.mkDerivation (finalAttrs:
let
  libPath = lib.makeLibraryPath [ glibc stdenv.cc.cc.lib libxcrypt-legacy ];
  loader = "${glibc}/lib/ld-linux-x86-64.so.2";
in
{
  
  pname = "goodsync";
  # Taken from the installer's own label ("GoodServer for Unix/Linux version ...").
  version = "12.11.8.8";

  # The vendor URL is unversioned: when GoodSync publishes a new build this
  # hash stops matching. To update, bump `version` and replace the hash with
  # the "got:" value from the failed build (or use lib.fakeHash to get it).
  src = fetchurl {
    url = "https://www.goodsync.com/download/goodsync-linux-x86_64-release.run";
    hash = "sha256-31ujLBPLqKvSvdgHykvY/Pj8yg7tL1FmsrsJtLTtIvw=";
  };

  nativeBuildInputs = [
    makeWrapper
    copyDesktopItems
  ];

  # `readelf -d` on gsync / gs-server / gscp shows only glibc plus these two:
  #   libcrypt.so.1 -> libxcrypt-legacy, libgcc_s.so.1 -> stdenv.cc.cc.lib
  buildInputs = [
    stdenv.cc.cc.lib
    libxcrypt-legacy
  ];

  # The .run is a Makeself archive. --noexec extracts it without running the
  # vendor's install-script.sh (which wants root, /usr/bin, systemd, ...).
  # --nox11/--noprogress just make the extraction itself more robust
  # headless (no X-detection probe, no progress-bar TTY assumptions).
  unpackPhase = ''
    runHook preUnpack
    sh "$src" --noexec --nox11 --noprogress --target ./source
    runHook postUnpack
  '';
  sourceRoot = "source";

  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true;
  dontAutoPatchelf = true;


  # Mirrors what install-script.sh does, minus the imperative parts (service
  # setup, /etc/goodsync, chown) which live in the NixOS module instead.
  installPhase = ''
    runHook preInstall

    # The vendor URL is unversioned (see the comment on `src` above), so a
    # silent mismatch is possible if a new release lands under the same
    # filename between when this hash was pinned and when it's rebuilt.
    # `gs-server` prints its own version string at startup, and it's also
    # embedded in the binary itself, so check for it here rather than only
    # discovering a mismatch later at runtime.
    grep -qa "${finalAttrs.version}" gs-server || {
      echo "ERROR: gs-server does not contain version string '${finalAttrs.version}'." >&2
      echo "The vendor likely shipped a new build under the same URL; update 'version' (and 'src.hash') in package.nix." >&2
      exit 1
    }

    # Real binaries + the data file gsync expects next to itself live under
    # libexec, out of PATH; $out/bin below holds only user-facing commands.
    install -Dm755 gsync                $out/libexec/goodsync/gsync
    install -Dm755 gs-server             $out/libexec/goodsync/gs-server
    install -Dm755 gscp                  $out/libexec/goodsync/gs-gscp   # vendor renames it on install
    install -Dm644 en-english.rfs        $out/libexec/goodsync/en-english.rfs

    # Resources for gs-server (/resources=...). The cert/key are the
    # vendor's own pair, shipped as-is; the module copies this out of the
    # store at runtime since the Job Server writes its own job-server.key
    # alongside them, and the store is read-only.
    mkdir -p $out/share/goodsync-server
    cp -r html-templates web-res gs-server.crt gs-server.key \
      $out/share/goodsync-server/

    install -Dm644 html-templates/gslogo64.png \
      $out/share/icons/hicolor/64x64/apps/goodsync.png

    runHook postInstall
  '';

  postFixup = ''
    mkdir -p $out/bin

    # Real binaries stay unmodified in libexec; these launch them via the loader.
    makeWrapper ${loader} $out/bin/gsync \
      --add-flags "--library-path ${libPath} $out/libexec/goodsync/gsync" \
      --prefix PATH : ${lib.makeBinPath [ xdg-utils ]}
    makeWrapper ${loader} $out/bin/gs-server \
      --add-flags "--library-path ${libPath} $out/libexec/goodsync/gs-server"
    makeWrapper ${loader} $out/bin/gs-gscp \
      --add-flags "--library-path ${libPath} $out/libexec/goodsync/gs-gscp"

    cat > $out/bin/goodsync <<GOODSYNC_EOF
#!${stdenv.shell}
set -euo pipefail
opened=0
${coreutils}/bin/stdbuf -oL "$out/bin/gsync" /gsweb | while IFS= read -r line; do
  printf '%s\n' "\$line"
  if [ "\$opened" -eq 0 ] && [[ "\$line" =~ https://[0-9.]+:([0-9]+)/web-ui ]]; then
    port="\''${BASH_REMATCH[1]}"
    ${xdg-utils}/bin/xdg-open "https://127.0.0.1:\$port/web-ui" >/dev/null 2>&1 &
    opened=1
  fi
done
GOODSYNC_EOF
    chmod +x $out/bin/goodsync
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "goodsync";
      desktopName = "GoodSync";
      genericName = "File Synchronization";
      comment = "File synchronization and backup";
      exec = "goodsync";
      icon = "goodsync";
      terminal = false;
      categories = [ "Utility" "FileTools" ];
    })
  ];

  meta = {
    description = "File synchronization and backup tool (CLI, server and local Web UI)";
    homepage = "https://www.goodsync.com/for-linux";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "goodsync";
  };
})
