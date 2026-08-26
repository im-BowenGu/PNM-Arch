`timescale 1ns/1ps

// =============================================================================
// tb_fp32_alu — self-checking testbench for FP32 ALU
// =============================================================================
module tb_fp32_alu;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [31:0] a, b;
    reg         valid_in;
    reg  [2:0]  op;
    wire [31:0] result;
    wire        valid_out;
    wire        busy;

    always #5 clk = ~clk;

    fp32_alu dut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .valid_in(valid_in), .op(op),
        .result(result), .valid_out(valid_out), .busy(busy)
    );

    integer errors;

    task check;
        input [31:0] exp;
        input [8*32-1:0] name;
        begin
            if (result !== exp) begin
                $display("[TB] MISMATCH (%0s): op=%0d a=%h b=%h -> got %h, expected %h", name, op, a, b, result, exp);
                errors = errors + 1;
            end
        end
    endtask

    // Wait for valid_out to pulse, then read result on same cycle
    task wait_result;
        integer timeout;
        begin
            timeout = 0;
            while (!valid_out && timeout < 200) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 200) begin
                $display("[TB] TIMEOUT waiting for valid_out (op=%0d)", op);
                errors = errors + 1;
            end
        end
    endtask

    // Apply inputs one cycle before valid_in to avoid race conditions
    // Bug fix: wait for busy to deassert before issuing new operation
    task run_op;
        input [31:0] ta, tb_val;
        input [2:0]  top;
        input [8*32-1:0] nm;
        input [31:0] exp;
        begin
            a = ta; b = tb_val; op = top;
            @(posedge clk);          // let inputs settle
            // Wait for busy to deassert (division in progress)
            while (busy) @(posedge clk);
            valid_in = 1;
            @(posedge clk);          // DUT samples stable inputs
            valid_in = 0;
            wait_result;
            check(exp, nm);
        end
    endtask

    initial begin
        $dumpfile("tb_fp32_alu.vcd");
        $dumpvars(0, tb_fp32_alu);
        errors = 0;

        #25; rst_n = 1; #10;

        // ADD: 2.0 + 3.0 = 5.0
        run_op(32'h40000000, 32'h40400000, 3'd0, "2+3=5", 32'h40A00000);

        // SUB: 5.0 - 3.0 = 2.0
        run_op(32'h40A00000, 32'h40400000, 3'd1, "5-3=2", 32'h40000000);

        // MUL: 2.0 * 3.0 = 6.0
        run_op(32'h40000000, 32'h40400000, 3'd2, "2*3=6", 32'h40C00000);

        // DIV: 6.0 / 3.0 = 2.0
        run_op(32'h40C00000, 32'h40400000, 3'd3, "6/3=2", 32'h40000000);

        // DIV: 1.0 / 0.0 = Inf
        run_op(32'h3F800000, 32'h00000000, 3'd3, "1/0=Inf", 32'h7F800000);

        // DIV: 7.0 / 2.0 = 3.5
        run_op(32'h40E00000, 32'h40000000, 3'd3, "7/2=3.5", 32'h40600000);

        // DIV: 1.0 / 1.0 = 1.0
        run_op(32'h3F800000, 32'h3F800000, 3'd3, "1/1=1", 32'h3F800000);

        // DIV: 5.0 / 10.0 = 0.5
        run_op(32'h40A00000, 32'h41200000, 3'd3, "5/10=0.5", 32'h3F000000);

        // DIV: 0.0 / 5.0 = 0.0
        run_op(32'h00000000, 32'h40A00000, 3'd3, "0/5=0", 32'h00000000);

        // MIN: min(3.0, 2.0) = 2.0
        run_op(32'h40400000, 32'h40000000, 3'd4, "min(3,2)=2", 32'h40000000);

        // MAX: max(3.0, 2.0) = 3.0
        run_op(32'h40400000, 32'h40000000, 3'd5, "max(3,2)=3", 32'h40400000);

        // CMP: 3.0 > 2.0 = 1.0
        run_op(32'h40400000, 32'h40000000, 3'd7, "3>2=1", 32'h3F800000);

        // CMP: 2.0 > 3.0 = 0.0
        run_op(32'h40000000, 32'h40400000, 3'd7, "2>3=0", 32'h00000000);

        if (errors == 0)
            $display("*** FP32 ALU TEST PASSED ***");
        else
            $display("*** FP32 ALU TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #50000; $display("TIMEOUT"); $finish(1); end

endmodule
