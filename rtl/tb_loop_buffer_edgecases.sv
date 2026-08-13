`timescale 1ns/1ps

module tb_loop_buffer_edgecases();

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
        $monitor("Time: %0t | PC: %d | Instr: %h | loop_state: %0d | write_ptr: %0d | flush: %b",
            $time, pc_out, dut.instr_if, dut.u_loop_buffer.state_q, dut.u_loop_buffer.write_ptr_q,
            dut.flush);
    end

    initial begin
        #6000;
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

    task clear_imem();
        begin
            for (int j = 0; j < 1024; j++) dut.u_instruction_mem.mem[j] = 32'h00000013;
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

    task check_ge(input [7:0] actual, input [7:0] minimum, input string label);
        begin
            if (actual < minimum)
                $display("FAIL: %s = %0d, expected >= %0d", label, actual, minimum);
            else
                $display("PASS: %s = %0d (>= %0d)", label, actual, minimum);
        end
    endtask

    // Sticky trackers, manually cleared between phases.
    logic       saw_flush_during_recording;
    logic [7:0] max_write_ptr_seen;

    always @(posedge clk) begin
        if (dut.flush && dut.u_loop_buffer.state_q == 2'd1)   // 1 == STATE_RECORDING
            saw_flush_during_recording <= 1'b1;
        if (dut.u_loop_buffer.write_ptr_q > max_write_ptr_seen)
            max_write_ptr_seen <= dut.u_loop_buffer.write_ptr_q;
    end

    initial begin
        $display("\n=== PHASE 1: oversized loop body (overflow -> INVALID) ===");
        clear_imem();
        saw_flush_during_recording = 1'b0;
        max_write_ptr_seen = 8'd0;

        // i = 0; limit = 3; while (i != limit) { <17 NOPs>; i++; }
        // Loop body (addr 8 .. addr 80 inclusive) is 19 instructions --
        // bigger than BUFFER_DEPTH (16) -- so RECORDING must hit the
        // overflow guard and abort via STATE_INVALID before ever reaching
        // the branch, on every attempt. The loop must still run correctly
        // to completion regardless -- an oversized loop should just never
        // get cached, not break functionally.
        dut.u_instruction_mem.mem[0]  = 32'h00000093; // addi x1, x0, 0
        dut.u_instruction_mem.mem[1]  = 32'h00300113; // addi x2, x0, 3
        for (int k = 2; k <= 18; k++)
            dut.u_instruction_mem.mem[k] = 32'h00000013; // addi x0,x0,0 (nop, already the default fill, but explicit)
        dut.u_instruction_mem.mem[19] = 32'h00108093; // addi x1, x1, 1
        dut.u_instruction_mem.mem[20] = 32'hfa209ce3; // bne  x1, x2, -72  (target addr 8)
        dut.u_instruction_mem.mem[21] = 32'h30900f93; // addi x31, x0, 777 (post-loop sentinel)

        reset_core();
        #2000;

        check_reg(1, 3,   "x1 (loop counter)");
        check_reg(2, 3,   "x2 (limit, unchanged)");
        check_reg(31, 777, "x31 (post-loop sentinel -- confirms clean exit despite never caching)");
        check_ge(max_write_ptr_seen, 8'd16, "max write_ptr_q reached (overflow guard hit)");

        $display("\n=== PHASE 2: flush mid-RECORDING (inner data-dependent branch) ===");
        clear_imem();
        saw_flush_during_recording = 1'b0;
        max_write_ptr_seen = 8'd0;

        // i = 0; limit = 6; while (i != limit) {
        //   i++;
        //   if (i == 3) { x9 = 88; } else { x9 = 77; x9 = 88; }
        // }
        // The inner "if (i==3)" branch is untrained and only ever resolves
        // taken on i==3 -- which lands during the outer loop's 3rd pass,
        // i.e. while the outer loop_buffer is actively RECORDING (RECORDING
        // begins partway through pass 2, capturing throughout pass 3). This
        // exercises the STATE_RECORDING: if(flush) -> STATE_INVALID path
        // specifically, as opposed to the already-tested STATE_LOOPING one.
        dut.u_instruction_mem.mem[0] = 32'h00000093; // addi x1, x0, 0
        dut.u_instruction_mem.mem[1] = 32'h00600113; // addi x2, x0, 6
        dut.u_instruction_mem.mem[2] = 32'h00300193; // addi x3, x0, 3
        dut.u_instruction_mem.mem[3] = 32'h00108093; // addi x1, x1, 1     <- LOOP (addr 12)
        dut.u_instruction_mem.mem[4] = 32'h00308463; // beq  x1, x3, 8     (inner branch, addr 16)
        dut.u_instruction_mem.mem[5] = 32'h04d00493; // addi x9, x0, 77
        dut.u_instruction_mem.mem[6] = 32'h05800493; // addi x9, x0, 88    (convergence point)
        dut.u_instruction_mem.mem[7] = 32'hfe2098e3; // bne  x1, x2, -16   (outer branch, addr 28, target addr 12)
        dut.u_instruction_mem.mem[8] = 32'h22b00c93; // addi x25, x0, 555  (post-loop sentinel)

        reset_core();
        #2000;

        check_reg(1, 6,   "x1 (loop counter)");
        check_reg(2, 6,   "x2 (limit, unchanged)");
        check_reg(25, 555, "x25 (post-loop sentinel -- confirms clean exit after the disruption)");
        check_bit(saw_flush_during_recording, 1'b1, "flush observed while state_q == STATE_RECORDING");

        $display("--- Verification Complete ---\n");
        $finish;
    end
endmodule