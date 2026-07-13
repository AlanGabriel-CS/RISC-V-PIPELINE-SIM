module alu (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [3:0]  alu_control,
    output logic [31:0] alu_result,
    output logic        zero,
    output logic        negative,
    output logic        overflow
); 
    always_comb begin
        case (alu_control)
            4'b0000: alu_result = a + b;           // ADD
            4'b0001: alu_result = a - b;           // SUB
            4'b0010: alu_result = a & b;           // AND
            4'b0011: alu_result = a | b;           // OR
            4'b0100: alu_result = a ^ b;           // XOR
            4'b0101: alu_result = a << b[4:0];     // SLL
            4'b0110: alu_result = a >> b[4:0];     // SRL
            4'b0111: alu_result = $signed(a) >>> b[4:0]; // SRA
            4'b1000: alu_result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0; // SLT
            4'b1001: alu_result = (a < b) ? 32'd1 : 32'd0;                   // SLTU
            default: alu_result = 32'd0;
        endcase
    end
 
    assign zero     = (alu_result == 32'd0);
    assign negative = alu_result[31]; 
    assign overflow = (alu_control == 4'b0001) ? 
                      ((a[31] ^ b[31]) && (alu_result[31] != a[31])) : 1'b0;
 
endmodule
 