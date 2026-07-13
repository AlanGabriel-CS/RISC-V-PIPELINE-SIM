module instruction_mem(
    input logic [31:0] addr,        // 32-bit address from program counter
    output logic [31:0] instruction // 32-bit machine code instruction out to the decoder 
);

    // creates physical storage: memory array of 1024 slots, each 32-bits (4 bytes)
    // gives 4kb instruction memory space
    logic [31:0] mem [1023:0];

    initial begin
    //    $readmemh("instructions.hex", mem);
    end

    //asynch read logic
    // byte-addressed, pc increments by 4
    // (0, 4, 8, 12) to array index (0, 1, 2, 3)
    // divide address by 4, dropping to bottom 2 bits
    assign instruction = mem[addr[11:2]];
    
endmodule
