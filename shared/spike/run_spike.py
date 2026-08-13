"""
run_spike.py

Compiles the bare-metal test program (boot.s + main.c), runs it under
Spike with --log-commits, and exports the parsed instruction stream both
as a human-readable trace (spike_trace.txt) and as raw opcode hex
(inst_mem.hex) for the SystemVerilog side.
"""

import subprocess
import re


def build_binary():
    print("[*] Compiling bare-metal RISC-V binary...")
    compile_cmd = [
        "riscv64-elf-gcc",
        "-O2",  # Optimization level helps generate a rich instruction mix
        "-ffreestanding",
        "-nostdlib",
        "-T", "link.ld",
        "-o", "test",
        "boot.s",
        "main.c"
    ]
    result = subprocess.run(compile_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        print(f"Compilation failed:\n{result.stderr}")
        exit(1)
    print("[+] Compilation successful.")


def run_spike_and_parse():
    print("[*] Running Spike simulation with high instruction limit...")

    # Set instruction cap high enough to capture your loop (e.g., 5000 instructions)
    spike_cmd = ["spike", "--instructions=5000", "--log-commits", "-l", "test"]

    process = subprocess.run(spike_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    raw_log = process.stderr

    pattern = re.compile(r"core\s+(\d+):\s+(0x[0-9a-fA-F]+)\s+\((0x[0-9a-fA-F]+)\)\s+(.*)")

    parsed_instructions = []
    for line in raw_log.splitlines():
        match = pattern.search(line)
        if match:
            core, pc, inst_hex, disassembly = match.groups()
            parsed_instructions.append({
                "core": int(core),
                "pc": pc,
                "inst_hex": inst_hex,
                "disassembly": disassembly.strip()
            })

    output_filename = "spike_trace.txt"
    with open(output_filename, "w") as f:
        f.write("PC          | Opcode     | Disassembly\n")
        f.write("-" * 50 + "\n")
        for inst in parsed_instructions:
            f.write(f"{inst['pc']} | {inst['inst_hex']} | {inst['disassembly']}\n")

    print(f"[+] Simulation complete. Parsed {len(parsed_instructions)} instructions into '{output_filename}'.")
    return parsed_instructions


def export_for_sv(parsed_instructions):
    hex_filename = "inst_mem.hex"
    print(f"[*] Exporting raw opcodes to '{hex_filename}' for SystemVerilog...")

    with open(hex_filename, "w") as f:
        for inst in parsed_instructions:
            # Strip the '0x' prefix from the opcode hex string (e.g., 0x00000113 -> 00000113)
            clean_opcode = inst["inst_hex"][2:]
            f.write(f"{clean_opcode}\n")

    print(f"[+] Exported {len(parsed_instructions)} instructions to hex.")


if __name__ == "__main__":
    build_binary()
    instructions = run_spike_and_parse()
    export_for_sv(instructions)