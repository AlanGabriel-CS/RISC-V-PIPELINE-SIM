// riscv_pkg.sv
// Pipeline-register types for the 5-stage core. Deliberately flat (no struct
// nested inside struct) rather than folding control signals into a separate
// ctrl_t and embedding that -- keeps this to plain packed logic vectors only,
// which is the safest subset for portability across SystemVerilog tools.
package riscv_pkg;
 
    typedef struct packed {
        logic        valid;         
        logic [31:0] pc;
        logic [31:0] pc_plus4;
        logic [31:0] instr;
        logic        pred_taken;
        logic [31:0] pred_target;
    } if_id_t;
 
    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] pc_plus4;
        logic [31:0] rs1_data;
        logic [31:0] rs2_data;
        logic [31:0] imm_ext;
        logic [4:0]  rs1_addr;
        logic [4:0]  rs2_addr;
        logic [4:0]  rd_addr;
        logic [2:0]  funct3;
        logic        pred_taken;
        logic [31:0] pred_target;
        // control
        logic        reg_write;
        logic        alu_src;
        logic [3:0]  alu_control;
        logic        mem_to_reg;
        logic        mem_read;
        logic        mem_write;
        logic        branch;
        logic        jump;
        logic        jalr;
        logic        lui;
        logic        auipc;
    } id_ex_t;
 
    typedef struct packed {
        logic        valid;
        logic [31:0] pc_plus4;
        logic [31:0] alu_result;
        logic [31:0] store_data;
        logic [31:0] imm_ext;
        logic [4:0]  rd_addr;
        logic        reg_write;
        logic        mem_to_reg;
        logic        mem_read;
        logic        mem_write;
        logic        jump;
        logic        lui;
    } ex_mem_t;
 
    typedef struct packed {
        logic        valid;
        logic [31:0] pc_plus4;
        logic [31:0] alu_result;
        logic [31:0] mem_read_data;
        logic [31:0] imm_ext;
        logic [4:0]  rd_addr;
        logic        reg_write;
        logic        mem_to_reg;
        logic        jump;
        logic        lui;
    } mem_wb_t;
 
endpackage