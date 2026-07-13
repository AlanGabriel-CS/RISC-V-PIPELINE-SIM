`timescale 1ns/1ps

module tb_riscv_core_full();

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
       $monitor("Time: %0t | PC: %d | Instr: %h | BranchTaken: %b | PC_Next: %d | ALU_Neg: %b | Overflow: %b",
         $time, pc_out, dut.instr, dut.branch_taken, dut.pc_next, dut.alu_negative, dut.alu_overflow);
    end

    initial begin
        #3000;
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
                $display("FAIL: %s (x%d) = %d (0x%h), expected %d (0x%h)",
                    reg_name, reg_addr, $signed(dut.u_reg_file.rf[reg_addr]), dut.u_reg_file.rf[reg_addr],
                    $signed(expected_val), expected_val);
            else
                $display("PASS: %s (x%d) = %d (0x%h)", reg_name, reg_addr, $signed(expected_val), expected_val);
        end
    endtask

    task check_mem(input [31:0] addr, input [31:0] expected_val);
        begin
            #1;
            if (dut.u_data_mem.ram[addr >> 2] !== expected_val)
                $display("FAIL: Mem[0x%h] = %d, expected %d", addr, dut.u_data_mem.ram[addr >> 2], expected_val);
            else
                $display("PASS: Mem[0x%h] = %d", addr, expected_val);
        end
    endtask

    initial begin
        for (int j = 0; j < 1024; j++) dut.u_instruction_mem.mem[j] = 32'h00000013;

        // --- original block: R-type / I-type / load / store / jal ---
        dut.u_instruction_mem.mem[0]  = 32'h00500093; // addi x1, x0, 5
        dut.u_instruction_mem.mem[1]  = 32'h00a00113; // addi x2, x0, 10
        dut.u_instruction_mem.mem[2]  = 32'h002081b3; // add  x3, x1, x2
        dut.u_instruction_mem.mem[3]  = 32'h40208233; // sub  x4, x1, x2
        dut.u_instruction_mem.mem[4]  = 32'h0440a023; // sw   x4, 64(x1)
        dut.u_instruction_mem.mem[5]  = 32'h0400a283; // lw   x5, 64(x1)
        dut.u_instruction_mem.mem[6]  = 32'h0080036f; // jal  x6, 8
        dut.u_instruction_mem.mem[7]  = 32'h06300393; // addi x7, x0, 99  (should be skipped)
        dut.u_instruction_mem.mem[8]  = 32'h02a00413; // addi x8, x0, 42  (jump target)

        // --- new block: I-type shift coverage (slli/srli/srai) ---
        dut.u_instruction_mem.mem[9]  = 32'h00100493; // addi x9,  x0, 1
        dut.u_instruction_mem.mem[10] = 32'h00449513; // slli x10, x9, 4     -> x10 = 16
        dut.u_instruction_mem.mem[11] = 32'hfff00593; // addi x11, x0, -1    -> x11 = 0xFFFFFFFF
        dut.u_instruction_mem.mem[12] = 32'h0045d613; // srli x12, x11, 4    -> x12 = 0x0FFFFFFF (logical)
        dut.u_instruction_mem.mem[13] = 32'h4045d693; // srai x13, x11, 4    -> x13 = 0xFFFFFFFF (arithmetic, -1)

        // --- new block: branch coverage, both taken (blt) and not-taken (bge) ---
        dut.u_instruction_mem.mem[14] = 32'hffb00713; // addi x14, x0, -5
        dut.u_instruction_mem.mem[15] = 32'h00a00793; // addi x15, x0, 10
        dut.u_instruction_mem.mem[16] = 32'h00f74463; // blt  x14, x15, 8    -> taken (-5 < 10), jumps to mem[18]
        dut.u_instruction_mem.mem[17] = 32'h06300813; // addi x16, x0, 99   (should be skipped)
        dut.u_instruction_mem.mem[18] = 32'h03700893; // addi x17, x0, 55   (branch target, must execute)

        dut.u_instruction_mem.mem[19] = 32'h00a00913; // addi x18, x0, 10
        dut.u_instruction_mem.mem[20] = 32'hffb00993; // addi x19, x0, -5
        dut.u_instruction_mem.mem[21] = 32'h0129d463; // bge  x19, x18, 8   -> NOT taken (-5 >= 10 is false), falls through
        dut.u_instruction_mem.mem[22] = 32'h04d00a13; // addi x20, x0, 77   (fallthrough target, must execute)

        // --- new block: beq/bne coverage (zero-flag path, not just neg/overflow) ---
        dut.u_instruction_mem.mem[23] = 32'h00700a93; // addi x21, x0, 7
        dut.u_instruction_mem.mem[24] = 32'h00700b13; // addi x22, x0, 7
        dut.u_instruction_mem.mem[25] = 32'h016a8463; // beq  x21, x22, 8   -> taken (7 == 7), jumps to mem[27]
        dut.u_instruction_mem.mem[26] = 32'h06300b93; // addi x23, x0, 99  (should be skipped)
        dut.u_instruction_mem.mem[27] = 32'h05800c13; // addi x24, x0, 88  (branch target, must execute)

        dut.u_instruction_mem.mem[28] = 32'h00300c93; // addi x25, x0, 3
        dut.u_instruction_mem.mem[29] = 32'h00400d13; // addi x26, x0, 4
        dut.u_instruction_mem.mem[30] = 32'h01ac9463; // bne  x25, x26, 8  -> taken (3 != 4), jumps to mem[32]
        dut.u_instruction_mem.mem[31] = 32'h06300d93; // addi x27, x0, 99  (should be skipped)
        dut.u_instruction_mem.mem[32] = 32'h04200e13; // addi x28, x0, 66  (branch target, must execute)

        dut.u_instruction_mem.mem[33] = 32'h00300e93; // addi x29, x0, 3
        dut.u_instruction_mem.mem[34] = 32'h00900f13; // addi x30, x0, 9
        dut.u_instruction_mem.mem[35] = 32'h01ee8463; // beq  x29, x30, 8  -> NOT taken (3 != 9), falls through
        dut.u_instruction_mem.mem[36] = 32'h06f00f93; // addi x31, x0, 111 (fallthrough target, must execute)

        // mem[37..39] intentionally left as NOP (default fill) -- buffer cycles so the
        // slt/sltu writes below can't race the check_reg reads of the block above.

        // --- new block: SLT/SLTU coverage, reusing x7/x16/x23/x27 (already checked ==0 above).
        // Same two operands (x11=-1, x9=1), signed vs unsigned comparison flips the result --
        // this is the point: it proves alu_control 4'b1000 vs 4'b1001 are actually different ops.
        dut.u_instruction_mem.mem[40] = 32'h0095a3b3; // slt  x7,  x11, x9   -> -1 <  1 (signed)   = 1
        dut.u_instruction_mem.mem[41] = 32'h0095b833; // sltu x16, x11, x9   -> 0xFFFFFFFF < 1 (unsigned) = 0
        dut.u_instruction_mem.mem[42] = 32'h00b4abb3; // slt  x23, x9,  x11  ->  1 < -1 (signed)   = 0
        dut.u_instruction_mem.mem[43] = 32'h00b4bdb3; // sltu x27, x9,  x11  -> 1 < 0xFFFFFFFF (unsigned) = 1

        // mem[44..46] intentionally left as NOP (default fill) -- buffer cycles, same reasoning
        // as the block above: lets the reads of x9/x10 above settle before these writes land.

        // --- new block: SLTI/SLTIU coverage. x11 is still -1 from the shift block. Immediate 0
        // makes the signed/unsigned split explicit: is -1 less than 0 (signed, yes) or is
        // 0xFFFFFFFF less than 0 (unsigned, no)?
        dut.u_instruction_mem.mem[47] = 32'h0005a493; // slti  x9,  x11, 0   -> -1 < 0 (signed)          = 1
        dut.u_instruction_mem.mem[48] = 32'h0005b513; // sltiu x10, x11, 0   -> 0xFFFFFFFF < 0 (unsigned) = 0

        // --- new block: LUI / AUIPC / JALR coverage ---
        dut.u_instruction_mem.mem[49] = 32'h123450b7; // lui   x1, 0x12345   -> x1 = 0x12345000
        dut.u_instruction_mem.mem[50] = 32'h00001117; // auipc x2, 0x1       -> x2 = pc(200) + 0x1000 = 4296
        dut.u_instruction_mem.mem[51] = 32'h0d800193; // addi  x3, x0, 216   -> x3 = jalr target address
        dut.u_instruction_mem.mem[52] = 32'h00018267; // jalr  x4, x3, 0     -> x4 = pc+4 = 212; jump to 216
        dut.u_instruction_mem.mem[53] = 32'h06f00293; // addi  x5, x0, 111   (must be SKIPPED)
        dut.u_instruction_mem.mem[54] = 32'h05800313; // addi  x6, x0, 88    (jalr target, must execute)

        $display("\n--- Starting Full Processor Verification ---");
        
        reset_core();
        
        // last real instruction is at word index 36 -> byte address 144
        wait(pc_out > 32'd144);
        #20;

        // original checks
        check_reg(1, 5,          "x1");
        check_reg(2, 10,         "x2");
        check_reg(3, 15,         "x3");
        check_reg(4, -5,         "x4");
        check_mem(69, -5);
        check_reg(5, -5,         "x5");   // lw round-trip
        check_reg(6, 28,         "x6");   // jal return address = pc+4
        check_reg(7, 0,          "x7");   // must NOT have executed
        check_reg(8, 42,         "x8");   // must have executed (jump landed correctly)

        // shift checks
        check_reg(9,  1,          "x9");
        check_reg(10, 16,         "x10");  // slli x9<<4
        check_reg(11, -1,         "x11");
        check_reg(12, 32'h0FFFFFFF, "x12"); // srli: zero-filled top nibble
        check_reg(13, -1,         "x13");  // srai: sign-filled top nibble, stays -1

        // branch checks
        check_reg(14, -5,         "x14");
        check_reg(15, 10,         "x15");
        check_reg(16, 0,          "x16");  // must NOT have executed (blt taken, skipped)
        check_reg(17, 55,         "x17");  // blt taken -> branch target executed
        check_reg(18, 10,         "x18");
        check_reg(19, -5,         "x19");
        check_reg(20, 77,         "x20");  // bge not taken -> fallthrough executed

        // beq/bne checks
        check_reg(21, 7,          "x21");
        check_reg(22, 7,          "x22");
        check_reg(23, 0,          "x23");  // must NOT have executed (beq taken, skipped)
        check_reg(24, 88,         "x24");  // beq taken -> branch target executed
        check_reg(25, 3,          "x25");
        check_reg(26, 4,          "x26");
        check_reg(27, 0,          "x27");  // must NOT have executed (bne taken, skipped)
        check_reg(28, 66,         "x28");  // bne taken -> branch target executed
        check_reg(29, 3,          "x29");
        check_reg(30, 9,          "x30");
        check_reg(31, 111,        "x31");  // beq not taken -> fallthrough executed

        $display("--- Core instruction-set checks complete, verifying SLT/SLTU ---");

        // last new instruction is at word index 43 -> byte address 172
        wait(pc_out > 32'd172);
        #20;

        check_reg(7,  32'd1, "x7  (slt  x11,x9 : -1 < 1 signed)");
        check_reg(16, 32'd0, "x16 (sltu x11,x9 : 0xFFFFFFFF < 1 unsigned)");
        check_reg(23, 32'd0, "x23 (slt  x9,x11 : 1 < -1 signed)");
        check_reg(27, 32'd1, "x27 (sltu x9,x11 : 1 < 0xFFFFFFFF unsigned)");

        $display("--- SLT/SLTU checks complete, verifying SLTI/SLTIU ---");

        // last new instruction is at word index 48 -> byte address 192
        wait(pc_out > 32'd192);
        #20;

        check_reg(9,  32'd1, "x9  (slti  x11,0 : -1 < 0 signed)");
        check_reg(10, 32'd0, "x10 (sltiu x11,0 : 0xFFFFFFFF < 0 unsigned)");

        $display("--- SLTI/SLTIU checks complete, verifying LUI/AUIPC/JALR ---");

        // last new instruction is at word index 54 -> byte address 216
        wait(pc_out > 32'd216);
        #20;

        check_reg(1, 32'h12345000, "x1 (lui x1,0x12345)");
        check_reg(2, 32'd4296,     "x2 (auipc x2,0x1 = pc(200)+0x1000)");
        check_reg(3, 32'd216,      "x3 (jalr target addr)");
        check_reg(4, 32'd212,      "x4 (jalr return addr = pc+4)");
        check_reg(5, -5,           "x5 (jalr skip -- must stay at prior lw value, NOT execute)");
        check_reg(6, 32'd88,       "x6 (jalr target -- must execute)");
        
        $display("--- Verification Complete ---\n");
        $finish;
    end
endmodule