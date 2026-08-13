// branch_predictor.sv
// Direct-mapped predictor, indexed by pc[IDX_BITS+1:2] (word-aligned, so
// bits [1:0] are always 0 and skipped). Each entry now also stores a TAG --
// the remaining upper PC bits -- checked on every lookup.
//
// Why the tag matters: with only IDX_BITS index bits, any two instruction
// addresses whose low IDX_BITS+2 bits match will fall into the same entry.
// Without a tag, a trained "taken, target=X" entry from one address would
// get served to a completely unrelated instruction that happens to alias
// the same index -- silently redirecting fetch to a wrong address. This is
// more than a misprediction cost (which the EX-stage flush recovers from
// for free): it can redirect execution off an instruction that isn't a
// branch at all, since predict_taken steers fetch in IF regardless of what
// the current instruction actually is. And because misprediction recovery
// only fires for actual branch/jump instructions (is_control_flow_ex gates
// it), an aliased false-positive on a plain ALU instruction has no flush to
// correct it -- the wrong-path fetch becomes real, unflushed execution.
//
// The tag check closes that: a lookup only predicts taken if both the
// entry is valid and its stored tag matches the current PC's tag. A false
// index hit against a different address now just predicts not-taken
// (falls through to pc+4, the always-safe default) instead of predicting
// a wrong target.
//
// What this does not fix, by design: the BHT (2-bit counter) direction
// array is still shared across aliasing addresses with no tag check of its
// own. Two aliasing branches can still corrupt each other's saturating
// counter, causing extra mispredictions (a performance cost, recovered via
// the normal EX-stage flush like any other misprediction). This is
// standard, expected behavior in real branch predictors -- the tag check
// specifically prevents aliasing from ever producing a wrong target
// address, which is the actual correctness hazard.
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

    localparam TAG_BITS = 32 - IDX_BITS - 2;

    logic [1:0]           bht [ENTRIES-1:0];
    logic [31:0]          btb [ENTRIES-1:0];
    logic                 btb_valid [ENTRIES-1:0];
    logic [TAG_BITS-1:0]  btb_tag [ENTRIES-1:0];

    wire [IDX_BITS-1:0] if_idx  = if_pc[IDX_BITS+1:2];
    wire [TAG_BITS-1:0] if_tag  = if_pc[31:IDX_BITS+2];

    wire [IDX_BITS-1:0] train_idx = train_pc[IDX_BITS+1:2];
    wire [TAG_BITS-1:0] train_tag = train_pc[31:IDX_BITS+2];

    // Predict taken only on a genuine tag match -- an index-only hit
    // against a different address's entry now safely predicts not-taken
    // instead of handing back a stale, unrelated target.
    assign predict_taken  = btb_valid[if_idx] && (btb_tag[if_idx] == if_tag) && bht[if_idx][1];
    assign predict_target = btb[if_idx];

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                bht[i]       <= 2'b01;  // weakly not-taken
                btb_valid[i] <= 1'b0;
                btb[i]       <= 32'd0;
                btb_tag[i]   <= '0;
            end
        end else if (train_valid) begin
            if (train_taken) begin
                if (bht[train_idx] != 2'b11) bht[train_idx] <= bht[train_idx] + 2'b01;
                // Tag written alongside the target on every taken train --
                // this is also how a stale aliased entry gets legitimately
                // evicted/reclaimed: the next real taken branch at this
                // index simply overwrites both target and tag together.
                btb[train_idx]       <= train_target;
                btb_valid[train_idx] <= 1'b1;
                btb_tag[train_idx]   <= train_tag;
            end else begin
                if (bht[train_idx] != 2'b00) bht[train_idx] <= bht[train_idx] - 2'b01;
            end
        end
    end
endmodule