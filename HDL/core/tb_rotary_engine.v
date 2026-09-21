`timescale 1ns/1ps

module tb_rotary_engine;

    reg clk, rst_n;
    reg [7:0] position;
    reg valid_in;
    reg [15:0] q_even_in, q_odd_in, k_even_in, k_odd_in;

    wire [15:0] q_even_out, q_odd_out, k_even_out, k_odd_out;
    wire valid_out;

    rotary_engine #(
        .LUT_DEPTH(256),
        .HIDDEN_DIM(64)
    ) uut (
        .clk(clk), .rst_n(rst_n),
        .position(position), .valid_in(valid_in),
        .q_even_in(q_even_in), .q_odd_in(q_odd_in),
        .k_even_in(k_even_in), .k_odd_in(k_odd_in),
        .q_even_out(q_even_out), .q_odd_out(q_odd_out),
        .k_even_out(k_even_out), .k_odd_out(k_odd_out),
        .valid_out(valid_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors;

    task send_and_check;
        input [7:0] pos;
        input [15:0] qe, qo, ke, ko;
        input [8*20-1:0] msg;
        begin
            @(posedge clk);
            position = pos;
            q_even_in = qe; q_odd_in = qo;
            k_even_in = ke; k_odd_in = ko;
            valid_in = 1;
            @(posedge clk);
            valid_in = 0;
            // Wait up to 8 cycles for valid_out (4-cycle pipeline)
            repeat(8) begin
                @(posedge clk);
                if (valid_out) begin
                    if (q_even_out !== qe || q_odd_out !== qo ||
                        k_even_out !== ke || k_odd_out !== ko) begin
                        $display("FAIL [%0s]: data mismatch q=(%04x,%04x) k=(%04x,%04x) expected q=(%04x,%04x) k=(%04x,%04x)",
                            msg, q_even_out, q_odd_out, k_even_out, k_odd_out, qe, qo, ke, ko);
                        errors = errors + 1;
                    end else begin
                        $display("PASS [%0s]: pos=%0d q=(%04x,%04x) k=(%04x,%04x)",
                            msg, pos, q_even_out, q_odd_out, k_even_out, k_odd_out);
                    end
                    disable send_and_check;
                end
            end
            $display("FAIL [%0s]: valid_out not asserted within 8 cycles", msg);
            errors = errors + 1;
        end
    endtask

    // Rotation check for a NON-identity LUT entry: drives qe=1.0, qo=0.5
    // (k same) and asserts the rotated even/odd outputs equal eexp/oexp.
    task check_rot;
        input [7:0] pos;
        input [15:0] eexp, oexp;
        input [8*20-1:0] msg;
        begin
            @(posedge clk);
            position = pos;
            q_even_in = 16'h3F80; q_odd_in = 16'h3F00;   // 1.0, 0.5
            k_even_in = 16'h3F80; k_odd_in = 16'h3F00;
            valid_in = 1;
            @(posedge clk);
            valid_in = 0;
            repeat(8) begin
                @(posedge clk);
                if (valid_out) begin
                    if (q_even_out !== eexp || q_odd_out !== oexp ||
                        k_even_out !== eexp || k_odd_out !== oexp) begin
                        $display("FAIL [%0s]: q=(%04x,%04x) k=(%04x,%04x) exp (%04x,%04x)",
                            msg, q_even_out, q_odd_out, k_even_out, k_odd_out, eexp, oexp);
                        errors = errors + 1;
                    end else begin
                        $display("PASS [%0s]: pos=%0d q=(%04x,%04x)", msg, pos, q_even_out, q_odd_out);
                    end
                    disable check_rot;
                end
            end
            $display("FAIL [%0s]: valid_out not asserted within 8 cycles", msg);
            errors = errors + 1;
        end
    endtask

    initial begin
        $dumpfile("tb_rotary_engine.vcd");
        $dumpvars(0, tb_rotary_engine);

        errors = 0;
        rst_n = 0;
        position = 0;
        valid_in = 0;
        q_even_in = 16'h0; q_odd_in = 16'h0;
        k_even_in = 16'h0; k_odd_in = 16'h0;

        @(posedge clk);
        @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Test 1: Position 0, identity rotation (cos=1.0, sin=0.0) -> pass-through
        $display("--- Test 1: Position 0 (identity) ---");
        send_and_check(8'd0, 16'h3F80, 16'h4000, 16'h4040, 16'h4080, "pos0");

        // Test 2: Position 5 (still identity in LUT)
        $display("--- Test 2: Position 5 ---");
        send_and_check(8'd5, 16'h4000, 16'h3F80, 16'h4080, 16'h4040, "pos5");

        // Test 3: Position 100
        $display("--- Test 3: Position 100 ---");
        send_and_check(8'd100, 16'h4120, 16'h41A0, 16'h4248, 16'h42C8, "pos100");

        // Test 4: Position 255 (max)
        $display("--- Test 4: Position 255 ---");
        send_and_check(8'd255, 16'h4300, 16'h4380, 16'h4400, 16'h4480, "pos255");

        // Test 5: Back-to-back (pipelining)
        $display("--- Test 5: Back-to-back ---");
        send_and_check(8'd0, 16'h0000, 16'h0000, 16'h0000, 16'h0000, "zero");
        send_and_check(8'd1, 16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80, "ones");

        // Test 6: Real non-identity rotation (exercises bf16_mul + bf16_addsub).
        // Poke position 200's LUT entry to cos=2.0 (0x4000), sin=2.0 (0x4000), then
        // rotate qe=1.0, qo=0.5: qe'=1.0*2 - 0.5*2 = 1.0 (0x3F80),
        // qo'=1.0*2 + 0.5*2 = 3.0 (0x4040). The CRITICAL #4 bugs (cos no-op and
        // XOR-instead-of-add/sub combine) both corrupt this result.
        $display("--- Test 6: Non-identity rotation ---");
        uut.cos_lut[200] = 16'h4000;   // 2.0
        uut.sin_lut[200] = 16'h4000;   // 2.0
        check_rot(8'd200, 16'h3F80, 16'h4040, "rot(cos=2,sin=2)");

        $display("");
        if (errors == 0)
            $display("*** ROTARY ENGINE TEST PASSED ***");
        else
            $display("*** ROTARY ENGINE TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
