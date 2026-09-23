{ lib
, stdenv
, fetchurl
, autoPatchelfHook
, makeWrapper
, copyDesktopItems
, makeDesktopItem
, libxcrypt-legacy
, xdg-utils
, bash
, coreutils
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "goodsync";
  # Taken from the installer's own label ("GoodServer for Unix/Linux version ...").
  version = "12.11.7.7";

  # The vendor URL is unversioned: when GoodSync publishes a new build this
  # hash stops matching. To update, bump `version` and replace the hash with
  # the "got:" value from the failed build (or use lib.fakeHash to get it).
  src = fetchurl {
    url = "https://www.goodsync.com/download/goodsync-linux-x86_64-release.run";
    hash = "sha256-ZBXhvQnnOSZ6sh1rj3pXuazMt37Ax2kYqdznvWYEkUg=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
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
  unpackPhase = ''
    runHook preUnpack
    sh "$src" --noexec --target ./source
    runHook postUnpack
  '';
  sourceRoot = "source";

  dontConfigure = true;
  dontBuild = true;

  # Mirrors what install-script.sh does, minus the imperative parts (service
  # setup, /etc/goodsync, chown) which live in the NixOS module instead.
  installPhase = ''
    runHook preInstall

    install -Dm755 gsync     $out/bin/gsync
    install -Dm755 gs-server $out/bin/gs-server
    install -Dm755 gscp      $out/bin/gs-gscp   # vendor renames it on install

    # gsync expects this next to the binary (vendor TODO says it'll move)
    install -Dm644 en-english.rfs $out/bin/en-english.rfs

    # Resources for gs-server (/resources=...). The cert/key are required at
    # startup; the module copies this out of the store at runtime since the
    # Job Server writes its own job-server.key alongside them.
    mkdir -p $out/share/goodsync-server
    cp -r html-templates web-res gs-server.crt gs-server.key \
      $out/share/goodsync-server/

    install -Dm644 html-templates/gslogo64.png $out/share/pixmaps/goodsync.png

    runHook postInstall
  '';

  postFixup = ''
    # gsync opens your browser with xdg-open
    wrapProgram $out/bin/gsync \
      --prefix PATH : ${lib.makeBinPath [ xdg-utils ]}

    # The Debian package ships a `goodsync` command; it is just `gsync /gsweb`
    # (start the Web UI and open the browser). But gsync's own "am I on a
    # GUI session" check doesn't succeed in every environment (e.g. no X
    # libs detected), so instead of opening a browser it just prints the Web
    # UI URLs and does nothing further -- one URL per bound interface,
    # including Docker's default bridge (172.17.0.1) if present.
    #
    # So `goodsync` itself is a small wrapper: stream gsweb's output through
    # unchanged (so you still see everything gsync normally prints), but
    # also watch for the first non-Docker https://.../web-ui URL and open it
    # with xdg-open ourselves.
    cat > $out/bin/.goodsync-wrapped <<'GOODSYNC_EOF'
#!${bash}/bin/bash
set -euo pipefail
opened=0
${coreutils}/bin/stdbuf -oL "$GOODSYNC_GSYNC" /gsweb | while IFS= read -r line; do
  echo "$line"
  if [ "$opened" -eq 0 ] && [[ "$line" =~ https://([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+/web-ui ]]; then
    ip="''${BASH_REMATCH[1]}"
    if [ "$ip" != "172.17.0.1" ]; then
      xdg-open "$line" >/dev/null 2>&1 &
      opened=1
    fi
  fi
done
GOODSYNC_EOF
    chmod +x $out/bin/.goodsync-wrapped
    makeWrapper $out/bin/.goodsync-wrapped $out/bin/goodsync \
      --prefix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --set GOODSYNC_GSYNC $out/bin/gsync
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
