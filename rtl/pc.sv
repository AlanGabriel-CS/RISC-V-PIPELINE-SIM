module pc (
    input logic clk,            // clock signal 
    input logic rst_n,          // active-low reset - forces pc to gnd when at 0
    input logic [31:0] pc_next, // next address to go to - calculated outside
    output logic [31:0] pc_out  // current address at - to instruction memory
);

    //executes exact instant clock goes 0 to 1
    // or when reset button pressed - 1 to 0

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_out <= 32'd0; // reset exec to address 0
        end else begin
            pc_out <= pc_next;       // moves to next instruction address
        end
    end

    initial begin
        if (rst_n === 1'b0) $display("Reset detected at %0t", $time);
    end

endmodule
