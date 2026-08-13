`timescale 1ns/1ps

module tb_icache_gating();

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
        $monitor("Time: %0t | PC: %d | loop_state: %0d | gate: %b | icache_addr: %d",
            $time, pc_out, dut.u_loop_buffer.state_q, dut.gate_icache_clk, dut.icache_addr_mux);
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

    // Track: (1) does gate_icache_clk ever mismatch loop_active (sanity
    // check on the wiring itself), (2) did the frozen address ever actually
    // change while gated (the thing this feature exists to prevent), and
    // (3) was there at least one multi-cycle gated stretch long enough to
    // meaningfully test #2 in the first place (a single-cycle gate wouldn't
    // prove anything about "staying" frozen).
    logic       gate_matches_loop_active;
    logic       froze_correctly;
    logic [3:0] gated_run_length;
    logic [7:0] max_gated_run_seen;
    logic [31:0] prev_addr;
    logic        prev_gate;

    initial begin
        gate_matches_loop_active = 1'b1;
        froze_correctly          = 1'b1;
        gated_run_length         = 4'd0;
        max_gated_run_seen       = 8'd0;
        prev_addr                = 32'd0;
        prev_gate                = 1'b0;
    end

    always @(posedge clk) begin
        if (dut.gate_icache_clk !== dut.u_loop_buffer.loop_active)
            gate_matches_loop_active <= 1'b0;

        if (dut.gate_icache_clk && prev_gate) begin
            // Gated both this cycle and last cycle -- the frozen address
            // must be identical across this boundary.
            if (dut.icache_addr_mux !== prev_addr)
                froze_correctly <= 1'b0;
            gated_run_length <= gated_run_length + 1'b1;
        end else if (dut.gate_icache_clk) begin
            gated_run_length <= 4'd1;   // first cycle of a new gated run
        end else begin
            gated_run_length <= 4'd0;
        end

        if (gated_run_length > max_gated_run_seen)
            max_gated_run_seen <= gated_run_length;

        prev_addr <= dut.icache_addr_mux;
        prev_gate <= dut.gate_icache_clk;
    end

    initial begin
        for (int j = 0; j < 1024; j++) dut.u_instruction_mem.mem[j] = 32'h00000013;

        // Same loop as the original loop-buffer test: i=0..5, taken 4
        // times then exits. Reused here because it's already proven to
        // reach LOOPING for multiple consecutive passes -- exactly what's
        // needed to check the freeze *holds*, not just triggers once.
        dut.u_instruction_mem.mem[0] = 32'h00000093; // addi x1, x0, 0
        dut.u_instruction_mem.mem[1] = 32'h00500113; // addi x2, x0, 5
        dut.u_instruction_mem.mem[2] = 32'h00108093; // addi x1, x1, 1   <- LOOP (addr 8)
        dut.u_instruction_mem.mem[3] = 32'hfe209ee3; // bne  x1, x2, -4  (addr 12, target 8)

        $display("\n--- Starting I-cache Gating Verification ---");

        reset_core();
        #1000;

        check_reg(1, 5, "x1 (loop counter, functional correctness unaffected)");
        check_reg(2, 5, "x2 (limit, unchanged)");

        check_bit(gate_matches_loop_active, 1'b1, "gate_icache_clk tracks loop_active exactly");
        check_bit(froze_correctly, 1'b1, "icache_addr_mux never changed while gated");

        // Confirms a real multi-cycle gated stretch was actually observed --
        // otherwise the froze_correctly check above would trivially pass
        // with no real coverage behind it.
        if (max_gated_run_seen < 2)
            $display("FAIL: longest gated run = %0d cycles, expected >= 2 (freeze check needs a real multi-cycle window)",
                max_gated_run_seen);
        else
            $display("PASS: longest gated run = %0d cycles (freeze check had real coverage)", max_gated_run_seen);

        $display("--- Verification Complete ---\n");
        $finish;
    end
endmodule