#include <iostream>
#include <fstream>
#include <string>
#include <memory>
#include "Vriscv_core.h"
#include "Vriscv_core___024root.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto top = std::make_unique<Vriscv_core>();

    std::cout << "=== RUNNING VERILATOR CPU SIMULATION ===" << std::endl;

    // Load instructions.hex directly from C++
    std::ifstream hex_file("instructions.hex");
    if (!hex_file.is_open()) {
        std::cerr << "[-] ERROR: Could not open instructions.hex from C++ testbench!" << std::endl;
        return 1;
    }

    std::string line;
    int mem_index = 0;
    while (std::getline(hex_file, line) && mem_index < 1024) {
        if (!line.empty() && line.rfind("//", 0) != 0) { // skip empty lines or pure comment lines
            unsigned int instruction_val = std::stoul(line, nullptr, 16);
            // Inject directly into the instruction memory array inside your core structure
            top->rootp->riscv_core__DOT__u_instruction_mem__DOT__mem[mem_index++] = instruction_val;
        }
    }
    std::cout << "[+] Successfully loaded " << mem_index << " instructions into memory." << std::endl;

    // Reset sequence
    top->clk = 0;
    top->rst_n = 0; 
    top->eval();
    top->clk = 1;
    top->eval();
    top->rst_n = 1; 

    // Run simulation for 20 clock cycles
    for (int cycle = 0; cycle < 20; cycle++) {
        top->clk = 0;
        top->eval();

        top->clk = 1;
        top->eval();

        auto& rf = top->rootp->riscv_core__DOT__u_reg_file__DOT__rf;

        std::cout << "Cycle: " << std::dec << cycle 
                  << " | PC: 0x" << std::hex << top->pc_out
                  << " | x1: " << std::dec << rf[1]
                  << " | x2: " << rf[2]
                  << " | x3: " << rf[3]
                  << std::endl;
    }

    std::cout << "=== SIMULATION FINISHED ===" << std::endl;
    return 0;
}