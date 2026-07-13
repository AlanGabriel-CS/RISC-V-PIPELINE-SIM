// hazard_unit.sv
// Load-use hazard: the ONE case forwarding can't fix, because a load's data
// isn't ready until the end of MEM, one full stage later than every other
// producer. If the instruction currently in EX (id_ex) is a load, and the
// instruction currently in ID (the freshly-decoded rs1/rs2) needs that same
// register, we have to stall for exactly one cycle -- freeze PC + IF/ID,
// and let the caller insert a bubble into ID/EX instead of letting this
// instruction proceed. One stall cycle is enough: by the time the consumer
// reaches EX (two cycles later), the load will be sitting in MEM/WB and
// ordinary forwarding picks it up from there.
module hazard_unit (
    input  logic [4:0] id_rs1,
    input  logic [4:0] id_rs2,
    input  logic       ex_mem_read,  // id_ex_r.mem_read (instruction currently in EX)
    input  logic [4:0] ex_rd,        // id_ex_r.rd_addr
    output logic       stall
);
    always_comb begin
        stall = ex_mem_read && (ex_rd != 5'd0) &&
                ((ex_rd == id_rs1) || (ex_rd == id_rs2));
    end
endmodule