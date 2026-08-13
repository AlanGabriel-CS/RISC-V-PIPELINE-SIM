`timescale 1ns/1ps

module tb_slti_sltiu();

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
        $monitor("Time: %0t | PC: %d | Instr: %h | stall: %b | flush: %b",
            $time, pc_out, dut.instr_if, dut.stall, dut.flush);
    end

    initial begin
        #2000;
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

    initial begin
        for (int j = 0; j < 1024; j++) dut.u_instruction_mem.mem[j] = 32'h00000013;

        // addi x1, x0, -1 -> x1 = 0xFFFFFFFF
        // slti x2, x1, 0  -> x1 is 1 instruction back: EX/MEM forward path.
        //   -1 < 0 (signed)          => x2 = 1
        // sltiu x3, x1, 0 -> x1 is 2 instructions back: MEM/WB forward path.
        //   0xFFFFFFFF < 0 (unsigned) => x3 = 0
        // Same operand, opposite comparison, same as the earlier single-cycle
        // test -- but now with real pipeline hazards forcing forwarding to
        // actually engage, not just a clean register-file read.
        dut.u_instruction_mem.mem[0] = 32'hfff00093; // addi x1, x0, -1
        dut.u_instruction_mem.mem[1] = 32'h0000a113; // slti  x2, x1, 0
        dut.u_instruction_mem.mem[2] = 32'h0000b193; // sltiu x3, x1, 0

        // addi x4, x0, 5
        // addi x5, x0, 5
        // slti  x6, x4, 3  -> x4 is 2 back (MEM/WB forward). 5<3 signed  = 0
        // sltiu x7, x5, 3  -> x5 is 2 back (MEM/WB forward). 5<3 unsigned = 0
        // Confirms the "not less than" branch of both comparisons also
        // survives forwarding correctly, not just the "less than" branch
        // exercised above.
        dut.u_instruction_mem.mem[3] = 32'h00500213; // addi x4, x0, 5
        dut.u_instruction_mem.mem[4] = 32'h00500293; // addi x5, x0, 5
        dut.u_instruction_mem.mem[5] = 32'h00322313; // slti  x6, x4, 3
        dut.u_instruction_mem.mem[6] = 32'h0032b393; // sltiu x7, x5, 3

        $display("\n--- Starting SLTI/SLTIU Pipeline Verification ---");

        reset_core();
        #400;

        check_reg(1, -1, "x1");
        check_reg(2, 32'd1, "x2 (slti x1,0 : -1 < 0 signed, EX/MEM forward)");
        check_reg(3, 32'd0, "x3 (sltiu x1,0 : 0xFFFFFFFF < 0 unsigned, MEM/WB forward)");
        check_reg(4, 5, "x4");
        check_reg(5, 5, "x5");
        check_reg(6, 32'd0, "x6 (slti x4,3 : 5 < 3 signed = false, MEM/WB forward)");
        check_reg(7, 32'd0, "x7 (sltiu x5,3 : 5 < 3 unsigned = false, MEM/WB forward)");

        $display("--- Verification Complete ---\n");
        $finish;
    end
endmodule
