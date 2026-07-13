module riscv_core (
    input logic clk,
    input logic rst_n,
    output logic [31:0] pc_out
);

    logic [31:0] pc_next;
    logic [31:0] pc_current;
    logic [31:0] instr;
    
    logic reg_write;
    logic alu_src;
    logic [3:0]  alu_control;
    logic mem_to_reg; 
    logic mem_read;
    logic mem_write;
    logic branch;
    logic jump;
    logic jalr;
    logic lui;
    logic auipc;

    logic [31:0] rf_read_data1;
    logic [31:0] rf_read_data2;
    logic [31:0] rf_write_data;

    logic [31:0] imm_ext;

    logic [31:0] alu_operand_a;
    logic [31:0] alu_operand_b;
    logic [31:0] alu_result;
    logic alu_zero;
    logic alu_negative;
    logic alu_overflow;

    logic [31:0] mem_read_data;
    logic [31:0] pc_plus_4;

    logic branch_taken;
    always_comb begin
        branch_taken = 1'b0; 
        if (branch) begin
            case (instr[14:12]) 
                3'b000:  branch_taken = alu_zero;
                3'b001:  branch_taken = ~alu_zero;
                3'b100: branch_taken = (alu_negative != alu_overflow); // BLT
                3'b101: branch_taken = (alu_negative == alu_overflow); // BGE
                default: branch_taken = 1'b0;
            endcase
        end
    end

    assign pc_plus_4 = pc_current + 32'd4;
    // JALR's target comes from the ALU (rs1 + imm), LSB forced to 0 per spec.
    // JAL and taken branches target pc_current + imm_ext directly.
    assign pc_next = jalr ? ({alu_result[31:1], 1'b0}) :
                      (jump || branch_taken) ? (pc_current + imm_ext) :
                                                pc_plus_4;

    pc u_pc (
        .clk     (clk),
        .rst_n   (rst_n),
        .pc_next (pc_next),
        .pc_out  (pc_current)
    );

    instruction_mem u_instruction_mem (
        .addr        (pc_current),
        .instruction (instr)
    );

    control_unit u_control_unit (
        .opcode      (instr[6:0]),
        .funct3      (instr[14:12]),
        .funct7      (instr[31:25]),
        .reg_write   (reg_write),
        .alu_src     (alu_src),
        .alu_control (alu_control),
        .mem_to_reg  (mem_to_reg),
        .mem_read    (mem_read),
        .mem_write   (mem_write),
        .branch      (branch),
        .jump        (jump),
        .jalr        (jalr),
        .lui         (lui),
        .auipc       (auipc)
    );

    reg_file u_reg_file (
        .clk        (clk),
        .rst_n      (rst_n),
        .reg_write  (reg_write),
        .rs1        (instr[19:15]),
        .rs2        (instr[24:20]),
        .rd         (instr[11:7]),
        .write_data (rf_write_data),
        .read_data1 (rf_read_data1),
        .read_data2 (rf_read_data2)
    );

    imm_gen u_imm_gen (
        .instruction (instr),
        .imm_ext     (imm_ext)
    );

    // AUIPC needs pc_current as operand A; every other instruction uses rs1.
    // (For AUIPC, instr[19:15] is part of the immediate, not a real rs1 --
    // the register file still reads that index, but the result is unused since
    // this mux overrides it, so it's harmless.)
    assign alu_operand_a = auipc ? pc_current : rf_read_data1;
    assign alu_operand_b = (alu_src) ? imm_ext : rf_read_data2;

    alu u_alu (
        .a           (alu_operand_a),
        .b           (alu_operand_b),
        .alu_control (alu_control),
        .alu_result  (alu_result),
        .zero        (alu_zero),
        .negative    (alu_negative),
        .overflow    (alu_overflow)
    );

    data_mem u_data_mem (
        .clk        (clk),
        .mem_read   (mem_read),
        .mem_write  (mem_write),     
        .addr       (alu_result),
        .write_data (rf_read_data2), 
        .read_data  (mem_read_data)  
    );

    // Write-Back Mux: lui takes imm_ext directly, jump (jal/jalr) takes pc+4,
    // loads take memory data, everything else takes the ALU result.
    assign rf_write_data = lui        ? imm_ext      :
                            jump       ? pc_plus_4    :
                            mem_to_reg ? mem_read_data :
                                         alu_result;

    assign pc_out = pc_current;

endmodule
