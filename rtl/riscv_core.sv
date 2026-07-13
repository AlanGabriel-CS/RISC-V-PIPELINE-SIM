module riscv_core (
    input  logic clk,
    input  logic rst_n,
    output logic [31:0] pc_out   // IF-stage PC, kept for testbench visibility
);
 
    import riscv_pkg::*;
 
    // ==================================================================
    // Cross-stage signals declared up front (Verilog has no forward decl,
    // and several of these are produced by a later stage but consumed by
    // an earlier one -- e.g. flush/stall reach back to IF, wb_write_data
    // reaches back to ID for the reg_file bypass).
    // ==================================================================
    logic        stall;          // load-use hazard (ID vs EX)
    logic        flush;          // misprediction (from EX)
    logic [31:0] flush_target;
    logic        pc_write;
    logic [31:0] wb_write_data;  // WB-stage result, also used by ID-stage bypass
 
    if_id_t  if_id_r;
    id_ex_t  id_ex_r;
    ex_mem_t ex_mem_r;
    mem_wb_t mem_wb_r;
 
    // ==================================================================
    // IF stage
    // ==================================================================
    logic [31:0] pc_if, pc_plus4_if, instr_if;
    logic        predict_taken_if;
    logic [31:0] predict_target_if;
    logic [31:0] pc_next_if;
 
    assign pc_plus4_if = pc_if + 32'd4;
    assign pc_next_if  = flush ? flush_target :
                          (predict_taken_if ? predict_target_if : pc_plus4_if);
    assign pc_write    = flush || !stall;
 
    pc u_pc (
        .clk      (clk),
        .rst_n    (rst_n),
        .pc_write (pc_write),
        .pc_next  (pc_next_if),
        .pc_out   (pc_if)
    );
 
    instruction_mem u_instruction_mem (
        .addr        (pc_if),
        .instruction (instr_if)
    );
 
    logic        bp_train_valid;
    logic        bp_actual_taken;
    logic [31:0] bp_actual_target;
 
    branch_predictor u_branch_predictor (
        .clk            (clk),
        .rst_n          (rst_n),
        .if_pc          (pc_if),
        .predict_taken  (predict_taken_if),
        .predict_target (predict_target_if),
        .train_valid    (bp_train_valid),
        .train_pc       (id_ex_r.pc),
        .train_taken    (bp_actual_taken),
        .train_target   (bp_actual_target)
    );
 
    assign pc_out = pc_if;
 
    // ------------------------------------------------------------------
    // IF/ID pipeline register
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_id_r <= '0;
        end else if (flush) begin
            if_id_r <= '0;               // squash wrong-path fetch
        end else if (stall) begin
            if_id_r <= if_id_r;          // hold (load-use stall)
        end else begin
            if_id_r.valid       <= 1'b1;
            if_id_r.pc          <= pc_if;
            if_id_r.pc_plus4    <= pc_plus4_if;
            if_id_r.instr       <= instr_if;
            if_id_r.pred_taken  <= predict_taken_if;
            if_id_r.pred_target <= predict_target_if;
        end
    end
 
    // ==================================================================
    // ID stage
    // ==================================================================
    logic [6:0] opcode_id;
    logic [2:0] funct3_id;
    logic [6:0] funct7_id;
    logic [4:0] rs1_id, rs2_id, rd_id;
 
    assign opcode_id = if_id_r.instr[6:0];
    assign funct3_id = if_id_r.instr[14:12];
    assign funct7_id = if_id_r.instr[31:25];
    assign rs1_id    = if_id_r.instr[19:15];
    assign rs2_id    = if_id_r.instr[24:20];
    assign rd_id     = if_id_r.instr[11:7];
 
    logic reg_write_id, alu_src_id, mem_to_reg_id, mem_read_id, mem_write_id;
    logic branch_id, jump_id, jalr_id, lui_id, auipc_id;
    logic [3:0] alu_control_id;
 
    control_unit u_control_unit (
        .opcode      (opcode_id),
        .funct3      (funct3_id),
        .funct7      (funct7_id),
        .reg_write   (reg_write_id),
        .alu_src     (alu_src_id),
        .alu_control (alu_control_id),
        .mem_to_reg  (mem_to_reg_id),
        .mem_read    (mem_read_id),
        .mem_write   (mem_write_id),
        .branch      (branch_id),
        .jump        (jump_id),
        .jalr        (jalr_id),
        .lui         (lui_id),
        .auipc       (auipc_id)
    );
 
    logic [31:0] imm_ext_id;
    imm_gen u_imm_gen (
        .instruction (if_id_r.instr),
        .imm_ext     (imm_ext_id)
    );
 
    logic [31:0] rs1_data_id, rs2_data_id;
 
    reg_file u_reg_file (
        .clk        (clk),
        .rst_n      (rst_n),
        .reg_write  (mem_wb_r.valid && mem_wb_r.reg_write),
        .rs1        (rs1_id),
        .rs2        (rs2_id),
        .rd         (mem_wb_r.rd_addr),
        .write_data (wb_write_data),
        .read_data1 (rs1_data_id),
        .read_data2 (rs2_data_id)
    );
 
    hazard_unit u_hazard_unit (
        .id_rs1      (rs1_id),
        .id_rs2      (rs2_id),
        .ex_mem_read (id_ex_r.mem_read),
        .ex_rd       (id_ex_r.rd_addr),
        .stall       (stall)
    );
 
    // ------------------------------------------------------------------
    // ID/EX pipeline register
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_ex_r <= '0;
        end else if (flush || stall) begin
            id_ex_r <= '0;   // bubble: wrong-path squash OR load-use stall.
                              // Note flush/stall can never both be driven by
                              // the same id_ex_r content -- stall requires
                              // id_ex_r.mem_read, flush requires id_ex_r's
                              // branch/jump, and one instruction can't be
                              // both -- so there's no priority ambiguity here.
        end else begin
            id_ex_r.valid       <= if_id_r.valid;
            id_ex_r.pc          <= if_id_r.pc;
            id_ex_r.pc_plus4    <= if_id_r.pc_plus4;
            id_ex_r.rs1_data    <= rs1_data_id;
            id_ex_r.rs2_data    <= rs2_data_id;
            id_ex_r.imm_ext     <= imm_ext_id;
            id_ex_r.rs1_addr    <= rs1_id;
            id_ex_r.rs2_addr    <= rs2_id;
            id_ex_r.rd_addr     <= rd_id;
            id_ex_r.funct3      <= funct3_id;
            id_ex_r.pred_taken  <= if_id_r.pred_taken;
            id_ex_r.pred_target <= if_id_r.pred_target;
            id_ex_r.reg_write   <= reg_write_id  && if_id_r.valid;
            id_ex_r.alu_src     <= alu_src_id;
            id_ex_r.alu_control <= alu_control_id;
            id_ex_r.mem_to_reg  <= mem_to_reg_id;
            id_ex_r.mem_read    <= mem_read_id   && if_id_r.valid;
            id_ex_r.mem_write   <= mem_write_id  && if_id_r.valid;
            id_ex_r.branch      <= branch_id     && if_id_r.valid;
            id_ex_r.jump        <= jump_id       && if_id_r.valid;
            id_ex_r.jalr        <= jalr_id;
            id_ex_r.lui         <= lui_id;
            id_ex_r.auipc       <= auipc_id;
        end
    end
 
    // ==================================================================
    // EX stage
    // ==================================================================
    logic [1:0] forward_a, forward_b;
 
    forward_unit u_forward_unit (
        .id_ex_rs1        (id_ex_r.rs1_addr),
        .id_ex_rs2        (id_ex_r.rs2_addr),
        .ex_mem_reg_write (ex_mem_r.valid && ex_mem_r.reg_write),
        .ex_mem_rd        (ex_mem_r.rd_addr),
        .mem_wb_reg_write (mem_wb_r.valid && mem_wb_r.reg_write),
        .mem_wb_rd        (mem_wb_r.rd_addr),
        .forward_a        (forward_a),
        .forward_b        (forward_b)
    );
 
    // What the instruction currently in MEM will eventually write back --
    // NOT just alu_result, since JAL/JALR (pc+4) and LUI (imm) don't come
    // from the ALU. mem_to_reg is deliberately excluded: if the EX/MEM
    // producer is a load, its data isn't ready yet at this point -- that
    // case is exactly the load-use hazard, which is handled by the stall
    // above, not by this forwarding path. (The hazard unit guarantees a
    // load's immediate successor never reaches EX while the load is still
    // only in EX, so this combination -- load in EX/MEM, real dependent in
    // EX -- can't occur.)
    logic [31:0] ex_mem_fwd_value;
    assign ex_mem_fwd_value = ex_mem_r.lui  ? ex_mem_r.imm_ext  :
                              (ex_mem_r.jump ? ex_mem_r.pc_plus4 :
                                               ex_mem_r.alu_result);
 
    logic [31:0] fwd_rs1, fwd_rs2;
    assign fwd_rs1 = (forward_a == 2'b10) ? ex_mem_fwd_value :
                      (forward_a == 2'b01) ? wb_write_data    :
                                              id_ex_r.rs1_data;
    assign fwd_rs2 = (forward_b == 2'b10) ? ex_mem_fwd_value :
                      (forward_b == 2'b01) ? wb_write_data    :
                                              id_ex_r.rs2_data;
 
    logic [31:0] alu_operand_a, alu_operand_b;
    assign alu_operand_a = id_ex_r.auipc ? id_ex_r.pc : fwd_rs1;
    assign alu_operand_b = id_ex_r.alu_src ? id_ex_r.imm_ext : fwd_rs2;
 
    logic [31:0] alu_result_ex;
    logic        alu_zero_ex, alu_negative_ex, alu_overflow_ex;
 
    alu u_alu (
        .a           (alu_operand_a),
        .b           (alu_operand_b),
        .alu_control (id_ex_r.alu_control),
        .alu_result  (alu_result_ex),
        .zero        (alu_zero_ex),
        .negative    (alu_negative_ex),
        .overflow    (alu_overflow_ex)
    );
 
    logic branch_taken_ex;
    always_comb begin
        branch_taken_ex = 1'b0;
        if (id_ex_r.branch) begin
            case (id_ex_r.funct3)
                3'b000:  branch_taken_ex = alu_zero_ex;
                3'b001:  branch_taken_ex = ~alu_zero_ex;
                3'b100:  branch_taken_ex = (alu_negative_ex != alu_overflow_ex); // BLT
                3'b101:  branch_taken_ex = (alu_negative_ex == alu_overflow_ex); // BGE
                default: branch_taken_ex = 1'b0;
            endcase
        end
    end
 
    logic        actual_taken_ex;
    logic [31:0] actual_target_ex;
    logic        is_control_flow_ex;
 
    assign actual_taken_ex    = id_ex_r.valid && (id_ex_r.jump || branch_taken_ex);
    assign actual_target_ex   = id_ex_r.jalr ? {alu_result_ex[31:1], 1'b0} :
                                               (id_ex_r.pc + id_ex_r.imm_ext);
    assign is_control_flow_ex = id_ex_r.valid && (id_ex_r.branch || id_ex_r.jump);
 
    logic mispredict_ex;
    assign mispredict_ex = is_control_flow_ex &&
                            ((actual_taken_ex != id_ex_r.pred_taken) ||
                             (actual_taken_ex && (actual_target_ex != id_ex_r.pred_target)));
 
    assign flush           = mispredict_ex;
    assign flush_target    = actual_taken_ex ? actual_target_ex : id_ex_r.pc_plus4;
    assign bp_train_valid  = is_control_flow_ex;
    assign bp_actual_taken = actual_taken_ex;
    assign bp_actual_target= actual_target_ex;
 
    // ------------------------------------------------------------------
    // EX/MEM pipeline register -- never squashed by flush: the branch/jump
    // resolving in EX this cycle is on the correct path (it's what decided
    // the flush), only the wrong-path instructions behind it (IF/ID, ID/EX)
    // need squashing.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_mem_r <= '0;
        end else begin
            ex_mem_r.valid      <= id_ex_r.valid;
            ex_mem_r.pc_plus4   <= id_ex_r.pc_plus4;
            ex_mem_r.alu_result <= alu_result_ex;
            ex_mem_r.store_data <= fwd_rs2;
            ex_mem_r.imm_ext    <= id_ex_r.imm_ext;
            ex_mem_r.rd_addr    <= id_ex_r.rd_addr;
            ex_mem_r.reg_write  <= id_ex_r.reg_write;
            ex_mem_r.mem_to_reg <= id_ex_r.mem_to_reg;
            ex_mem_r.mem_read   <= id_ex_r.mem_read;
            ex_mem_r.mem_write  <= id_ex_r.mem_write;
            ex_mem_r.jump       <= id_ex_r.jump;
            ex_mem_r.lui        <= id_ex_r.lui;
        end
    end
 
    // ==================================================================
    // MEM stage
    // ==================================================================
    logic [31:0] mem_read_data_mem;
 
    data_mem u_data_mem (
        .clk        (clk),
        .mem_read   (ex_mem_r.mem_read),
        .mem_write  (ex_mem_r.mem_write),
        .addr       (ex_mem_r.alu_result),
        .write_data (ex_mem_r.store_data),
        .read_data  (mem_read_data_mem)
    );
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_wb_r <= '0;
        end else begin
            mem_wb_r.valid         <= ex_mem_r.valid;
            mem_wb_r.pc_plus4      <= ex_mem_r.pc_plus4;
            mem_wb_r.alu_result    <= ex_mem_r.alu_result;
            mem_wb_r.mem_read_data <= mem_read_data_mem;
            mem_wb_r.imm_ext       <= ex_mem_r.imm_ext;
            mem_wb_r.rd_addr       <= ex_mem_r.rd_addr;
            mem_wb_r.reg_write     <= ex_mem_r.reg_write;
            mem_wb_r.mem_to_reg    <= ex_mem_r.mem_to_reg;
            mem_wb_r.jump          <= ex_mem_r.jump;
            mem_wb_r.lui           <= ex_mem_r.lui;
        end
    end
 
    // ==================================================================
    // WB stage
    // ==================================================================
    assign wb_write_data = mem_wb_r.lui        ? mem_wb_r.imm_ext       :
                            mem_wb_r.jump       ? mem_wb_r.pc_plus4     :
                            mem_wb_r.mem_to_reg ? mem_wb_r.mem_read_data :
                                                  mem_wb_r.alu_result;
 
endmodule