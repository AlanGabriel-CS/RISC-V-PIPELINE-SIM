module instruction_mem (
    input  logic [31:0] addr,       // 32-bit address from program counter
    output logic [31:0] instruction // 32-bit machine code instruction out to the decoder
);

    // physical storage: 1024 32-bit (4-byte) words -- 4 KB of instruction memory
    logic [31:0] mem [1023:0];

    initial begin
    //    $readmemh("instructions.hex", mem);
    end

    // Asynchronous read logic. Byte-addressed, pc increments by 4, so
    // (0, 4, 8, 12) maps to array index (0, 1, 2, 3): divide the address by
    // 4 by dropping the bottom 2 bits.
    assign instruction = mem[addr[11:2]];

endmodule
