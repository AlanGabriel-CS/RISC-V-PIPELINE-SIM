module instruction_mem (
    input  logic        clk,
    input  logic [31:0] addr,
    output logic [31:0] instruction
);
    logic [31:0] mem [1023:0];
    initial $readmemh("instructions.hex", mem);

    logic [31:0] instruction_r;

    always_ff @(posedge clk) begin
        instruction_r <= mem[addr[11:2]];
    end

    assign instruction = instruction_r;
endmodule