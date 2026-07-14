// RISC-V RV32I Cycle-Accurate Simulator 
// Implements a software model of a RISC-V 32 bit integer (RV32I)
//Simulators three stages CPU performs on instructions:

//FETCH: read the next instruction word from memory
//DECODE: find out what the instruction is asking for
//EXECUTE: perform the operation 

// Simulation is not meant for performance, it's correctness and clarity
// Meant to be used to verify hardware implementation in SystemaVerilog

//Author: Alan gabriel



#include <iostream>
#include <cstdint>
#include <string>
#include <iomanip>
#include <fstream>
#include <string>

// Virtual Hardware State:
// CPU - this lives in physical flip-flops on silicon
// RISC-V integer register file: x0 is hardwire to 0, x1-x31 are general purpose
// Each register is 32 bits wide, program counter holds memory address of fetched instruction

uint32_t registers[32] = {0};
uint32_t pc = 0;
uint8_t memory[4096] = {0};


// Functions model physical interfac e between CPU and hardware like register file write port and memory bus

// Register file write port
// x0 is always 0

void write_reg(int reg_num, uint32_t value) {
    if (reg_num == 0) return; // Enforce x0 = 0
    if (reg_num < 32) registers[reg_num] = value;
}

// Memory bus read
// little-endian byte ordering: least significant byte of 32-bit word lives at lowest address
// stcihes four consecutive bytes from memory into signle 32-bit instruction word

uint32_t fetch_instruction(uint32_t address) {
    return (uint32_t)memory[address] | 
           ((uint32_t)memory[address + 1] << 8) | 
           ((uint32_t)memory[address + 2] << 16) | 
           ((uint32_t)memory[address + 3] << 24);
}

// Memory bus write
// breaks 32-bit value into 4 individual bytes
// in little-endian order

void store_word(uint32_t address, uint32_t value) {
    if (address + 3 >= 4096) return;
    memory[address]     = value & 0xFF;         
    memory[address + 1] = (value >> 8) & 0xFF;
    memory[address + 2] = (value >> 16) & 0xFF;
    memory[address + 3] = (value >> 24) & 0xFF; 
}

// ARITHMETIC LOGIC UNIT (ALU) 
// ALU is computational, combinational circuit, no clock or state, just inputs and outputs


uint32_t execute_alu(uint32_t op1, uint32_t op2, const std::string& operation) {
    if (operation == "ADD") return op1 + op2;
    if (operation == "SUB") return op1 - op2;
    if (operation == "AND") return op1 & op2;
    if (operation == "OR")  return op1 | op2;
    if (operation == "XOR") return op1 ^ op2;

    // Set less than (signed) - compares as signed ints
    // return 1 if op1 < op2 else 0. 
    if (operation == "SLT") return (int32_t)op1 < (int32_t)op2 ? 1 : 0; 

    // Set less than (unsigned) - address comparison
    if (operation == "SLTU") return op1 < op2 ? 1 : 0; 

    //Shift operation, op2 is the shift ammount
    if (operation == "SLL") return op1 << op2; // left shoft with 0s
    if (operation == "SRL") return op1 >> op2; // right shift with 0s
    if (operation == "SRA") return (int32_t)op1 >> op2; // arithemtic right shift - with sign bits
    
    return 0;
}

// Decoder Helper
// Risc-v encodes constant vals (immediates) dependent on instruction format
// bits are scrambled across 32-bit instruction word to keep rs1, rs2, and rd in same positions
// extracts and reassembles the imm for one format
// sign-extends the result to 32 bits to be used in arithmetic - replicating top bit of imm to fill upper bits

// Sign extend
// Used in I-type and S-type - immediate is 12 bits wide, 11th bit is sign
// If 1, fill upper with 1, else cast to signed (fill 0)

int32_t sign_extend_12(uint32_t imm) {
    if (imm & 0x800) imm |= 0xFFFFF000;
    return (int32_t)imm;
}

// Decode B type imm
// B-type encodes signed 13-bit offset 
// bits are scattered across 31, 30:25, 11:8, 7 of instruction word
// imm[0] = 0 - branch targets are 2-byte aligned
int32_t decode_B_imm(uint32_t instr) {
    int32_t imm = ((instr >> 31) << 12) |           // bit 12
                  (((instr >> 7) & 0x1) << 11) |    // bit 11
                  (((instr >> 25) & 0x3F) << 5) |   // bits 10:5
                  (((instr >> 8) & 0xF) << 1);      // bits 4:1
    if (imm & 0x1000) imm |= 0xFFFFE000;
    return imm;
}

