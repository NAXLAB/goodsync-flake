{ lib
, stdenv
, glibc
, python3
, writeText
, makeWrapper
, copyDesktopItems
, makeDesktopItem
, libxcrypt-legacy
, xdg-utils
, coreutils
  # Supplied by flake.nix (the flake owns where the software comes from).
, version
, src
}:


stdenv.mkDerivation (finalAttrs:
let
  libPath = lib.makeLibraryPath [ glibc stdenv.cc.cc.lib libxcrypt-legacy ];

  # Points PT_INTERP at a new loader path without moving anything: the string
  # goes into the zero padding after the first LOAD segment (inside a page the
  # kernel already maps), and that segment's size is extended to cover it.
  patchInterp = writeText "patch-interp.py" ''
    import struct, sys

    path, interp = sys.argv[1], sys.argv[2].encode() + b"\x00"
    data = bytearray(open(path, "rb").read())
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        sys.exit(path + ": not a 64-bit little-endian ELF")

    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)

    phs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        t, fl, po, pv, pp, fs, ms, al = struct.unpack_from("<IIQQQQQQ", data, off)
        phs.append(dict(off=off, type=t, offset=po, vaddr=pv, filesz=fs, memsz=ms))

    ip = next(p for p in phs if p["type"] == 3)
    loads = sorted((p for p in phs if p["type"] == 1), key=lambda p: p["offset"])
    seg = next(p for p in loads
               if p["offset"] <= ip["offset"] < p["offset"] + p["filesz"])
    later = [p for p in loads if p["offset"] > seg["offset"]]
    if not later or seg["filesz"] != seg["memsz"]:
        sys.exit(path + ": unexpected segment layout")
    nxt = later[0]

    start = seg["offset"] + seg["filesz"]
    end = start + len(interp)
    vaddr = seg["vaddr"] + seg["filesz"]
    if end > nxt["offset"] or vaddr + len(interp) > nxt["vaddr"]:
        sys.exit(path + ": not enough padding for new interpreter path")
    if any(data[start:end]):
        sys.exit(path + ": padding is not empty")

    data[start:end] = interp
    n = seg["filesz"] + len(interp)
    struct.pack_into("<QQ", data, seg["off"] + 32, n, n)
    struct.pack_into("<QQQQQ", data, ip["off"] + 8,
                     start, vaddr, vaddr, len(interp), len(interp))
    open(path, "wb").write(data)
    print(path + ": interpreter -> " + sys.argv[2])
  '';
in
{

  pname = "goodsync";
  inherit version src;

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

    # `version` is set in flake.nix next to the source hash. gs-server prints
    # its own version string at startup, and it's also embedded in the binary
    # itself, so check that it matches `version` here rather than only
    # discovering a mismatch later at runtime. (-F: dots are literal.)
    grep -qaF "${finalAttrs.version}" gs-server || {
      echo "ERROR: gs-server does not contain version string '${finalAttrs.version}'." >&2
      echo "The vendor likely shipped a new build under the same URL; update 'version' (and 'src.hash') in flake.nix." >&2
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
    for bin in gsync gs-server gs-gscp; do
      ${python3}/bin/python3 ${patchInterp} \
        "$out/libexec/goodsync/$bin" "${glibc}/lib/ld-linux-x86-64.so.2"
    done

    # Non-fatal smoke test: the vendor's own sanity check, run on the patched binary.
    LD_LIBRARY_PATH=${libPath} $out/libexec/goodsync/gs-gscp /sanity-check \
      || echo "WARNING: gscp /sanity-check failed on the patched binary"

    mkdir -p $out/bin
    makeWrapper $out/libexec/goodsync/gsync $out/bin/gsync \
      --prefix LD_LIBRARY_PATH : ${libPath} \
      --prefix PATH : ${lib.makeBinPath [ xdg-utils ]}
    makeWrapper $out/libexec/goodsync/gs-server $out/bin/gs-server \
      --prefix LD_LIBRARY_PATH : ${libPath}
    makeWrapper $out/libexec/goodsync/gs-gscp $out/bin/gs-gscp \
      --prefix LD_LIBRARY_PATH : ${libPath}

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