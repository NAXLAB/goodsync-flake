{ lib
, stdenv
, fetchurl
, dpkg
, autoPatchelfHook
, makeWrapper
, openssl
, zlib
, curl
, libxcrypt-legacy
, xdg-utils
, coreutils
, gnused
, gnugrep
, procps
, iproute2
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "goodsync";
  # Check https://www.goodsync.com/for-linux for the current version and
  version = "12.9.29";

  src = fetchurl {
    url = "https://www.goodsync.com/download/goodsync.x86_64.deb";
    # Placeholder. Get the real hash with:
    #   nix-prefetch-url https://www.goodsync.com/download/goodsync.x86_64.deb
    # then wrap the result: `nix hash convert --to sri --type sha256 <hash>`
    # (or just set this to lib.fakeHash, run the build once, and copy the
    # "got:" hash from the error message).
    hash = "sha256-t7xXLaK/xmo5uRWHoSLi7Q2iVC6YZTuk1GIBvXtmo0s=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
  ];

  # Runtime libs the GoodSync binaries link against. This is a reasonable
  # starting guess (it's a C/C++ app that talks TLS to sync servers), but
  # autoPatchelfHook will list anything still missing when you `nix build`;
  # add the matching nixpkgs package to this list and rebuild.
  buildInputs = [
    stdenv.cc.cc.lib
    openssl
    zlib
    curl
    libxcrypt-legacy
  ];

  # A .deb isn't a normal source tarball, so we unpack it ourselves instead
  # of using the default unpack phase.
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" source
    runHook postUnpack
  '';

  sourceRoot = "source";

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"

    # Debian packages normally install FHS-style under usr/. Confirm this
    # after an unpack (dpkg-deb -x goodsync.x86_64.deb /tmp/gs-inspect &&
    # find /tmp/gs-inspect) — some vendors use /opt/<name> instead, in
    # which case adjust this to `cp -r opt/goodsync $out` (or similar) and
    # symlink $out/bin/goodsync to the real binary.
    if [ -d usr ]; then
      cp -r usr/* "$out/"
    else
      echo "Unexpected .deb layout - inspect ./source and fix installPhase" >&2
      find . -maxdepth 2
      exit 1
    fi

    runHook postInstall
  '';

  postFixup = ''
    # autoPatchelfHook has already rewritten the ELF interpreter/RPATH by
    # this point. This wrapper just makes sure goodsync can find xdg-open
    # (to pop your browser to the Web UI) and basic system tools it may
    # shell out to.
    for prog in goodsync gsync gs-server gscp; do
      if [ -f "$out/bin/$prog" ]; then
        wrapProgram "$out/bin/$prog" \
          --prefix PATH : ${lib.makeBinPath [ xdg-utils coreutils gnused gnugrep procps iproute2 ]}
      fi
    done
  '';

  meta = {
    description = "File synchronization, backup and comparison tool for Linux (CLI + local Web UI)";
    homepage = "https://www.goodsync.com/for-linux";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "goodsync";
  };
})