//Decode J-type imm
// J-type encodes signed 21-bit offset
// bits are scattered across 31, 30:21, 20, 19:12
int32_t decode_J_imm(uint32_t instr){
    int32_t imm = ((instr >> 31) << 20) |              //  bit 31 (sign)
                  (((instr >> 21) & 0x3FF) << 1) |     // bit 30:21 - 10:1
                  (((instr >> 20) & 0x1) << 11) |      // bit 20 - 11
                  (((instr >> 12) & 0xFF) << 12);      // bit 19:12 - 19:12

    // Sign extend fromn the 20th bit if its neg
    if (imm & 0x100000){
        imm |= 0xFFE00000;
    }
    return imm;
}

// Decode s-type imm
// s-type splits 12-bit imm across two fields 
// i-type uses rs2 for lower imm

int32_t decode_S_imm(uint32_t instr) {
    uint32_t imm = (((instr >> 25) & 0x7F) << 5) |   // imm[11:5]
                   (((instr >> 7)  & 0x1F) << 0);    // imm[4:0]

    if (imm & 0x800) imm |= 0xFFFFF000;
    return (int32_t)imm;
}

// Execution - control unit + datapath
// function models instruction decode and execute stages of pipelines
// extracts the opcode, reg fields
// identifies instruction type from opcodce
// decodes format-specific fields 
// executes the opperation
// writes the result back to reg fiel or memory


