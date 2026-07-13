module control_unit (
    input logic [6:0] opcode,   // 7-bit opcode (instruction bit [6:0])
    input logic [2:0] funct3,   // 3-bit function field (instruction bits [14:12])
    input logic [6:0] funct7,   /// 7-bit function field (instruction bits [31:25])
    output logic reg_write,     // 1 - write to register file, 0 - nothing
    output logic alu_src,       // 0 - alu operand B is rs2, 1  - alu operand b is imm
    output logic [3:0] alu_control,   // 4-bit signal telling alu what opp to do
    output logic mem_to_reg,    // 0 - data to reg from alu,  1 - comes from data mem
    output logic mem_read,      // 1-  read from data memory, 0 - do nothing
    output logic mem_write,     // 1-write to data memory, 0 -do nothing
    output logic branch,        // 1- this is branch instr, 0 - do nothing
    output logic jump,          // 1 - write pc+4 to rd (JAL or JALR)
    output logic jalr,          // 1 - pc_next comes from ALU (rs1+imm), not pc+imm (JALR only)
    output logic lui,           // 1 - write-back comes straight from imm_ext (LUI)
    output logic auipc          // 1 - ALU operand A must be pc_current, not rs1 (AUIPC)
 );

    always_comb begin
        // default control signal vals
        reg_write   = 1'b0;
        alu_src     = 1'b0;
        mem_to_reg  = 1'b0;
        mem_read    = 1'b0;
        mem_write   = 1'b0;
        branch      = 1'b0;
        jump        = 1'b0;
        jalr        = 1'b0;
        lui         = 1'b0;
        auipc       = 1'b0;
        alu_control = 4'b0000; 

        if (opcode == 7'b1100011) $display("Branch opcode detected!");

        case (opcode)
            //r-type instruct (eg. add, sub, and, or)
            //format op x1, x2, x3 - takes two reg, does math writes back to reg
            7'b0110011: begin
                reg_write = 1'b1; // save result to reg
                alu_src = 1'b0; // operand b comes from rs2

                // look at funct3 and funct7 for math opp
                case(funct3)
                    3'b000: begin
                        if (funct7 == 7'b0100000)
                            alu_control = 4'b0001; // sub 
                        else
                            alu_control = 4'b0000; // add
                    end 
                    3'b111: alu_control = 4'b0010; // and
                    3'b110: alu_control = 4'b0011; // or
                    3'b001: alu_control = 4'b0101; // SLL
                    3'b100: alu_control = 4'b0100; // XOR
                    3'b101: alu_control = (funct7[5]) ? 4'b0111 : 4'b0110; // SRA vs SRL
                    3'b010: alu_control = 4'b1000; // SLT
                    3'b011: alu_control = 4'b1001; // SLTU
                    default: alu_control = 4'b0000;
                endcase
            end

            // i-type arithmetic instructions (eg. addi, andi, slli, srli, srai, slti, sltiu)
            // format: op, x1, x2 - takes reg and const
            7'b0010011: begin
                reg_write = 1'b1; // save result to reg
                alu_src = 1'b1; // opperand B comes from imm gen, not rs2

                case (funct3)
                    3'b000:  alu_control = 4'b0000; // addi
                    3'b111:  alu_control = 4'b0010; // andi
                    3'b110:  alu_control = 4'b0011; // ori
                    3'b100:  alu_control = 4'b0100; // xori
                    3'b001:  alu_control = 4'b0101; // slli (shamt in imm[4:0], funct7=0000000)
                    3'b101:  alu_control = (funct7[5]) ? 4'b0111 : 4'b0110; // srai vs srli
                    3'b010:  alu_control = 4'b1000; // slti
                    3'b011:  alu_control = 4'b1001; // sltiu
                    default: alu_control = 4'b0000;
                endcase
            end

            //i-type load instr (eg. lw)
            7'b0000011: begin
                reg_write = 1'b1;
                alu_src = 1'b1; // use imm to calc memory offset address
                mem_to_reg = 1'b1; // data being written to reg comes from RAM, not alu
                mem_read = 1'b1; // tell data mem to open to read gate
                alu_control = 4'b0000; //alu adds base reg + imm offset

            end

            //s-type store instr (eg sw)
            7'b0100011: begin
                alu_src = 1'b1; // use imm to calc offset add
                mem_write = 1'b1; // tell data mem to write gates
                alu_control = 4'b0000; //alu adds base reg + imm ofset
            end

            // b-type branch instructions (eg. beq, bne, blt, bge)
            7'b1100011: begin
                branch   = 1'b1; // Signal that this is a branch instruction
                alu_src  = 1'b0; // Compare two registers against each other

                // Decode specific branch condition using funct3
                case (funct3)
                    3'b000: alu_control = 4'b0001; // beq
                    3'b001: alu_control = 4'b0001; // bne
                    3'b100: alu_control = 4'b0001; // blt (A < B)
                    3'b101: alu_control = 4'b0001; // bge (A >= B)
                    default: alu_control = 4'b0001;
                endcase
            end

            //j-type jump instruction
            // format: jal x1, offset -- rd = pc+4, pc = pc + imm
            7'b1101111: begin
                jump        = 1'b1;
                reg_write   = 1'b1;
            end

            // i-type jump-and-link-register (jalr)
            // format: jalr rd, rs1, imm -- rd = pc+4, pc = (rs1 + imm) & ~1
            7'b1100111: begin
                jump        = 1'b1;
                jalr        = 1'b1;
                reg_write   = 1'b1;
                alu_src     = 1'b1;    // operand B = imm
                alu_control = 4'b0000; // ALU computes rs1 + imm
            end

            // u-type load upper immediate (lui)
            // format: lui rd, imm -- rd = imm << 12
            7'b0110111: begin
                lui         = 1'b1;
                reg_write   = 1'b1;
            end

            // u-type add upper immediate to pc (auipc)
            // format: auipc rd, imm -- rd = pc + (imm << 12)
            7'b0010111: begin
                auipc       = 1'b1;
                reg_write   = 1'b1;
                alu_src     = 1'b1;    // operand B = imm
                alu_control = 4'b0000; // ALU computes pc + imm (operand A muxed to pc externally)
            end

            default: begin
                branch      = 1'b0;
                jump        = 1'b0;
                jalr        = 1'b0;
                lui         = 1'b0;
                auipc       = 1'b0;
                alu_src     = 1'b0;
                alu_control = 4'b0000;
                reg_write   = 1'b0;
                mem_to_reg  = 1'b0;
                mem_read    = 1'b0;
                mem_write   = 1'b0;
            end
        endcase
    end
endmodule