{
  description = "PNM paper environment: LaTeX/pandoc paper pipeline, Verilog simulation (iverilog/verilator), Go co-sim harness, C/Rust firmware toolchains, LibrePCB board design";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: builtins.listToAttrs
        (map (s: { name = s; value = f s; }) systems);
      # Common packages shared between devShell and verify
      commonPkgs = pkgs: with pkgs; [
        texlive.combined.scheme-medium
        pandoc
        poppler-utils
        iverilog
        verilator
        gcc
        python3
        python3Packages.matplotlib
        yosys
        go
        rustc
        librepcb
      ];
      # musl-libc built for the RV32IMA (soft-float) orchestrator core. The
      # nixpkgs riscv32-musl default targets rv32gc/ilp32d (double-float),
      # which cannot link the firmware daemons for the FPU-less router chip;
      # rebuild static-only with the exact RTL ISA (-march=rv32ima -mabi=ilp32).
      muslRv32ima = pkgs:
        pkgs.pkgsCross.riscv32.pkgsStatic.musl.overrideAttrs (a: {
          CFLAGS = (a.CFLAGS or []) ++ [ "-march=rv32ima" "-mabi=ilp32" ];
          configureFlags = (a.configureFlags or []) ++ [ "--disable-shared" ];
          installPhase = ''
            mkdir -p $out/lib $out/include
            cp -r lib/* $out/lib/ || true
            cp -r include/* $out/include/ || true
          '';
          outputs = [ "out" ];
        });
      # RISC-V cross toolchains for the firmware targets
      # (toolchain/{mcu,soc} and fw/os/{linux,sel4} Makefiles).
      # A plain derivation that symlinks only the bin dirs: the gcc-wrapper
      # setup hooks (which would otherwise hijack CC/CXX for the whole dev
      # shell and break host Go/cgo builds) are deliberately not merged in.
      crossToolchains = pkgs:
        pkgs.runCommand "pnm-cross-toolchains" { } ''
          mkdir -p $out/bin
          for p in ${pkgs.pkgsCross.riscv32-embedded.buildPackages.gcc} \
                   ${pkgs.pkgsCross.riscv32-embedded.buildPackages.binutils} \
                   ${pkgs.pkgsCross.riscv32.pkgsStatic.buildPackages.gcc} \
                   ${pkgs.pkgsCross.riscv32.pkgsStatic.buildPackages.binutils} \
                   ${pkgs.pkgsCross.riscv64-musl.buildPackages.gcc} \
                   ${pkgs.pkgsCross.riscv64-musl.buildPackages.binutils}; do
            ln -sf $p/bin/* $out/bin/
          done
        '';
    in
    {
      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; }; in {
          default = pkgs.mkShell {
            name = "pnm-paper-env";
            packages = commonPkgs pkgs ++ [ (crossToolchains pkgs) ];
            shellHook = ''
              # Soft-float RV32IMA musl sysroot for toolchain/soc. Kept out
              # of `packages` so its headers never leak into NIX_CFLAGS_COMPILE
              # and break host gcc/cgo builds; build scripts opt in via this var.
              export PNM_MUSL_RV32IMA=${muslRv32ima pkgs}
              echo "PNM Paper Environment"
              echo "  python3 build.py          # build submission/paper.docx + .pdf"
              echo "  go test ./internal/pnm/   # run all tests"
              echo "  cd HDL && iverilog ...    # run HDL testbenches"
              echo "  librepcb-cli open pcb/pnm_node/pnm_node.lpp             # PCB: compute node"
              echo ""
              echo "Flake commands:"
              echo "  nix build                 # full verification -> result/"
              echo "  nix develop               # enter this shell"
            '';
          };
        });

      packages = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; }; in {
          default = self.packages.${system}.verify;
          verify = pkgs.stdenv.mkDerivation {
            pname = "pnm-verify";
            version = "1.0";
            src = self;

            nativeBuildInputs = commonPkgs pkgs;

            buildPhase = ''
              export HOME=$TMPDIR
              export GOCACHE=$TMPDIR/go-cache
              export GOTOOLCHAIN=local

              # Integration tests write output files into sim/; the sandbox
              # source tree is read-only, so make it writable.
              chmod -R u+w .

              echo "=== Building paper ==="
              ( cd paper && python3 build.py )

              echo "=== reproduce.sh structural self-check ==="
              # Fast (no compilation) guard for the path/anchor invariants the
              # harness relies on; catches board-JSON-path regressions before
              # the long sim sweeps.
              ./reproduce.sh --self-check

              echo "=== Running Go co-sim tests ==="
              ( cd sim && go test ./internal/pnm/ )

              echo "=== HDL static lint ==="
              ( cd HDL && verilator --lint-only -Wno-MULTITOP -Wno-TIMESCALEMOD \
                hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v \
                rst_sync.v clk_gate.v )

              echo "=== Key testbenches ==="
              (
                cd HDL
                iverilog -g2005 -o tb_rst_sync.out rst_sync.v tb_rst_sync.v && vvp tb_rst_sync.out
                iverilog -g2005 -o tb_clk_gate.out clk_gate.v tb_clk_gate.v && vvp tb_clk_gate.out
                iverilog -g2005 -o tb_fabric.out hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_fabric.v && vvp tb_fabric.out
              )

              echo "=== PCB project validation ==="
              export QT_QPA_PLATFORM=offscreen
              # The build sandbox has no fontconfig; give librepcb a minimal
              # config so Qt can start (fontconfig only, no font loading).
              cat > "$TMPDIR/minimal-fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig/>
EOF
              export FONTCONFIG_FILE="$TMPDIR/minimal-fonts.conf"
              for prj in pcb/pnm_node/pnm_node.lpp pcb/host_bridge/host_bridge.lpp pcb/gating_asic/gating_asic.lpp pcb/interconnect_board/interconnect_board.lpp; do
                if ! librepcb-cli open-project "$prj" >/tmp/librepcb.log 2>&1 || ! grep -q SUCCESS /tmp/librepcb.log; then
                  echo "PCB project validation FAILED: $prj"
                  cat /tmp/librepcb.log
                  exit 1
                fi
              done
              echo "PCB projects validated: pnm_node, processor, gating_asic, interconnect_board"

              echo "=== Board assembly smoke test ==="
              ( python3 implementations/build_asm.py implementations/boards/node_board.json --no-sim )

              echo "=== All verification passed ==="
            '';

            installPhase = ''
              mkdir -p $out
              cp paper/submission/paper.pdf $out/ 2>/dev/null || true
              cp paper/submission/paper.docx $out/ 2>/dev/null || true
            '';
          };
        });
    };
}
