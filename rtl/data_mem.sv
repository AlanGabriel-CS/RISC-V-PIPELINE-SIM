module data_mem (
    input  logic        clk,
    input  logic        mem_read,
    input  logic        mem_write,
    input  logic [31:0] addr,
    input  logic [31:0] write_data,
    output logic [31:0] read_data
);

    logic [31:0] ram [0:63];

    always_ff @(posedge clk) begin
        if (mem_write) begin
            ram[addr >> 2] <= write_data; // Word-aligned indexing
        end
    end
    assign read_data = (mem_read) ? ram[addr >> 2] : 32'h0000_0000;

endmodule