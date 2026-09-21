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
        go
        rustc
        librepcb
      ];
    in
    {
      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; }; in {
          default = pkgs.mkShell {
            name = "pnm-paper-env";
            packages = commonPkgs pkgs;
            shellHook = ''
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

              echo "=== Building paper ==="
              ( cd paper && python3 build.py )

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
              ( librepcb-cli open-project pcb/pnm_node/pnm_node.lpp 2>&1 | grep -q SUCCESS )
              ( librepcb-cli open-project pcb/processor/processor.lpp 2>&1 | grep -q SUCCESS )
              ( librepcb-cli open-project pcb/gating_asic/gating_asic.lpp 2>&1 | grep -q SUCCESS )
              ( librepcb-cli open-project pcb/interconnect_board/interconnect_board.lpp 2>&1 | grep -q SUCCESS )
              echo "PCB projects validated: pnm_node, processor, gating_asic, interconnect_board"

              echo "=== Board assembly smoke test ==="
              ( python3 implementations/build_asm.py implementations/boards/node_board.json --no-sim )

              echo "=== All verification passed ==="
            '';

            installPhase = ''
              mkdir -p $out
              cp submission/paper.pdf $out/ 2>/dev/null || true
              cp submission/paper.docx $out/ 2>/dev/null || true
            '';
          };
        });
    };
}
