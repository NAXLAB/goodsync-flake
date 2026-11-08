# GoodSync for Linux, repackaged from the vendor's Makeself `.run` installer.
#
# This file is only the derivation. Where the installer comes from (version,
# download URL, detected version) is decided in flake.nix, which passes
# `version` and `src` in.
{
  lib,
  stdenv,
  version,
  src,
  python3,
  makeWrapper,
  copyDesktopItems,
  makeDesktopItem,
  writeText,
  writeShellScript,
  libxcrypt-legacy,
  xdg-utils,
  coreutils,
}:

let
  # `readelf -d` on gsync / gs-server / gscp shows only libc plus these two
  # (libgcc_s.so.1 -> stdenv.cc.cc.lib, libcrypt.so.1 -> libxcrypt-legacy).
  # libc is deliberately NOT listed: the patched interpreter finds its own
  # libc, and LD_LIBRARY_PATH leaks into child processes (browsers, user
  # pre/post-sync commands), where a mismatched libc would be harmful.
  # installCheckPhase fails the build if a new vendor release needs more.
  libPath = lib.makeLibraryPath [
    stdenv.cc.cc.lib
    libxcrypt-legacy
  ];

  interpreter = stdenv.cc.bintools.dynamicLinker;

  # Points PT_INTERP of a vendor binary at the Nix loader, in place.
  patcher = writeText "patch-interp.py" ''
    """Point an ELF binary's PT_INTERP at a new loader path, in place.

    usage: patch-interp.py BINARY NEW_INTERPRETER

    Nothing is moved. The new path is written into the zero padding that
    follows the first LOAD segment (inside a page the kernel already maps),
    and that segment's file/mem size is extended to cover it. PT_INTERP is
    then pointed at the new string. Section headers are not updated; the
    kernel and ld.so ignore them.

    NOTE: record here why `patchelf` is not used for these binaries. (It is
    the reason this script exists; without it the next maintainer will
    "simplify" it.)

    Every layout assumption is checked and fails loudly, so a vendor build
    with a different layout stops the Nix build instead of producing a
    broken binary.
    """
    import struct
    import sys

    path = sys.argv[1]
    interp = sys.argv[2].encode() + b"\x00"

    data = bytearray(open(path, "rb").read())
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        sys.exit(path + ": not a 64-bit little-endian ELF")

    (e_phoff,) = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)

    PT_LOAD, PT_INTERP = 1, 3

    phs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        t, _fl, po, pv, _pp, fs, ms, _al = struct.unpack_from("<IIQQQQQQ", data, off)
        phs.append(dict(off=off, type=t, offset=po, vaddr=pv, filesz=fs, memsz=ms))

    ip = next((p for p in phs if p["type"] == PT_INTERP), None)
    if ip is None:
        sys.exit(path + ": no PT_INTERP (statically linked?)")

    loads = sorted((p for p in phs if p["type"] == PT_LOAD), key=lambda p: p["offset"])
    seg = next(
        (p for p in loads if p["offset"] <= ip["offset"] < p["offset"] + p["filesz"]),
        None,
    )
    if seg is None:
        sys.exit(path + ": PT_INTERP is not inside any LOAD segment")

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

    # Grow the LOAD segment: p_filesz and p_memsz are at phdr offsets 32 and 40.
    n = seg["filesz"] + len(interp)
    struct.pack_into("<QQ", data, seg["off"] + 32, n, n)

    # Retarget PT_INTERP: p_offset, p_vaddr, p_paddr, p_filesz, p_memsz at 8..48.
    struct.pack_into(
        "<QQQQQ", data, ip["off"] + 8,
        start, vaddr, vaddr, len(interp), len(interp),
    )

    open(path, "wb").write(data)
    print(path + ": interpreter -> " + sys.argv[2])
  '';

  # Runs the client against the already-running gs-server and opens the Web
  # UI. gsync's output is passed through untouched (tee, unbuffered) so that
  # interactive prompts without a trailing newline, such as the first-run
  # account setup, appear immediately; a copy is scanned for the Web UI URL.
  # The URL is scraped from gsync's human-readable output: if the vendor
  # changes that format, auto-open silently stops (the client is unaffected).
  # gsync, stdbuf, tee and xdg-open are found via the PATH set by the wrapper
  # below.
  launcher = writeShellScript "goodsync-launcher" ''
    set -euo pipefail

    stdbuf -o0 gsync /gsweb | tee >(
      opened=0
      while IFS= read -r line; do
        if [ "$opened" -eq 0 ] && [[ "$line" =~ https://[0-9.]+:([0-9]+)/web-ui ]]; then
          xdg-open "https://127.0.0.1:''${BASH_REMATCH[1]}/web-ui" >/dev/null 2>&1 &
          opened=1
        fi
      done
    )
  '';
in
stdenv.mkDerivation {
  pname = "goodsync";
  inherit version src;

  nativeBuildInputs = [
    makeWrapper
    copyDesktopItems
    python3
  ];

  # The .run is a Makeself archive. --noexec extracts it without running the
  # vendor's install-script.sh (which wants root, /usr/bin, systemd, ...).
  # --nox11/--noprogress avoid the X-detection probe and progress-bar TTY
  # assumptions; --nochown skips the header's `chown -R` after extraction.
  #
  # The version is read from the archive header (`--info`), so a wrong
  # version (e.g. a misnamed local installer) fails here with a clear message.
  unpackPhase = ''
    runHook preUnpack

    got=$(sh "$src" --info | sed -n 's/^Identification:.* version //p')
    if [ "$got" != "${version}" ]; then
      echo "ERROR: installer reports version '$got' but the flake says '${version}'." >&2
      echo "The flake derives the version from the installer itself, so this should" >&2
      echo "not happen; if you pass version/src by hand, make sure they agree." >&2
      exit 1
    fi

    sh "$src" --noexec --nox11 --noprogress --nochown --target ./source

    runHook postUnpack
  '';
  sourceRoot = "source";

  dontConfigure = true;
  dontBuild = true;
  # We rewrite the ELF interpreter ourselves (see `patcher`). Nothing else may
  # touch these binaries: strip/patchelf in fixup would invalidate the
  # padding assumption the patcher relies on.
  dontPatchELF = true;
  dontStrip = true;

  # Mirrors what the vendor's install-script.sh does, minus the imperative
  # parts (service setup, /etc/goodsync, chown) which live in the NixOS module.
  installPhase = ''
    runHook preInstall

    libexec=$out/libexec/goodsync

    # Real binaries + the data file gsync expects next to itself live under
    # libexec, out of PATH; $out/bin holds only user-facing commands.
    install -Dm755 gsync          $libexec/gsync
    install -Dm755 gs-server      $libexec/gs-server
    install -Dm755 gscp           $libexec/gs-gscp   # vendor renames it on install
    install -Dm644 en-english.rfs $libexec/en-english.rfs

    # Resources for gs-server (/resources=...). The cert/key are the vendor's
    # own pair, shipped as-is; the module copies this out of the store at
    # runtime because the Job Server writes job-server.key alongside them.
    mkdir -p $out/share/goodsync-server
    cp -r html-templates web-res gs-server.crt gs-server.key \
      $out/share/goodsync-server/

    install -Dm644 html-templates/gslogo64.png \
      $out/share/icons/hicolor/64x64/apps/goodsync.png

    for bin in gsync gs-server gs-gscp; do
      python3 ${patcher} "$libexec/$bin" "${interpreter}"
    done

    mkdir -p $out/bin
    makeWrapper $libexec/gsync $out/bin/gsync \
      --prefix LD_LIBRARY_PATH : ${libPath} \
      --prefix PATH : ${lib.makeBinPath [ xdg-utils ]}
    makeWrapper $libexec/gs-server $out/bin/gs-server \
      --prefix LD_LIBRARY_PATH : ${libPath}
    makeWrapper $libexec/gs-gscp $out/bin/gs-gscp \
      --prefix LD_LIBRARY_PATH : ${libPath}
    makeWrapper ${launcher} $out/bin/goodsync \
      --prefix PATH : $out/bin:${lib.makeBinPath [ coreutils xdg-utils ]}

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    # 1. Every shared library each binary needs must resolve. This catches a
    #    new vendor dependency at build time instead of at first launch.
    #    (`ld.so --list` resolves libraries without running the program.)
    for bin in gsync gs-server gs-gscp; do
      missing=$(LD_LIBRARY_PATH=${libPath} ${interpreter} --list \
        "$out/libexec/goodsync/$bin" | grep 'not found' || true)
      if [ -n "$missing" ]; then
        echo "ERROR: $bin has unresolved libraries:" >&2
        echo "$missing" >&2
        echo "Add the providing package to libPath in package.nix." >&2
        exit 1
      fi
    done

    # 2. The vendor's own sanity check, run through the real wrapper on the
    #    patched binary.
    $out/bin/gs-gscp /sanity-check

    runHook postInstallCheck
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
      categories = [
        "Utility"
        "FileTools"
      ];
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
}