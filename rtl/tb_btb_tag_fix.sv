`timescale 1ns/1ps

module tb_btb_tag_fix();

    logic clk, rst_n;
    logic [31:0] pc_out;

    riscv_core dut (
        .clk(clk),
        .rst_n(rst_n),
        .pc_out(pc_out)
    );

    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    initial begin
        $monitor("Time: %0t | PC: %d | pred_taken: %b | pred_target: %0d",
            $time, pc_out, dut.predict_taken_if, dut.predict_target_if);
    end

    initial begin
        #4000;
        $display("Simulation timed out at PC: 0x%h", pc_out);
        $finish;
    end

    task reset_core();
        begin
            rst_n = 1'b0;
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task check_reg(input [4:0] reg_addr, input [31:0] expected_val, input string reg_name);
        begin
            #1;
            if (dut.u_reg_file.rf[reg_addr] !== expected_val)
                $display("FAIL: %s (x%0d) = %0d, expected %0d", reg_name, reg_addr,
                    dut.u_reg_file.rf[reg_addr], expected_val);
            else
                $display("PASS: %s (x%0d) = %0d", reg_name, reg_addr, expected_val);
        end
    endtask

    task check_bit(input logic actual, input logic expected, input string label);
        begin
            if (actual !== expected)
                $display("FAIL: %s = %b, expected %b", label, actual, expected);
            else
                $display("PASS: %s = %b", label, expected);
        end
    endtask

    // Sticky: did IF ever predict-taken while fetching the aliasing address
    // (268)? Under the old untagged predictor this fired incorrectly,
    // because addr 268 and addr 12 (the real branch, trained taken to
    // target 8) share the same 6-bit index: (268/4) mod 64 == (12/4) mod 64
    // == 3. A false hit here would have redirected fetch from 268 back to
    // 8 -- on an instruction that isn't even a branch.
    logic bad_alias_predict;
    initial bad_alias_predict = 1'b0;
    always @(posedge clk) begin
        if (pc_out == 32'd268 && dut.predict_taken_if)
            bad_alias_predict <= 1'b1;
    end

    initial begin
        for (int j = 0; j < 1024; j++) dut.u_instruction_mem.mem[j] = 32'h00000013;

        // i = 0; limit = 3; while (i != limit) i++;
        // Real branch lives at addr 12, trained taken (target addr 8) over
        // several passes -- same loop shape already proven to train the
        // predictor in earlier tests.
        dut.u_instruction_mem.mem[0] = 32'h00000093; // addi x1, x0, 0
        dut.u_instruction_mem.mem[1] = 32'h00300113; // addi x2, x0, 3
        dut.u_instruction_mem.mem[2] = 32'h00108093; // addi x1, x1, 1    <- LOOP (addr 8)
        dut.u_instruction_mem.mem[3] = 32'hfe209ee3; // bne  x1, x2, -4   (addr 12, target 8)

        // Word index 67 = byte address 268 = 12 + 256, which aliases addr
        // 12's BTB index under the old 6-bit-index, no-tag scheme. This is
        // a plain, non-branch instruction -- if the predictor ever fires
        // predict_taken while fetching this address, that's the bug.
        dut.u_instruction_mem.mem[67] = 32'h3e700f13; // addi x30, x0, 999 (sentinel)

        $display("\n--- Starting BTB Tag-Fix Verification ---");

        reset_core();
        #2000;

        check_reg(1, 3,   "x1 (loop counter, unaffected by the fix)");
        check_reg(2, 3,   "x2 (limit, unchanged)");
        check_reg(30, 999, "x30 (sentinel at the aliasing address -- confirms fetch reached it undisturbed)");
        check_bit(bad_alias_predict, 1'b0, "predict_taken never fired on the aliasing address (268)");

        $display("--- Verification Complete ---\n");
        $finish;
    end
endmodule