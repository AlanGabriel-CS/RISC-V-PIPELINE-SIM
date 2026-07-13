// branch_predictor.sv
// Small direct-mapped predictor, indexed by pc[IDX_BITS+1:2] (word-aligned,
// so bits [1:0] are always 0 and skipped). No tag bits -- for a 64-entry
// table that means any two instructions whose addresses share the same
// index alias each other. That's a real limitation for a large program, but
// harmless for this testbench since it exercises well under ENTRIES
// distinct instruction words, so every PC gets a unique slot.
//
// IF-stage lookup is combinational (prediction must be ready the same cycle
// as fetch). EX-stage training is synchronous: every resolved branch/JAL/
// JALR updates its BHT counter (saturating, 2-bit) and, if actually taken,
// its BTB target. Untaken branches don't need a stored target (nothing to
// jump to), so the BTB entry is only written on train_taken.
module branch_predictor #(
    parameter ENTRIES  = 64,
    parameter IDX_BITS = 6
)(
    input  logic clk,
    input  logic rst_n,
 
    input  logic [31:0] if_pc,
    output logic        predict_taken,
    output logic [31:0] predict_target,
 
    input  logic        train_valid,
    input  logic [31:0] train_pc,
    input  logic        train_taken,
    input  logic [31:0] train_target
);
 
    logic [1:0]  bht [ENTRIES-1:0];
    logic [31:0] btb [ENTRIES-1:0];
    logic        btb_valid [ENTRIES-1:0];
 
    wire [IDX_BITS-1:0] if_idx    = if_pc[IDX_BITS+1:2];
    wire [IDX_BITS-1:0] train_idx = train_pc[IDX_BITS+1:2];
 
    assign predict_taken  = btb_valid[if_idx] && bht[if_idx][1];
    assign predict_target = btb[if_idx];
 
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                bht[i]       <= 2'b01;  // weakly not-taken
                btb_valid[i] <= 1'b0;
                btb[i]       <= 32'd0;
            end
        end else if (train_valid) begin
            if (train_taken) begin
                if (bht[train_idx] != 2'b11) bht[train_idx] <= bht[train_idx] + 2'b01;
                btb[train_idx]       <= train_target;
                btb_valid[train_idx] <= 1'b1;
            end else begin
                if (bht[train_idx] != 2'b00) bht[train_idx] <= bht[train_idx] - 2'b01;
            end
        end
    end
endmodule