void decode_and_execute(uint32_t instr) {
    uint32_t opcode = instr & 0x7F;             // bits 6:0
    uint32_t rd     = (instr >> 7) & 0x1F;      // bit 11:7
    uint32_t funct3 = (instr >> 12) & 0x7;      // bits 14:12
    uint32_t rs1    = (instr >> 15) & 0x1F;     // bits 19:15
    uint32_t rs2    = (instr >> 20) & 0x1F;     // bits 24:20
    uint32_t funct7 = (instr >> 25) & 0x7F;     // bits 31:25

    switch (opcode) {
        //I-type - immediate arithmetic 
        case 0x13: { 
            int32_t imm = sign_extend_12(instr >> 20);
            uint32_t result = 0;
            
            switch (funct3){
                case 0x0: // add Imm
                    result = execute_alu(registers[rs1], imm, "ADD");
                    break;
                case 0x1: { // shift left logical imm
                    uint32_t shamt = rs2; 
                    result = execute_alu(registers[rs1], shamt, "SLL");
                    break;
                }
                case 0x2: // set less than imm
                    result = execute_alu(registers[rs1], imm, "SLT");
                    break;

                case 0x3: // set less than imm unsigned 
                    result = execute_alu(registers[rs1], (uint32_t)imm, "SLTU");
                    break;
                case 0x4: // bitwise xor imm
                    result = execute_alu(registers[rs1], imm, "XOR");
                    break;
                case 0x5: { // shift right Logical or Arithmetic Immediate
                    uint32_t shamt = rs2; 
                    uint32_t is_SRAI = (instr >> 30) & 0x1; 
                    
                    if (is_SRAI) {
                        result = execute_alu(registers[rs1], shamt, "SRA");
                    } else {
                        result = execute_alu(registers[rs1], shamt, "SRL");
                    }
                    break;
                }
                case 0x6: // bitwise or imm
                    result = execute_alu(registers[rs1], imm, "OR");
                    break;
                case 0x7: // bitwise and imm
                    result = execute_alu(registers[rs1], imm, "AND");
                    break;
                default:
                    std::cout << "Unknown I-type funct3: 0x" << std::hex << funct3 << std::dec << std::endl;
                return;
            }

            write_reg(rd, result);
            break;
        }
        case 0x33: { // R-Type: register-register arithmetic and logic
            uint32_t result = 0;

            switch (funct3) {
                case 0x0: // add or sub
                    if (funct7 == 0x20) {
                        result = execute_alu(registers[rs1], registers[rs2], "SUB");
                    } else {
                        result = execute_alu(registers[rs1], registers[rs2], "ADD");
                    }
                    break;
                    
                case 0x1: // SLL (Shift Left Logical)
                    result = execute_alu(registers[rs1], registers[rs2] & 0x1F, "SLL");
                    break;
                    
                case 0x2: // SLT (Set Less Than - Signed)
                    result = execute_alu(registers[rs1], registers[rs2], "SLT");
                    break;
                    
                case 0x3: // SLTU (Set Less Than - Unsigned)
                    result = execute_alu(registers[rs1], registers[rs2], "SLTU");
                    break;
                    
                case 0x4: // XOR (Bitwise XOR)
                    result = execute_alu(registers[rs1], registers[rs2], "XOR");
                    break;
                    
                case 0x5: // SRL or SRA
                    if (funct7 == 0x20) {
                        result = execute_alu(registers[rs1], registers[rs2] & 0x1F, "SRA");
                    } else {
                        result = execute_alu(registers[rs1], registers[rs2] & 0x1F, "SRL");
                    }
                    break;
                    
                case 0x6: // OR (Bitwise OR)
                    result = execute_alu(registers[rs1], registers[rs2], "OR");
                    break;
                    
                case 0x7: // AND (Bitwise AND)
                    result = execute_alu(registers[rs1], registers[rs2], "AND");
                    break;
                    
                default:
                    std::cout << "Unknown R-Type funct3: 0x" << std::hex << funct3 << std::dec << std::endl;
                    return;
            }

            write_reg(rd, result);
            break;
        }
        case 0x23: { // S-type Store Instructions 
            int32_t imm = decode_S_imm(instr);
            uint32_t address = registers[rs1] + imm;
            uint32_t value = registers[rs2];

            switch (funct3) {
                case 0x0: // SB (Store Byte)
                    memory[address] = (uint8_t)(value & 0xFF);
                    break;
                    
                case 0x1: // SH (Store Halfword)
                    memory[address]     = (uint8_t)(value & 0xFF);
                    memory[address + 1] = (uint8_t)((value >> 8) & 0xFF);
                    break;
                    
                case 0x2: // SW (Store Word)
                    memory[address]     = (uint8_t)(value & 0xFF);
                    memory[address + 1] = (uint8_t)((value >> 8) & 0xFF);
                    memory[address + 2] = (uint8_t)((value >> 16) & 0xFF);
                    memory[address + 3] = (uint8_t)((value >> 24) & 0xFF);
                    break;
                    
                default:
                    std::cout << "Unknown Store funct3: 0x" << std::hex << funct3 << std::dec << std::endl;
                    return;
            }
            break;
        }
        case 0x63: { // B-Type branch instructions, pc offset relative address branch
            int32_t imm = decode_B_imm(instr);
            bool take_branch = false;

            switch (funct3) {
                case 0x0: // BEQ (Branch Equal)
                    if (registers[rs1] == registers[rs2]) take_branch = true;
                    break;
                case 0x1: // BNE (Branch Not Equal)
                    if (registers[rs1] != registers[rs2]) take_branch = true;
                    break;
                case 0x4: // BLT (Branch Less Than - Signed)
                    if ((int32_t)registers[rs1] < (int32_t)registers[rs2]) take_branch = true;
                    break;
                case 0x5: // BGE (Branch Greater Than or Equal - Signed)
                    if ((int32_t)registers[rs1] >= (int32_t)registers[rs2]) take_branch = true;
                    break;
                case 0x6: // BLTU (Branch Less Than - Unsigned)
                    if (registers[rs1] < registers[rs2]) take_branch = true; // Natural uint32_t behavior
                    break;
                case 0x7: // BGEU (Branch Greater Than or Equal - Unsigned)
                    if (registers[rs1] >= registers[rs2]) take_branch = true;
                    break;
                default:
                    std::cout << "Unknown B-Type funct3: 0x" << std::hex << funct3 << std::dec << std::endl;
                    return;
            }

            // If condition is met, update PC (accounting for natural loop increment)
            if (take_branch) {
                pc = pc + imm - 4;
            }
            break;
        }
       case 0x03: { // I-type Load Instructions 
            int32_t imm = sign_extend_12(instr >> 20);
            uint32_t address = registers[rs1] + imm;
            if (address + 3 >= 4096) {
                std::cout << "Memory access out of bounds: 0x" << std::hex << address << std::dec << std::endl;
                break;
            }
            uint32_t value = 0;

            switch (funct3) {
                case 0x0: { // LB (Load Byte - Signed)
                    int8_t byte_val = (int8_t)memory[address]; // Cast forces sign extension
                    value = (int32_t)byte_val;
                    break;
                }
                case 0x1: { // LH (Load Halfword - Signed)
                    // Combine two consecutive bytes
                    int16_t half_val = (int16_t)(memory[address] | (memory[address + 1] << 8));
                    value = (int32_t)half_val;
                    break;
                }
                case 0x2: // LW (Load Word)
                    value = memory[address] | 
                            (memory[address + 1] << 8) | 
                            (memory[address + 2] << 16) | 
                            (memory[address + 3] << 24);
                    break;
                case 0x4: // LBU (Load Byte Unsigned)
                    value = (uint32_t)memory[address]; // Zero extension happens naturally
                    break;
                case 0x5: // LHU (Load Halfword Unsigned)
                    value = (uint32_t)(memory[address] | (memory[address + 1] << 8));
                    break;
                default:
                    std::cout << "Unknown Load funct3: 0x" << std::hex << funct3 << std::dec << std::endl;
                    return;
            }

            write_reg(rd, value);
            break;
        }

        case 0x67: { // I-type: JALR (jump nd link reg)
            int32_t imm = sign_extend_12(instr >>20);

            //calc target address from rs1 + offset
            uint32_t target_address = registers[rs1] + imm;

            // clear the lowest bit of the targ address
            target_address &= ~1;

            // link save add to rd
            write_reg(rd, pc+4);

            // jump - update pc to target address
            pc = target_address - 4;
            break;
        
        }

        case 0x37: { // U-Type: LUI (Load Upper Immediate)
            uint32_t imm = instr & 0xFFFFF000; 
            write_reg(rd, imm);
            break;
        }
        case 0x17: { // U-Type: AUIPC (add upper immeditate to pc)
            int32_t imm = instr & 0xFFFFF000; 
            uint32_t result = pc + imm;
            write_reg(rd, result);
            break;
        }
        case 0x6F: { // J-Type: JAL (jump and link)
            int32_t imm = decode_J_imm(instr);
            // save return address to rd
            write_reg(rd, pc + 4);
            
            // jump - update pc to target address
            pc = pc + imm - 4;
            break;
        }

        case 0x0F: // FENCE - no-op for single-core sim
            break;

        case 0x73: { // System Calls
            if (registers[17] == 10) { // x17 is used for system call numbers
                std::cout << "Program exited gracefully via ECALL." << std::endl;
                pc = 4096; // Jump to end of memory to stop the loop
            }
            break;
        }
        default:
            std::cout << "Unknown Opcode: 0x" << std::hex << opcode << std::dec << std::endl;
    }
}

