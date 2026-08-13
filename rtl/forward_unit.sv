// forward_unit.sv
// Standard priority forwarding for the EX stage: EX/MEM (the instruction
// immediately ahead, currently in MEM) beats MEM/WB (two ahead, currently in
// WB) beats the raw value latched into ID/EX at decode time. Used for both
// ALU operands; the caller also reuses forward_b's result as the (possibly
// forwarded) store-data value for SW, since that's always rs2 regardless of
// what the ALU operand B mux picks.
module forward_unit (
    input  logic [4:0] id_ex_rs1,
    input  logic [4:0] id_ex_rs2,
    input  logic       ex_mem_reg_write,
    input  logic [4:0] ex_mem_rd,
    input  logic       mem_wb_reg_write,
    input  logic [4:0] mem_wb_rd,
    output logic [1:0] forward_a,   // 00 = ID/EX value, 10 = EX/MEM, 01 = MEM/WB
    output logic [1:0] forward_b
);
    always_comb begin
        if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1))
            forward_a = 2'b10;
        else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1))
            forward_a = 2'b01;
        else
            forward_a = 2'b00;

        if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2))
            forward_b = 2'b10;
        else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2))
            forward_b = 2'b01;
        else
            forward_b = 2'b00;
    end
endmodule
