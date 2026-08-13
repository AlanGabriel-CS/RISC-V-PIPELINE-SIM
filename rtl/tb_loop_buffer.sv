`timescale 1ns/1ps

module tb_loop_buffer();

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

    // Sticky flag: latch true the first time playback is ever seen, since
    // check_reg-style point-in-time checks can't observe a transient
    // condition on their own.
    logic saw_playback;
    initial saw_playback = 1'b0;
    always @(posedge clk) begin
        if (dut.u_loop_buffer.loop_active) saw_playback <= 1'b1;
    end

    // Same idea for STATE_INVALID (value 3) -- the one genuinely new state
    // from the FSM rework. The loop's natural exit (branch predicted taken,
    // resolves not-taken) should route through here on its way back to
    // IDLE, so this confirms that transition is actually reachable, not
    // just present in the source.
    logic saw_invalid;
    initial saw_invalid = 1'b0;
    always @(posedge clk) begin
        if (dut.u_loop_buffer.state_q == 2'd3) saw_invalid <= 1'b1;
    end

    initial begin
        $monitor("Time: %0t | PC: %d | Instr: %h | loop_state: %0d | loop_active: %b | write_ptr: %0d",
            $time, pc_out, dut.instr_if, dut.u_loop_buffer.state_q, dut.u_loop_buffer.loop_active,
            dut.u_loop_buffer.write_ptr_q);
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

    task check_buf(input [3:0] idx, input [31:0] expected_val, input string label);
        begin
            #1;
            if (dut.u_loop_buffer.buffer[idx] !== expected_val)
                $display("FAIL: %s buffer[%0d] = 0x%h, expected 0x%h",
                    label, idx, dut.u_loop_buffer.buffer[idx], expected_val);
            else
                $display("PASS: %s buffer[%0d] = 0x%h", label, idx, expected_val);
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

        // i = 0; limit = 5; while (i != limit) i++;
        // Loop body is just the addi (addr 8); branch is addr 12, target
        // addr 8 -- backward, 2 instructions, well within the buffer.
        // Runs 5 iterations (i: 0->1->2->3->4->5), taken 4 times, then
        // not taken once on exit (i==limit). That's enough passes for:
        // pass 1 = mispredict + train, pass 2 = RECORDING, pass 3+ = should
        // be PLAYBACK, then exit cleanly back to IDLE.
        dut.u_instruction_mem.mem[0] = 32'h00000093; // addi x1, x0, 0
        dut.u_instruction_mem.mem[1] = 32'h00500113; // addi x2, x0, 5
        dut.u_instruction_mem.mem[2] = 32'h00108093; // addi x1, x1, 1   <- LOOP (addr 8)
        dut.u_instruction_mem.mem[3] = 32'hfe209ee3; // bne  x1, x2, -4  (addr 12, target 8)

        $display("\n--- Starting Loop Buffer Verification ---");

        reset_core();

        #1000;

        // Functional correctness first: if the loop buffer ever served a
        // wrong instruction, this is where it would show up.
        check_reg(1, 5, "x1 (loop counter)");
        check_reg(2, 5, "x2 (limit, unchanged)");

        // Did it actually reach PLAYBACK at some point? If read_idx_valid
        // or the state machine is broken, this stays 0 even if the
        // functional result above happens to still be right (since
        // falling back to instruction_in on every cycle is a silent,
        // harmless-looking failure mode).
        check_bit(saw_playback, 1'b1, "loop buffer reached PLAYBACK");
        check_bit(saw_invalid, 1'b1, "loop buffer reached INVALID (loop-exit path)");

        // And did it capture the *correct* bytes, not just *some* bytes?
        check_buf(0, 32'h00108093, "captured addi x1,x1,1");
        check_buf(1, 32'hfe209ee3, "captured bne x1,x2,-4");

        $display("--- Verification Complete ---\n");
        $finish;
    end
endmodule