############################################################################
# Extra Haskell packages which we build with haskell.nix, but which aren't
# part of our project's package set themselves.
#
# These are for e.g. developer usage, or for running formatting tests.
############################################################################
{ pkgs, compiler-nix-name, index-state, checkMaterialization, sources }:
{
  Agda = pkgs.haskell-nix.hackage-package {
    name = "Agda";
    version = "2.6.1";
    plan-sha256 = "0gvvhwjcwmq8avcqz8azv8db2171qvigkam3i9bgr6z13xk995ha";
    inherit compiler-nix-name index-state checkMaterialization;
    modules = [{
      # Agda is a huge pain. They have a special custom setup that compiles the interface files for
      # the Agda that ships with the compiler. These go in the data files for the *library*, but they
      # require the *executable* to compile them, which depends on the library!
      # They get away with it by using the old-style builds and building everything together, we can't
      # do that.
      # So we work around it:
      # - turn off the custom setup
      # - manually compile the executable (fortunately it has no extra dependencies!) and do the
      # compilation at the end of the library derivation.
      packages.Agda.package.buildType = pkgs.lib.mkForce "Simple";
      packages.Agda.components.library.postInstall = ''
        # Compile the executable using the package DB we've just made, which contains
        # the main Agda library
        ghc src/main/Main.hs -package-db=$out/package.conf.d -o agda

        # Find all the files in $out (would be $data if we had a separate data output)
        shopt -s globstar
        files=($out/**/*.agda)
        for f in "''${files[@]}" ; do
          echo "Compiling $f"
          # This is what the custom setup calls in the end
          ./agda --no-libraries --local-interfaces $f
        done
      '';
    }];
  };
  cabal-install = (pkgs.haskell-nix.cabalProject {
    name = "cabal-install";
    src = sources.cabal;
    modules = [{ reinstallableLibGhc = true; }];
    inherit compiler-nix-name index-state checkMaterialization;
    # Invalidate and update if you change the version or index-state
    plan-sha256 = {
      ghc883 = "0z65sq5jp9hlxsxr5adkf34frbjzc8m8szx6gl781avwidn856c8";
      ghc884 = "0900jwc351i0dw1fdfxiyz4gmfzdc0g7fsf1lh3lssrih5p5ykfs";
      ghc8101 = "1izj3vam33klrhfzrxxvf1xlqnf29dp4gn8xncsqdxnwrlq9gy8x";
    }.${compiler-nix-name};
  }).cabal-install;
  stylish-haskell = pkgs.haskell-nix.hackage-package {
    name = "stylish-haskell";
    version = "0.10.0.0";
    inherit compiler-nix-name index-state checkMaterialization;
    # Invalidate and update if you change the version or index-state
    plan-sha256 = {
      ghc883 = "0zaypywwcq8kh1q0flc6azqilvabbzbchi2i155agjsq3b7xs3k0";
      ghc884 = "019n7imqcr7xx2la6inxq1i6s37c02l3yg4hpd8a9pz2jl1dp57g";
      ghc8101 = "0xpxi3rx9widv4dqrfw7sgzz1mx29mqnbwfgq2s21qryq3pqjw4v";
    }.${compiler-nix-name};
  };
  hlint = pkgs.haskell-nix.hackage-package {
    name = "hlint";
    version = "2.2.11";
    inherit compiler-nix-name index-state checkMaterialization;
    # Invalidate and update if you change the version or index-state
    plan-sha256 = {
      ghc883 = "0mw6w1b79hww4m5r8wncgbyw03p34mmmm66rl8wglq3ynjxfxh77";
      ghc884 = "1n4415cjk74c762s8gv25651ar296000i19ajkwpyw392gl3rn4x";
      ghc8101 = "1zsrmxmbigyg4jdmcwy4x3g60qlz7z5qkafmkapf7624d1w4dc6z";
    }.${compiler-nix-name};
  };
  inherit (pkgs.haskell-nix.cabalProject {
        src = pkgs.fetchFromGitHub {
          name = "haskell-language-server";
          owner = "haskell";
          repo = "haskell-language-server";
          rev = "15f870f89a18ca3e7991193f8c996ac6b4e17b26";
          sha256 = "14r6s1yw4h8b6jc4v04zk7hinpw23vn8jfk6sbbq7798nw891k7g";
          fetchSubmodules = true;
        };
        # Needed for GHC 8.10
        cabalProjectLocal = ''
          allow-newer: diagrams-svg:base, monoid-extras:base, svg-builder:base,
            diagrams-lib:base, dual-tree:base, active:base, diagrams-core:base,
            diagrams-contrib:base, force-layout:base, diagrams-postscript:base,
            statestack:base
        '';
        sha256map = {
          "https://github.com/bubba/brittany.git"."c59655f10d5ad295c2481537fc8abf0a297d9d1c" = "1rkk09f8750qykrmkqfqbh44dbx1p8aq1caznxxlw8zqfvx39cxl";
        };
        inherit compiler-nix-name index-state checkMaterialization;
        # Invalidate and update if you change the version
        plan-sha256 = (if pkgs.hostPlatform.isLinux
          then {
            ghc883 = "0jq1a2iyn394s3d2xag45d8ga32gn1i5bn5i63xd1jqllb85pcw3";
          }
          else {
            ghc883 = "0l812savqj4xch9afky93zfkn5wvq6mz3q09v6mxkhcpnp6gshic";
            ghc884 = "17kwki0apll74rqprzh5silbrbs9f6bq5g7c6jszxfcl5vv49cqb";
            ghc8101 = "181551n2f0syvxwjclj3jxg219rrswgy2519q04fk8ll509d98pb";
          }).${compiler-nix-name};
        modules = [{
          # Tests don't pass for some reason, but this is a somewhat random revision.
          packages.haskell-language-server.doCheck = false;
          packages.hie-bios.src = sources.hie-bios;
        }];
      })
  hie-bios haskell-language-server ghcide;
  purty =
    let hspkgs = pkgs.haskell-nix.stackProject {
        src = pkgs.fetchFromGitLab {
          owner = "joneshf";
          repo = "purty";
          rev = "3c073e1149ecdddd01f1d371c70d5b243d743bf2";
          sha256 = "0j8z9661anisp4griiv5dfpxarfyhcfb15yrd2k0mcbhs5nzhni0";
        };
        # Invalidate and update if you change the version
        stack-sha256 = "1r1fyzbl69jir30m0vqkyyf82q2548kdql4m05lss7fdsbdv4bw1";
        inherit checkMaterialization;

        # Force using 8.6.5 to work around https://github.com/input-output-hk/haskell.nix/issues/811
        ghc = pkgs.buildPackages.haskell-nix.compiler.ghc865;
        modules = [{ compiler.nix-name = pkgs.lib.mkForce "ghc865"; }];

        pkg-def-extras = [
          # Workaround for https://github.com/input-output-hk/haskell.nix/issues/214
          (hackage: {
            packages = {
              "hsc2hs" = (((hackage.hsc2hs)."0.68.6").revisions).default;
            };
          })
        ];
      };
    in hspkgs.purty;
}
