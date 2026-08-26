`include "pnm_defs.vh"

// =============================================================================
// pnm_arb — Dual-port arbiter for the PNM register block
//
// Merges two bus masters (CPU and pi_bridge) onto one PNM register slave
// port.  Round-robin priority: whichever master has not been served most
// recently wins; a single-master case is zero-overhead pass-through.
//
// Both masters present the same valid/ready handshake.  The arbiter holds
// one grant until the transaction completes (ready pulses), so neither
// master sees partial transactions.
// =============================================================================

module pnm_arb (
    input  wire        clk,
    input  wire        rst_n,

    // Master 0: CPU
    input  wire [7:0]  cpu_addr,
    input  wire [31:0] cpu_wdata,
    output reg  [31:0] cpu_rdata,
    input  wire        cpu_we,
    input  wire        cpu_valid,
    output reg         cpu_ready,

    // Master 1: pi_bridge
    input  wire [7:0]  brg_addr,
    input  wire [31:0] brg_wdata,
    output reg  [31:0] brg_rdata,
    input  wire        brg_we,
    input  wire        brg_valid,
    output reg         brg_ready,

    // Shared slave port
    output reg  [7:0]  slv_addr,
    output reg  [31:0] slv_wdata,
    input  wire [31:0] slv_rdata,
    output reg         slv_we,
    output reg         slv_valid,
    input  wire        slv_ready
);

    localparam G_CPU = 1'b0;
    localparam G_BRG = 1'b1;

    reg grant;
    reg busy;
    reg owner_is_brg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant       <= G_CPU;
            busy        <= 1'b0;
            owner_is_brg<= 1'b0;
            slv_addr    <= 8'h0;
            slv_wdata   <= 32'h0;
            slv_we      <= 1'b0;
            slv_valid   <= 1'b0;
            cpu_rdata   <= 32'h0;
            brg_rdata   <= 32'h0;
            cpu_ready   <= 1'b0;
            brg_ready   <= 1'b0;
        end else begin
            cpu_ready <= 1'b0;
            brg_ready <= 1'b0;
            slv_valid <= 1'b0;

            if (!busy) begin
                // Round-robin: whichever master has NOT been served wins ties
                if (grant == G_CPU) begin
                    if (cpu_valid && !cpu_ready) begin
                        grant <= G_CPU;
                        busy  <= 1'b1;
                        owner_is_brg <= 1'b0;
                        slv_addr  <= cpu_addr;
                        slv_wdata <= cpu_wdata;
                        slv_we    <= cpu_we;
                        slv_valid <= 1'b1;
                    end else if (brg_valid && !brg_ready) begin
                        grant <= G_BRG;
                        busy  <= 1'b1;
                        owner_is_brg <= 1'b1;
                        slv_addr  <= brg_addr;
                        slv_wdata <= brg_wdata;
                        slv_we    <= brg_we;
                        slv_valid <= 1'b1;
                    end
                end else begin
                    if (brg_valid && !brg_ready) begin
                        grant <= G_BRG;
                        busy  <= 1'b1;
                        owner_is_brg <= 1'b1;
                        slv_addr  <= brg_addr;
                        slv_wdata <= brg_wdata;
                        slv_we    <= brg_we;
                        slv_valid <= 1'b1;
                    end else if (cpu_valid && !cpu_ready) begin
                        grant <= G_CPU;
                        busy  <= 1'b1;
                        owner_is_brg <= 1'b0;
                        slv_addr  <= cpu_addr;
                        slv_wdata <= cpu_wdata;
                        slv_we    <= cpu_we;
                        slv_valid <= 1'b1;
                    end
                end
            end else begin
                // Transaction in flight: wait for slave ready
                if (slv_ready) begin
                    if (owner_is_brg) begin
                        brg_rdata <= slv_rdata;
                        brg_ready <= 1'b1;
                    end else begin
                        cpu_rdata <= slv_rdata;
                        cpu_ready <= 1'b1;
                    end
                    busy <= 1'b0;
                    // Flip grant for round-robin fairness
                    grant <= ~grant;
                end else begin
                    slv_valid <= 1'b1;  // hold
                end
            end
        end
    end

endmodule
