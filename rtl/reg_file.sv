module reg_file(
    input logic clk,                // clock signal for synchronous writes
    input logic rst_n,              // asynch reset to clear all registers
    input logic reg_write,          // control signal = 1-write 0-nothing
    input logic [4:0] rs1,          // source register 1 address 
    input logic [4:0] rs2,          // source register 2 address 
    input logic [4:0] rd,           // destination register
    input logic [31:0] write_data,  // 32-bit data written to rd
    output logic [31:0] read_data1,  // 32-bit data written to rs1
    output logic [31:0] read_data2  // 32-bit data written to rs2
);

    //create physical storage: array of 32 registers, 32-bits wide
    logic [31:0] rf [31:0];
    
    // asynch read logic - always running regardless of clk
    // register x0 hardwired to be 0
    assign read_data1 = (rs1 == 5'd0) ? 32'd0 : rf[rs1];
    assign read_data2 = (rs2 == 5'd0) ? 32'd0 : rf[rs2];

    // synch write logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // clear 32 registers to 0 on reset
            integer i;
            //32 parralel lines - asynch reset
            for (i=0; i<32; i +=1) begin
                rf[i] <= 32'd0;
            end
        end else if (reg_write && (rd != 5'd0)) begin
            //write data to rd if write-enable is high
            rf[rd] <= write_data;
        end
    end

endmodule
