// =============================================================================
// rv32_core — RV32IMA Multi-Cycle Processor Core
//
// Minimal RISC-V core for BMC/router integration. Targets Linux/Redox
// compatibility on nommu configurations (Flat Mode / physical addressing).
//
// Supported ISA:
//   RV32I:  LUI, AUIPC, JAL, JALR, branches, loads, stores, OP-IMM, OP
//   M:      MUL (single-cycle, lower 32 bits)
//   Zicsr:  CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI
//   System: ECALL, EBREAK, MRET
//
// Microarchitecture: 5-stage FSM (IF -> ID -> EX -> MEM -> WB)
// =============================================================================

module rv32_core #(
    parameter RESET_ADDR = 32'h0000_0000,
    parameter NMINT      = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    // Bus master
    output wire [31:0] bus_addr,
    output reg  [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    output reg         bus_we,
    output reg  [3:0]  bus_be,
    output reg         bus_valid,
    input  wire        bus_ready,
    input  wire        bus_error,

    // Interrupts
    input  wire [NMINT-1:0] irq,

    // Program counter output (combinational, for ROM addressing)
    output wire [31:0] fetch_addr
);

    // =========================================================================
    // FSM states
    // =========================================================================
    localparam S_RESET    = 3'd0;
    localparam S_FETCH    = 3'd1;
    localparam S_DECODE   = 3'd2;
    localparam S_EXECUTE  = 3'd3;
    localparam S_MEMORY   = 3'd4;
    localparam S_WRITEBACK = 3'd5;
    localparam S_CSR_MRET = 3'd6;

    reg [2:0]  state;
    reg [31:0] pc;
    reg [31:0] pc_next;
    reg        mem_addr_valid;  // set after address presented in MEMORY stage
    assign fetch_addr = pc;

    // Bus address register (combinational output)
    reg [31:0] bus_addr_r;
    assign bus_addr = bus_addr_r;

    // =========================================================================
    // Register file (32 x 32-bit, x0 hardwired to 0)
    // =========================================================================
    reg [31:0] rf [0:31];

    // =========================================================================
    // Pipeline registers
    // =========================================================================
    reg [31:0] ir;
    reg [31:0] rs1_val;
    reg [31:0] rs2_val;
    reg [31:0] imm;
    reg [31:0] alu_result;
    reg [31:0] mem_result;
    reg [4:0]  rd_addr;
    reg        rd_we;
    reg [2:0]  funct3;
    reg [6:0]  funct7;

    // =========================================================================
    // Decode fields (combinational from ir)
    // =========================================================================
    wire [6:0] opcode = ir[6:0];
    wire [4:0] rs1   = ir[19:15];
    wire [4:0] rs2   = ir[24:20];
    wire [4:0] rd    = ir[11:7];

    localparam OP_LUI    = 7'b0110111;
    localparam OP_AUIPC  = 7'b0010111;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_OP_IMM = 7'b0010011;
    localparam OP_OP     = 7'b0110011;
    localparam OP_FENCE  = 7'b0001111;
    localparam OP_SYSTEM = 7'b1110011;

    wire is_m_ext = (opcode == OP_OP) && (funct7[0]);

    // =========================================================================
    // Branch comparison
    // =========================================================================
    reg branch_taken;
    always @(*) begin
        branch_taken = 1'b0;
        case (funct3)
            3'b000: branch_taken = (rs1_val == rs2_val);
            3'b001: branch_taken = (rs1_val != rs2_val);
            3'b100: branch_taken = ($signed(rs1_val) < $signed(rs2_val));
            3'b101: branch_taken = ($signed(rs1_val) >= $signed(rs2_val));
            3'b110: branch_taken = (rs1_val < rs2_val);
            3'b111: branch_taken = (rs1_val >= rs2_val);
            default: branch_taken = 1'b0;
        endcase
    end

    // =========================================================================
    // ALU inputs (combinational mux from decode regs)
    // =========================================================================
    reg [31:0] alu_a_r, alu_b_r;
    reg [6:0]  alu_funct7_r;

    always @(*) begin
        alu_a_r = 32'h0;
        alu_b_r = 32'h0;
        alu_funct7_r = 7'h0;
        case (state)
            S_EXECUTE: begin
                case (opcode)
                    OP_OP_IMM: begin
                        alu_a_r = rs1_val;
                        alu_b_r = imm;
                        alu_funct7_r = 7'h0;
                    end
                    OP_OP: begin
                        alu_a_r = rs1_val;
                        alu_b_r = rs2_val;
                        alu_funct7_r = ir[31:25];
                    end
                    OP_LOAD, OP_STORE: begin
                        alu_a_r = rs1_val;
                        alu_b_r = imm;
                    end
                    OP_JALR: begin
                        alu_a_r = rs1_val;
                        alu_b_r = imm;
                    end
                    default: begin
                        alu_a_r = 32'h0;
                        alu_b_r = 32'h0;
                    end
                endcase
            end
            default: begin
                alu_a_r = 32'h0;
                alu_b_r = 32'h0;
            end
        endcase
    end

    // =========================================================================
    // ALU (combinational)
    // =========================================================================
    reg [31:0] alu_out;
    always @(*) begin
        alu_out = 32'h0;
        case (funct3)
            3'b000: alu_out = (alu_funct7_r[5] && opcode == OP_OP) ? (alu_a_r - alu_b_r) : (alu_a_r + alu_b_r);
            3'b001: alu_out = alu_a_r << alu_b_r[4:0];
            3'b010: alu_out = ($signed(alu_a_r) < $signed(alu_b_r)) ? 32'd1 : 32'd0;
            3'b011: alu_out = (alu_a_r < alu_b_r) ? 32'd1 : 32'd0;
            3'b100: alu_out = alu_a_r ^ alu_b_r;
            3'b101: alu_out = (alu_funct7_r[5]) ? ($signed(alu_a_r) >>> alu_b_r[4:0]) : (alu_a_r >> alu_b_r[4:0]);
            3'b110: alu_out = alu_a_r | alu_b_r;
            3'b111: alu_out = alu_a_r & alu_b_r;
        endcase
    end

    // =========================================================================
    // CSR file (Machine mode)
    // =========================================================================
    localparam CSR_MSTATUS  = 12'h300;
    localparam CSR_MISA     = 12'h301;
    localparam CSR_MIE      = 12'h304;
    localparam CSR_MTVEC    = 12'h305;
    localparam CSR_MEPC     = 12'h341;
    localparam CSR_MCAUSE   = 12'h342;
    localparam CSR_MIP      = 12'h344;
    localparam CSR_MSCRATCH = 12'h340;
    localparam CSR_MCYCLE   = 12'hB00;
    localparam CSR_MCYCLEH  = 12'hB80;
    localparam CSR_MRETINST = 12'hB02;
    localparam CSR_MRETINSTH= 12'hB82;
    localparam CSR_CYCLE    = 12'hC00;
    localparam CSR_CYCLEH   = 12'hC80;

    reg [31:0] csr_mstatus;
    reg [31:0] csr_mie;
    reg [31:0] csr_mtvec;
    reg [31:0] csr_mepc;
    reg [31:0] csr_mcause;
    reg [31:0] csr_mip;
    reg [31:0] csr_mscratch;
    reg [63:0] csr_mcycle;
    reg [63:0] csr_minstret;

    wire [31:0] csr_misa_val = (32'd1 << 8) | (32'd1 << 12);  // RV32IM
    wire [31:0] mip_ext = {28'h0, |(irq), 3'h0};

    reg [31:0] csr_rdata;
    always @(*) begin
        csr_rdata = 32'h0;
        case (ir[31:20])
            CSR_MSTATUS:  csr_rdata = csr_mstatus;
            CSR_MISA:     csr_rdata = csr_misa_val;
            CSR_MIE:      csr_rdata = csr_mie;
            CSR_MTVEC:    csr_rdata = csr_mtvec;
            CSR_MEPC:     csr_rdata = csr_mepc;
            CSR_MCAUSE:   csr_rdata = csr_mcause;
            CSR_MIP:      csr_rdata = csr_mip | mip_ext;
            CSR_MSCRATCH: csr_rdata = csr_mscratch;
            CSR_MCYCLE, CSR_CYCLE: csr_rdata = csr_mcycle[31:0];
            CSR_MCYCLEH, CSR_CYCLEH: csr_rdata = csr_mcycle[63:32];
            CSR_MRETINST: csr_rdata = csr_minstret[31:0];
            CSR_MRETINSTH: csr_rdata = csr_minstret[63:32];
            default: csr_rdata = 32'h0;
        endcase
    end

    wire [4:0] zimm = rs1;
    reg [31:0] csr_wval;
    always @(*) begin
        case (ir[14:12])
            3'b001: csr_wval = rs1_val;
            3'b010: csr_wval = csr_rdata | rs1_val;
            3'b011: csr_wval = csr_rdata & ~rs1_val;
            3'b101: csr_wval = {27'h0, zimm};
            3'b110: csr_wval = csr_rdata | {27'h0, zimm};
            3'b111: csr_wval = csr_rdata & ~{27'h0, zimm};
            default: csr_wval = 32'h0;
        endcase
    end

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_RESET;
            pc           <= RESET_ADDR;
            bus_addr_r   <= 32'h0;
            bus_wdata    <= 32'h0;
            bus_we       <= 1'b0;
            bus_be       <= 4'h0;
            bus_valid    <= 1'b0;
            ir           <= 32'h0;
            rs1_val      <= 32'h0;
            rs2_val      <= 32'h0;
            imm          <= 32'h0;
            alu_result   <= 32'h0;
            mem_result   <= 32'h0;
            rd_addr      <= 5'h0;
            rd_we        <= 1'b0;
            funct3       <= 3'h0;
            funct7       <= 7'h0;
            pc_next      <= 32'h0;
            mem_addr_valid <= 1'b0;

            csr_mstatus  <= 32'h0000_1800;
            csr_mie      <= 32'h0;
            csr_mtvec    <= 32'h0000_1000;
            csr_mepc     <= 32'h0;
            csr_mcause   <= 32'h0;
            csr_mip      <= 32'h0;
            csr_mscratch <= 32'h0;
            csr_mcycle   <= 64'h0;
            csr_minstret <= 64'h0;
        end else begin
            csr_mcycle <= csr_mcycle + 64'd1;

            case (state)
                S_RESET: begin
                    bus_valid  <= 1'b0;
                    bus_we     <= 1'b0;
                    bus_be     <= 4'h0;
                    bus_addr_r <= RESET_ADDR;
                    pc         <= RESET_ADDR;
                    state      <= S_FETCH;
                end

                // =============================================================
                // FETCH: present PC on bus, latch instruction
                // =============================================================
                S_FETCH: begin
                    bus_addr_r <= pc;
                    bus_we     <= 1'b0;
                    bus_be     <= 4'hF;
                    bus_valid  <= 1'b1;
                    if (bus_ready) begin
                        ir        <= bus_rdata;
                        bus_valid <= 1'b0;
                        state     <= S_DECODE;
                    end
                end

                // =============================================================
                // DECODE: register read + immediate generation
                // =============================================================
                S_DECODE: begin
                    rs1_val <= (rs1 == 5'h0) ? 32'h0 : rf[rs1];
                    rs2_val <= (rs2 == 5'h0) ? 32'h0 : rf[rs2];
                    funct3  <= ir[14:12];
                    funct7  <= ir[31:25];
                    rd_addr <= rd;
                    rd_we   <= 1'b0;

                    case (opcode)
                        OP_LUI:    imm <= {ir[31:12], 12'h0};
                        OP_AUIPC:  imm <= {ir[31:12], 12'h0};
                        OP_JAL:    imm <= {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};
                        OP_JALR:   imm <= {{20{ir[31]}}, ir[31:20]};
                        OP_BRANCH: imm <= {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
                        OP_LOAD:   imm <= {{20{ir[31]}}, ir[31:20]};
                        OP_STORE:  imm <= {{19{ir[31]}}, ir[31:25], ir[11:7]};
                        OP_OP_IMM: imm <= {{20{ir[31]}}, ir[31:20]};
                        default:   imm <= 32'h0;
                    endcase

                    state <= S_EXECUTE;
                end

                // =============================================================
                // EXECUTE
                // =============================================================
                S_EXECUTE: begin
                    case (opcode)
                        OP_LUI: begin
                            alu_result <= imm;
                            rd_we <= 1'b1;
                            state <= S_WRITEBACK;
                        end

                        OP_AUIPC: begin
                            alu_result <= pc + imm;
                            rd_we <= 1'b1;
                            state <= S_WRITEBACK;
                        end

                        OP_JAL: begin
                            alu_result <= pc + 32'd4;
                            pc_next    <= pc + imm;
                            rd_we <= 1'b1;
                            state <= S_WRITEBACK;
                        end

                        OP_JALR: begin
                            alu_result <= pc + 32'd4;
                            pc_next    <= (rs1_val + imm) & ~32'h1;
                            rd_we <= 1'b1;
                            state <= S_WRITEBACK;
                        end

                        OP_BRANCH: begin
                            pc_next <= branch_taken ? (pc + imm) : (pc + 32'd4);
                            state <= S_WRITEBACK;
                        end

                        OP_LOAD: begin
                            alu_result <= rs1_val + imm;
                            mem_addr_valid <= 1'b0;
                            state <= S_MEMORY;
                        end

                        OP_STORE: begin
                            alu_result <= rs1_val + imm;
                            mem_addr_valid <= 1'b0;
                            state <= S_MEMORY;
                        end

                        OP_OP_IMM: begin
                            alu_result <= alu_out;
                            rd_we      <= 1'b1;
                            state      <= S_WRITEBACK;
                        end

                        OP_OP: begin
                            if (is_m_ext) begin
                                // MUL: single-cycle using Verilog *
                                if (funct3 == 3'b000) begin
                                    alu_result <= rs1_val * rs2_val;
                                    rd_we <= 1'b1;
                                    state <= S_WRITEBACK;
                                end else begin
                                    // MULH/DIV/REM: trap to simplify
                                    csr_mepc    <= pc;
                                    csr_mcause  <= 32'd2;  // Illegal instruction
                                    pc_next     <= csr_mtvec;
                                    state       <= S_CSR_MRET;
                                end
                            end else begin
                                alu_result <= alu_out;
                                rd_we      <= 1'b1;
                                state      <= S_WRITEBACK;
                            end
                        end

                        OP_FENCE: begin
                            state <= S_FETCH;
                            pc <= pc + 32'd4;
                            csr_minstret <= csr_minstret + 64'd1;
                        end

                        OP_SYSTEM: begin
                            csr_minstret <= csr_minstret + 64'd1;
                            case (ir[31:20])
                                12'h000: begin  // ECALL
                                    csr_mepc    <= pc;
                                    csr_mcause  <= 32'd11;
                                    pc_next     <= csr_mtvec;
                                    state       <= S_CSR_MRET;
                                end
                                12'h001: begin  // EBREAK
                                    csr_mepc    <= pc;
                                    csr_mcause  <= 32'd3;
                                    pc_next     <= csr_mtvec;
                                    state       <= S_CSR_MRET;
                                end
                                12'h302: begin  // MRET
                                    pc_next     <= csr_mepc;
                                    state       <= S_CSR_MRET;
                                end
                                default: begin
                                    // CSR instructions
                                    case (ir[14:12])
                                        3'b001, 3'b010, 3'b011,
                                        3'b101, 3'b110, 3'b111: begin
                                            case (ir[31:20])
                                                CSR_MSTATUS:  csr_mstatus  <= csr_wval;
                                                CSR_MIE:      csr_mie      <= csr_wval;
                                                CSR_MTVEC:    csr_mtvec    <= csr_wval;
                                                CSR_MEPC:     csr_mepc     <= csr_wval;
                                                CSR_MCAUSE:   csr_mcause   <= csr_wval;
                                                CSR_MSCRATCH: csr_mscratch <= csr_wval;
                                                CSR_MCYCLE:   csr_mcycle[31:0]  <= csr_wval;
                                                CSR_MCYCLEH:  csr_mcycle[63:32] <= csr_wval;
                                                default: ;
                                            endcase
                                            alu_result <= csr_rdata;
                                            rd_we <= 1'b1;
                                            state <= S_WRITEBACK;
                                        end
                                        default: begin
                                            state <= S_FETCH;
                                            pc <= pc + 32'd4;
                                        end
                                    endcase
                                end
                            endcase
                        end

                        default: begin
                            csr_mepc   <= pc;
                            csr_mcause <= 32'd2;
                            pc_next    <= csr_mtvec;
                            state      <= S_CSR_MRET;
                        end
                    endcase
                end

                // =============================================================
                // MEMORY: load/store (2-cycle: cycle 1 presents address,
                //         cycle 2+ checks bus_ready)
                // =============================================================
                S_MEMORY: begin
                    if (!mem_addr_valid) begin
                        // Cycle 1: present address
                        bus_addr_r   <= alu_result;
                        bus_wdata    <= rs2_val;
                        bus_we       <= (opcode == OP_STORE);
                        bus_be       <= 4'hF;
                        bus_valid    <= 1'b1;
                        mem_addr_valid <= 1'b1;
                    end else begin
                        // Cycle 2+: wait for ready
                        if (bus_ready) begin
                            if (opcode == OP_LOAD)
                                mem_result <= bus_rdata;
                            bus_valid      <= 1'b0;
                            bus_we         <= 1'b0;
                            mem_addr_valid <= 1'b0;
                            rd_we          <= (opcode == OP_LOAD);
                            state          <= S_WRITEBACK;
                        end
                    end
                end

                // =============================================================
                // WRITEBACK
                // =============================================================
                S_WRITEBACK: begin
                    if (rd_we && rd_addr != 5'h0) begin
                        case (opcode)
                            OP_LOAD: rf[rd_addr] <= mem_result;
                            default: rf[rd_addr] <= alu_result;
                        endcase
                    end
                    state <= S_FETCH;
                    if (opcode == OP_JAL || opcode == OP_JALR || opcode == OP_BRANCH)
                        pc <= pc_next;
                    else
                        pc <= pc + 32'd4;
                    csr_minstret <= csr_minstret + 64'd1;
                end

                // =============================================================
                // CSR_MRET: return from trap
                // =============================================================
                S_CSR_MRET: begin
                    pc    <= pc_next;
                    state <= S_FETCH;
                end

                default: state <= S_RESET;
            endcase
        end
    end

endmodule
