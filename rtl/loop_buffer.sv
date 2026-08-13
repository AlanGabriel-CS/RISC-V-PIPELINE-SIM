module loop_buffer #(
    parameter BUFFER_DEPTH = 16,
    parameter ADDR_WIDTH   = 32
)(
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic [ADDR_WIDTH-1:0] if_pc,
    input  logic [31:0]           instruction_in,
    input  logic                  predict_taken,
    input  logic [ADDR_WIDTH-1:0] predict_target,
    input  logic                  flush,

    output logic                  loop_active,      // asserted only in STATE_LOOPING
    output logic [31:0]           instruction_out,
    output logic                  gate_icache_clk   // asserted while LOOPING -- safe to freeze the
                                                      // I-cache's fetch address (see riscv_core.sv)
);

    // This piggybacks entirely on the existing branch_predictor's BHT/BTB --
    // predict_taken only fires here once that predictor has already trained
    // "taken, backward" for this PC, so this module doesn't need its own
    // occurrence counter. It also doesn't generate its own fetch addresses:
    // the normal predictor-driven pc_next_if logic already re-walks
    // [loop_start, branch_pc] correctly on every subsequent taken pass, so
    // this module only intercepts *which instruction* gets returned for a
    // given if_pc, not *how* if_pc is generated.

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_RECORDING,
        STATE_LOOPING,
        STATE_INVALID
    } state_t;

    state_t state_q, state_d;

    logic [ADDR_WIDTH-1:0] loop_start_q, loop_start_d;
    logic [ADDR_WIDTH-1:0] loop_end_q,   loop_end_d;     // exclusive end: first PC AFTER the branch

    logic [31:0] buffer [BUFFER_DEPTH-1:0];
    logic [$clog2(BUFFER_DEPTH):0] write_ptr_q, write_ptr_d;  // extra bit for full detection

    logic is_backward_prediction;
    assign is_backward_prediction = predict_taken && (predict_target < if_pc);

    logic [$clog2(BUFFER_DEPTH)-1:0] read_idx;
    logic                            read_idx_valid;
    logic [ADDR_WIDTH-1:0]           loop_offset_pc;

    assign loop_offset_pc = if_pc - loop_start_q;
    assign read_idx = loop_offset_pc[$clog2(BUFFER_DEPTH)+1:2];  // word offset

    // Explicit range check (not just index arithmetic) so a backward exit
    // can't produce a spurious "valid" hit from unsigned wraparound, plus a
    // zero-extended comparison against write_ptr_q's full width (comparing
    // against a truncated slice would silently break for a loop that fills
    // the buffer exactly).
    assign read_idx_valid = loop_active &&
                             (if_pc >= loop_start_q) && (if_pc < loop_end_q) &&
                             ({1'b0, read_idx} < write_ptr_q);

    always_comb begin
        state_d      = state_q;
        loop_start_d = loop_start_q;
        loop_end_d   = loop_end_q;
        write_ptr_d  = write_ptr_q;

        case (state_q)
            STATE_IDLE: begin
                if (!flush && is_backward_prediction) begin
                    state_d      = STATE_RECORDING;
                    loop_start_d = predict_target;
                    loop_end_d   = if_pc + 32'd4;
                    write_ptr_d  = '0;
                end
            end

            STATE_RECORDING: begin
                if (flush) begin
                    // Fetch got redirected mid-capture -- whatever's in the
                    // buffer no longer reliably represents this loop's body.
                    // Route through INVALID rather than silently discarding
                    // in place, so the abort is explicit and the tracking
                    // registers get cleared rather than just abandoned.
                    state_d = STATE_INVALID;
                end else if (write_ptr_q >= BUFFER_DEPTH) begin
                    state_d = STATE_INVALID;   // body too big for the buffer -- give up
                end else begin
                    write_ptr_d = write_ptr_q + 1'b1;
                    if (if_pc == (loop_end_q - 32'd4)) begin
                        state_d = STATE_LOOPING;
                    end
                end
            end

            STATE_LOOPING: begin
                if (flush) begin
                    state_d = STATE_INVALID;
                end else if ((if_pc < loop_start_q) || (if_pc >= loop_end_q)) begin
                    // Loop exited (branch resolved/predicted not-taken) or
                    // fetch got redirected elsewhere. This does not stall
                    // fetch for even one cycle -- instruction_out already
                    // falls back to instruction_in combinationally the
                    // instant if_pc leaves [loop_start, loop_end) via
                    // read_idx_valid above. This state transition is
                    // bookkeeping, not a gate on fetch.
                    state_d = STATE_INVALID;
                end
            end

            STATE_INVALID: begin
                // One-cycle clear pulse: drop the stale candidate and
                // return to IDLE, ready for a fresh backward prediction to
                // start a new RECORDING attempt.
                loop_start_d = '0;
                loop_end_d   = '0;
                write_ptr_d  = '0;
                state_d      = STATE_IDLE;
            end

            default: state_d = STATE_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q      <= STATE_IDLE;
            loop_start_q <= '0;
            loop_end_q   <= '0;
            write_ptr_q  <= '0;
        end else begin
            state_q      <= state_d;
            loop_start_q <= loop_start_d;
            loop_end_q   <= loop_end_d;
            write_ptr_q  <= write_ptr_d;

            if (state_q == STATE_RECORDING && !flush) begin
                if (write_ptr_q < BUFFER_DEPTH) begin
                    buffer[write_ptr_q[$clog2(BUFFER_DEPTH)-1:0]] <= instruction_in;
                end
            end
        end
    end

    assign loop_active     = (state_q == STATE_LOOPING);
    assign gate_icache_clk = (state_q == STATE_LOOPING);

    assign instruction_out = read_idx_valid ? buffer[read_idx] : instruction_in;

endmodule