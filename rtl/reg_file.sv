module reg_file (
    input  logic        clk,        // clock signal for synchronous writes
    input  logic        rst_n,      // asynchronous reset, clears all registers
    input  logic        reg_write,  // control signal, 1 = write, 0 = no-op
    input  logic [4:0]  rs1,        // source register 1 address
    input  logic [4:0]  rs2,        // source register 2 address
    input  logic [4:0]  rd,         // destination register
    input  logic [31:0] write_data, // 32-bit data written to rd
    output logic [31:0] read_data1, // 32-bit data read from rs1
    output logic [31:0] read_data2  // 32-bit data read from rs2
);

    // physical storage: 32 registers, 32 bits wide
    logic [31:0] rf [31:0];

    // Asynchronous read logic with same-cycle write-forwarding bypass.
    // Needed for the "3 instructions apart" RAW hazard: if the producer's
    // WB and this consumer's ID land in the same cycle, the producer has
    // already left the pipeline by the time EX-stage forwarding would look
    // for it -- normal forwarding can't reach back that far. But since WB
    // and this read happen in the very same cycle, handing out write_data
    // directly (instead of the not-yet-updated rf[] entry) closes the gap.
    // Register x0 always reads back 0, regardless of rf[0]'s contents.
    assign read_data1 = (rs1 == 5'd0) ? 32'd0 :
                         (reg_write && (rd == rs1)) ? write_data : rf[rs1];
    assign read_data2 = (rs2 == 5'd0) ? 32'd0 :
                         (reg_write && (rd == rs2)) ? write_data : rf[rs2];

    // synchronous write logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // clear all 32 registers to 0 on reset
            integer i;
            // 32 registers reset in parallel (unrolled by synthesis)
            for (i = 0; i < 32; i += 1) begin
                rf[i] <= 32'd0;
            end
        end else if (reg_write && (rd != 5'd0)) begin
            // write to rd when write-enable is high
            rf[rd] <= write_data;
        end
    end

endmodule
