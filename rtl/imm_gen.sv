module imm_gen(
    input logic [31:0] instruction, // full 32-bit machine code instr
    output logic [31:0] imm_ext     // sign-extend 32-bit imm output
);

    logic [6:0] opcode; 
    assign opcode = instruction [6:0];

    always @* begin
        case(opcode)
            // I-type (addi, lw, jalr, slti, sltiu, etc.)
            // bits [31:20] hold 12-bit imm val
            7'b0010011,
            7'b0000011,
            7'b1100111: begin
                imm_ext = { {20{instruction[31]}}, instruction[31:20] };
            end

            // S-type (sw)
            // imm split between [31:25] and bits [11:7]
            7'b0100011: begin
                imm_ext = { {20{instruction[31]}}, instruction[31:25], instruction[11:7] };
            end

            // B-type (beq, bne)
            // imm split across [31], [7], [30:25], and [11:8]
            // Total offset bits: 13 bits ([12:0]). Needs 19 sign bits to hit 32.
            7'b1100011: begin
                imm_ext = {{20{instruction[31]}}, instruction[7], instruction[30:25], instruction[11:8], 1'b0};
            end

            7'b1101111: begin // JAL
                imm_ext = { {12{instruction[31]}}, instruction[19:12], instruction[20], instruction[30:21], 1'b0 };
            end

            // U-type (lui, auipc)
            // imm occupies bits [31:12] directly; lower 12 bits are zero
            7'b0110111,
            7'b0010111: begin
                imm_ext = { instruction[31:12], 12'b0 };
            end
            
            default: begin
                imm_ext = 32'h0000_0000;
            end
        endcase
    end
endmodule