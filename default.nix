{ mkDerivation, attoparsec, base, bytestring, containers
, data-default-class, filepath, hspec, hspec-discover, lib, mtl
, network, QuickCheck, safe-exceptions, text, time, unix
, utf8-string
}:
mkDerivation {
  pname = "libmpd";
  version = "0.10.0.0";
  src = ./.;
  libraryHaskellDepends = [
    attoparsec base bytestring containers data-default-class filepath
    mtl network safe-exceptions text time utf8-string
  ];
  testHaskellDepends = [
    attoparsec base bytestring containers data-default-class filepath
    hspec mtl network QuickCheck safe-exceptions text time unix
    utf8-string
  ];
  testToolDepends = [ hspec-discover ];
  homepage = "http://github.com/vimus/libmpd-haskell#readme";
  description = "An MPD client library";
  license = lib.licenses.mit;
}
