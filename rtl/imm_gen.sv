module imm_gen (
    input  logic [31:0] instruction, // full 32-bit machine code instruction
    output logic [31:0] imm_ext      // sign-extended 32-bit immediate output
);

    logic [6:0] opcode;
    assign opcode = instruction [6:0];

    always_comb begin
        case (opcode)
            // I-type (addi, lw, jalr, slti, sltiu, etc.)
            // bits [31:20] hold the 12-bit immediate value
            7'b0010011,
            7'b0000011,
            7'b1100111: begin
                imm_ext = { {20{instruction[31]}}, instruction[31:20] };
            end

            // S-type (sw)
            // immediate split between [31:25] and bits [11:7]
            7'b0100011: begin
                imm_ext = { {20{instruction[31]}}, instruction[31:25], instruction[11:7] };
            end

            // B-type (beq, bne)
            // immediate split across [31], [7], [30:25], and [11:8]
            // Total offset: 13 bits ([12:0]), requiring 19 sign-extension bits to reach 32.
            7'b1100011: begin
                imm_ext = {{20{instruction[31]}}, instruction[7], instruction[30:25], instruction[11:8], 1'b0};
            end

            7'b1101111: begin // JAL
                imm_ext = { {12{instruction[31]}}, instruction[19:12], instruction[20], instruction[30:21], 1'b0 };
            end

            // U-type (lui, auipc)
            // Immediate occupies bits [31:12] directly; lower 12 bits are zero.
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