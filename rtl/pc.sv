module pc (
    input  logic        clk,      // clock signal
    input  logic        rst_n,    // active-low reset -- drives pc_out to 0
    input  logic        pc_write, // 0 = stall: hold current value, ignore pc_next
    input  logic [31:0] pc_next,  // next address to fetch, computed externally
    output logic [31:0] pc_out    // current fetch address, to instruction memory
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_out <= 32'd0; // reset execution to address 0
        end else if (pc_write) begin
            pc_out <= pc_next; // advance to next instruction address
        end
    end

    initial begin
        if (rst_n === 1'b0) $display("Reset detected at %0t", $time);
    end

endmodule
