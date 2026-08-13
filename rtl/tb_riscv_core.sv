`timescale 1ns/1ps

module tb_riscv_core();

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
        $monitor("Time: %0t | PC: %d | Instr: %h | stall: %b | flush: %b | pred_taken: %b | actual_taken: %b",
            $time, pc_out, dut.instr_if, dut.stall, dut.flush, dut.predict_taken_if, dut.actual_taken_ex);
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

    task check_mem(input [31:0] addr, input [31:0] expected_val);
        begin
            #1;
            if (dut.u_data_mem.ram[addr >> 2] !== expected_val)
                $display("FAIL: Mem[0x%h] = %0d, expected %0d", addr, dut.u_data_mem.ram[addr >> 2], expected_val);
            else
                $display("PASS: Mem[0x%h] = %0d", addr, expected_val);
        end
    endtask

    initial begin
        for (int j = 0; j < 1024; j++) dut.u_instruction_mem.mem[j] = 32'h00000013;

        // --- basic forwarding chain: exercises EX/MEM forward and MEM/WB
        // forward simultaneously, then EX/MEM forward + reg_file 3-apart
        // bypass simultaneously ---
        dut.u_instruction_mem.mem[0]  = 32'h00500093; // addi x1, x0, 5
        dut.u_instruction_mem.mem[1]  = 32'h00a00113; // addi x2, x0, 10
        dut.u_instruction_mem.mem[2]  = 32'h002081b3; // add  x3, x1, x2   -> x3=15
                                                       //   x2 is 1 back  (EX/MEM forward)
                                                       //   x1 is 2 back  (MEM/WB forward)
        dut.u_instruction_mem.mem[3]  = 32'h00308233; // add  x4, x1, x3   -> x4=20
                                                       //   x3 is 1 back  (EX/MEM forward)
                                                       //   x1 is 3 back  (producer's WB lands the
                                                       //   same cycle as this instr's ID -- the
                                                       //   reg_file write-forwarding bypass case)

        // --- store/load + load-use hazard ---
        dut.u_instruction_mem.mem[4]  = 32'h00402023; // sw   x4, 0(x0)    -> mem[0]=20 (store data forwarded, 1 back)
        dut.u_instruction_mem.mem[5]  = 32'h00002403; // lw   x8, 0(x0)    -> x8=20
        dut.u_instruction_mem.mem[6]  = 32'h001404b3; // add  x9, x8, x1   -> LOAD-USE HAZARD: x8 needed
                                                       //   immediately after the load -- must stall
                                                       //   1 cycle, then forward from MEM/WB. x9=25.

        // --- branch #1: taken, mispredicted (BHT resets to weakly-not-taken) ---
        dut.u_instruction_mem.mem[7]  = 32'h03700513; // addi x10, x0, 55
        dut.u_instruction_mem.mem[8]  = 32'h03700593; // addi x11, x0, 55
        dut.u_instruction_mem.mem[9]  = 32'h00b50463; // beq  x10, x11, 8  -> TAKEN, mispredicted -> flush, jump to mem[11]
        dut.u_instruction_mem.mem[10] = 32'h06300613; // addi x12, x0, 99  (must be squashed by the flush)
        dut.u_instruction_mem.mem[11] = 32'h04200693; // addi x13, x0, 66  (branch target, must execute)

        // --- branch #2: taken, mispredicted, different PC (own BHT/BTB entry) ---
        dut.u_instruction_mem.mem[12] = 32'h01400713; // addi x14, x0, 20
        dut.u_instruction_mem.mem[13] = 32'h01e00793; // addi x15, x0, 30
        dut.u_instruction_mem.mem[14] = 32'h00f71463; // bne  x14, x15, 8  -> TAKEN, mispredicted -> flush
        dut.u_instruction_mem.mem[15] = 32'h05800813; // addi x16, x0, 88  (must be squashed)
        dut.u_instruction_mem.mem[16] = 32'h04d00893; // addi x17, x0, 77  (branch target, must execute)

        // --- branch #3: NOT taken, correctly predicted (no flush, no penalty) ---
        dut.u_instruction_mem.mem[17] = 32'h00300913; // addi x18, x0, 3
        dut.u_instruction_mem.mem[18] = 32'h00300993; // addi x19, x0, 3
        dut.u_instruction_mem.mem[19] = 32'h01391463; // bne  x18, x19, 8  -> NOT taken; predictor default
                                                       //   is weakly-not-taken -> correct prediction, no flush
        dut.u_instruction_mem.mem[20] = 32'h06f00a13; // addi x20, x0, 111 (fallthrough, must execute)

        // --- JAL: unconditional, still goes through the same misprediction
        // path (predictor has no entry for this PC yet) ---
        dut.u_instruction_mem.mem[21] = 32'h00800aef; // jal  x21, 8       -> x21 = pc+4 = 88; flush; jump to mem[23]
        dut.u_instruction_mem.mem[22] = 32'h07b00b13; // addi x22, x0, 123 (must be squashed)
        dut.u_instruction_mem.mem[23] = 32'h02c00b93; // addi x23, x0, 44  (jump target, must execute)

        // --- JALR: target computed by the ALU using a forwarded register ---
        dut.u_instruction_mem.mem[24] = 32'h06c00c13; // addi x24, x0, 108 (jalr target address)
        dut.u_instruction_mem.mem[25] = 32'h000c0ce7; // jalr x25, x24, 0  -> x25 = pc+4 = 104; jump to 108
        dut.u_instruction_mem.mem[26] = 32'h0c700d13; // addi x26, x0, 199 (must be squashed)
        dut.u_instruction_mem.mem[27] = 32'h09b00d93; // addi x27, x0, 155 (jalr target, must execute)

        // --- LUI / AUIPC ---
        dut.u_instruction_mem.mem[28] = 32'h00030e37; // lui   x28, 0x30   -> x28 = 0x30000
        dut.u_instruction_mem.mem[29] = 32'h00001e97; // auipc x29, 0x1    -> x29 = pc(116) + 0x1000 = 4212

        $display("\n--- Starting 5-Stage Pipeline Verification ---");

        reset_core();

        // Generous fixed wait: 30 instructions + pipeline fill/drain (~5) +
        // 1 load-use stall cycle + 2 mispredictions * 2-cycle penalty (~4)
        // is well under 45 cycles (~900ns). Give it a lot of headroom since,
        // unlike the single-cycle testbench, PC no longer advances at a
        // fixed rate -- stalls and flushes make cycle-accurate waiting on
        // pc_out unreliable here.
        #2500;

        check_reg(1, 5,           "x1");
        check_reg(2, 10,          "x2");
        check_reg(3, 15,          "x3");   // EX/MEM + MEM/WB forward
        check_reg(4, 20,          "x4");   // EX/MEM forward + reg_file 3-apart bypass
        check_mem(0, 20);
        check_reg(8, 20,          "x8");   // lw
        check_reg(9, 25,          "x9");   // load-use stall + MEM/WB forward

        check_reg(10, 55,         "x10");
        check_reg(11, 55,         "x11");
        check_reg(12, 0,          "x12");  // must not have executed (beq taken, squashed)
        check_reg(13, 66,         "x13");  // beq taken -> branch target executed

        check_reg(14, 20,         "x14");
        check_reg(15, 30,         "x15");
        check_reg(16, 0,          "x16");  // must not have executed (bne taken, squashed)
        check_reg(17, 77,         "x17");  // bne taken -> branch target executed

        check_reg(18, 3,          "x18");
        check_reg(19, 3,          "x19");
        check_reg(20, 111,        "x20");  // bne not taken, correctly predicted -> fallthrough executed

        check_reg(21, 88,         "x21");  // jal return addr = pc+4
        check_reg(22, 0,          "x22");  // must not have executed (jal squashed it)
        check_reg(23, 44,         "x23");  // jal target -> must execute

        check_reg(24, 108,        "x24");
        check_reg(25, 104,        "x25");  // jalr return addr = pc+4
        check_reg(26, 0,          "x26");  // must not have executed (jalr squashed it)
        check_reg(27, 155,        "x27");  // jalr target -> must execute

        check_reg(28, 32'h00030000, "x28"); // lui
        check_reg(29, 32'd4212,     "x29"); // auipc

        $display("--- Verification Complete ---\n");
        $finish;
    end
endmodule