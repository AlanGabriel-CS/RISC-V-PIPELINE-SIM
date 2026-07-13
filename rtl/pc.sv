
module pc (
    input logic clk,            // clock signal
    input logic rst_n,          // active-low reset - forces pc to gnd when at 0
    input logic pc_write,       // 0 = stall: hold current value, ignore pc_next
    input logic [31:0] pc_next, // next address to go to - calculated outside
    output logic [31:0] pc_out  // current address at - to instruction memory
);
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_out <= 32'd0; // reset exec to address 0
        end else if (pc_write) begin
            pc_out <= pc_next; // moves to next instruction address
        end
        // else: pc_write == 0, hold current value (load-use stall)
    end
 
    initial begin
        if (rst_n === 1'b0) $display("Reset detected at %0t", $time);
    end
 
endmodule
 