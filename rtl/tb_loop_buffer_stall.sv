`timescale 1ns/1ps

// tb_loop_buffer_stall.sv
//
// Regression test for a real bug found while testing gen_program.py's
// random loop generation at larger program sizes: loop_buffer's
// STATE_RECORDING logic advanced write_ptr_q and captured
// instruction_in on every clock cycle, with no check for whether the IF
// stage actually fetched a new instruction that cycle. A load-use
// hazard inside a loop body freezes if_pc for one extra cycle (the
// pipeline's own, correct, 1-cycle stall) -- during RECORDING, that
// extra cycle got captured as if it were a new instruction, silently
// shifting every instruction recorded after it by one buffer slot. By
// the time replay (STATE_LOOPING) reached the loop's own backward
// branch, it served back whatever ended up one slot early instead --
// which, on the exit iteration, meant the branch's *decrement*
// instruction got replayed a second time instead of the branch itself,
// so the counter blew straight through zero and the loop never
// terminated.
//
// This test reproduces the minimal trigger directly: a load immediately
// followed by an instruction that consumes it, inside an otherwise
// ordinary counting loop.

module tb_loop_buffer_stall();

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

    logic saw_playback;
    initial saw_playback = 1'b0;
    always @(posedge clk) begin
        if (dut.u_loop_buffer.loop_active) saw_playback <= 1'b1;
    end

    // Sticky flag for the load-use stall actually firing at least once --
    // without this, a fix regression that makes the stall stop happening
    // at all would make this test pass for the wrong reason (never
    // actually exercising the bug it's here to catch).
    logic saw_stall;
    initial saw_stall = 1'b0;
    always @(posedge clk) begin
        if (dut.stall) saw_stall <= 1'b1;
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
                $display("FAIL: %s (x%0d) = %0d (0x%h), expected %0d (0x%h)",
                    reg_name, reg_addr, $signed(dut.u_reg_file.rf[reg_addr]), dut.u_reg_file.rf[reg_addr],
                    $signed(expected_val), expected_val);
            else
                $display("PASS: %s (x%0d) = %0d (0x%h)", reg_name, reg_addr, $signed(expected_val), expected_val);
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

    initial begin
        for (int j = 0; j < 1024; j++) dut.u_instruction_mem.mem[j] = 32'h00000013;
        for (int j = 0; j < 1024; j++) dut.u_data_mem.ram[j] = 32'h00000000;

        // i = 0; limit = 5; mem[0] = limit;
        // while (i != limit) { x5 = mem[0]; x6 = x5 + x5; i++; }
        // The lw/add pair is the load-use hazard: x5 is read the very
        // next instruction after it's loaded, forcing exactly the
        // 1-cycle stall this test exists to put inside a loop body.
        dut.u_instruction_mem.mem[0] = 32'h00000093; // addi x1, x0, 0
        dut.u_instruction_mem.mem[1] = 32'h00500113; // addi x2, x0, 5
        dut.u_instruction_mem.mem[2] = 32'h00202023; // sw   x2, 0(x0)
        dut.u_instruction_mem.mem[3] = 32'h00002283; // lw   x5, 0(x0)   <- LOOP (addr 12)
        dut.u_instruction_mem.mem[4] = 32'h00528333; // add  x6, x5, x5  <- load-use stall here
        dut.u_instruction_mem.mem[5] = 32'h00108093; // addi x1, x1, 1
        dut.u_instruction_mem.mem[6] = 32'hfe2098e3; // bne  x1, x2, -16 (addr 24, target 12)

        $display("\n--- Starting Loop Buffer Stall-During-Recording Regression ---");

        reset_core();

        #1400;

        check_reg(1, 5, "x1 (loop counter)");
        check_reg(2, 5, "x2 (limit, unchanged)");
        check_reg(5, 5, "x5 (loaded value)");
        check_reg(6, 10, "x6 (x5+x5, load-use consumer)");

        check_bit(saw_playback, 1'b1, "loop buffer reached PLAYBACK");
        check_bit(saw_stall, 1'b1, "load-use stall actually fired inside the loop body");

        $display("--- Verification Complete ---\n");
        $finish;
    end
endmodule