// File loader
void load_from_file(const std::string& filename){
    std::ifstream file(filename);
    if(!file.is_open()){
        std::cerr << "Error: could not open file " << filename << std::endl;
        return;
    }

    std::string line;
    uint32_t current_pc = 0;
    int line_num = 0;

    while (std::getline(file, line)){
        line_num++;
        if(line.empty()) continue;

        try {
            uint32_t instr = std::stoul(line, nullptr, 16);
            store_word(current_pc, instr);
            current_pc += 4;
        } catch (const std::exception& e) {
            std::cerr << "Bad line " << line_num << " in hex file: \"" << line << "\"" << std::endl;
        }
    }

    std::cout << "Loaded " << (current_pc / 4) << " instructions." << std::endl;
}

void dump_registers() {
    std::cout << "\n============================================" << std::endl;
    std::cout << "          FINAL REGISTER FILE STATE         " << std::endl;
    std::cout << "============================================" << std::endl;

    for (int i = 0; i < 32; i++) {
        std::cout << "x" << std::setw(2) << std::left << i << ": ";

        // ↓ Reset to right-alignment before printing values
        std::cout << "0x" << std::setw(8) << std::right << std::setfill('0') << std::hex << registers[i];
        std::cout << std::dec << " (" << std::setw(10) << std::setfill(' ') << (int32_t)registers[i] << ")";

        if (i % 2 == 1) {
            std::cout << std::endl;
        } else {
            std::cout << "  |  ";
        }
    }
    std::cout << "============================================" << std::endl;
}
// MAIN SIMULATION LOOP

void run_sim() {
    while (pc < 4096) {
        uint32_t instr = fetch_instruction(pc);
        if (instr == 0) break; // End of program
        
        decode_and_execute(instr);
        pc += 4;
    }
}

// PROGRAM LOADER

int main() {
    load_from_file("program.hex");

    run_sim();

    dump_registers();

    return 0;
}