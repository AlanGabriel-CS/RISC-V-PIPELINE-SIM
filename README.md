# RISC-V-PIPELINE-SIM

A 5-stage pipelined RV32I core written in SystemVerilog, simulated with Icarus Verilog and cross-checked against Spike (the official RISC-V ISA simulator) for correctness. Started out as a simple cycle-accurate single-cycle simulator and grew into a proper pipeline with hazard detection, forwarding, branch prediction, and a loop buffer for cheap "icache gating" power savings.

## What's actually in here

- 5-stage pipeline: IF -> ID -> EX -> MEM -> WB
- Load-use hazard detection (1-cycle stall, see `hazard_unit.sv`)
- Full forwarding for EX operands (EX/MEM and MEM/WB, priority given to the closer one)
- Direct-mapped branch predictor, 64 entries, tagged BTB + 2-bit saturating counters
- A loop buffer that recognizes tight backward branches and replays instructions out of a small buffer instead of re-fetching, and freezes ("gates") the icache address while it does
- RV32I base integer instruction set (no M/F/D extensions)
- 256-byte data memory, 4KB instruction memory

## How I verify this thing

I don't trust my own testbenches to catch everything (learned that the hard way, see below), so the real correctness check is comparing this core's retirement trace against Spike, the reference RISC-V ISA simulator.

The repo is split across my PC and Mac, shared over an SMB folder, because I never got Spike building cleanly on Windows and honestly didn't feel like fighting it:

- **PC** compiles and runs the SV core in Icarus Verilog, produces `commit_log.txt` (the retirement trace) plus the program hex/elf
- **Mac** runs Spike against the same elf, then diffs the two traces with `compare_accuracy.py`

as of the last run, all 9 test programs (1 handwritten + 8 randomly generated batch programs) match Spike at 100%.

## Known limitations & test coverage

The 100% match is real, but the net it's cast is narrower than it sounds:

- **Random programs top out at ~15 instructions.** `gen_program.py` has to fit the whole program *and* a load/store scratch region inside the SV core's `data_mem` (64 words / 256B), because Spike models unified memory and an unlucky random store could otherwise overwrite not-yet-executed code. `instruction_mem` is already 4KB -- `data_mem` is the actual bottleneck, not the ISA or the generator logic.
- **The loop buffer has never been exercised by a random program.** Every generated program's only backward branch is the trivial `beq x0,x0,0` infinite epilogue at the end. Nothing in the random mix currently constructs a real bounded loop (induction variable + compare + backward branch, executed N times), so the loop buffer's replay path has only ever been validated by the two hand-written directed testbenches (`tb_loop_buffer.sv`, `tb_loop_buffer_edgecases.sv`), never cross-checked against Spike across varied loop bodies or trip counts.
- **LB/LH/LBU/LHU/SB/SH are excluded from the generator on purpose** -- the RTL ignores funct3 on loads/stores, so these would silently behave like LW/SW instead of exercising anything new. Same story for **BLTU/BGEU**: decoded, but the branch-taken logic never resolves them taken. Both are known RTL gaps, not generator gaps.
- **No exception/trap/CSR support at all** -- ecall, ebreak, misaligned access, illegal instructions, interrupts. Out of scope so far.

## Debugging notes (the stuff that actually took time)

Writing some of this down mostly for future-me, because I will 100% forget how any of this worked in six months.

**BTB aliasing was scarier than it sounds.** The original branch predictor was just a direct-mapped table indexed by PC bits, no tag. Worked fine right up until two branch addresses hashed to the same index -- then a trained "taken, jump to X" entry from one branch would get served to a completely unrelated instruction that happened to alias the same table slot. Since `predict_taken` steers fetch in IF regardless of whether the current instruction is even a branch, this wasn't just a misprediction (which gets flushed for free) -- it could redirect fetch off a plain ALU instruction with nothing there to ever flush it, so wrong-path code just... executes for real. Added a tag field to close it (`branch_predictor.sv`), a false index hit now just falls back to not-taken instead of a random jump.

**The x31 base register bug in `gen_program.py`.** My random program generator uses x31 as a base register for loads/stores, computed relative to the program's own address. First version placed it 124 bytes too high because I forgot `auipc`'s own PC needs to be accounted for in the offset math -- so x31 ended up pointing completely outside the 256-byte data_mem, and every load through it read back Icarus's undefined `x`. Fixed that, then immediately ran into a second, sneakier bug: with x31 now sitting right at the end of the program with no margin, a store with a negative offset could land back inside the program's own not-yet-executed instructions. Spike has unified memory, so that's genuine self-modifying code -- a store corrupts a real instruction word, and when Spike later fetches it, it traps. My SV core never saw any of this because `instruction_mem` and `data_mem` are two completely separate arrays there, so the bug was totally invisible on my side and only ever showed up as Spike mismatches. Took embarrassingly long to figure out why "random" single-instruction mismatches kept popping up near the end of programs. Fixed it by giving x31 a full 32-byte window past the end of the program, so the most-negative store offset can never reach backwards into it.

**Loop buffer wraparound.** the read index into the loop buffer is computed as `if_pc - loop_start`, then shifted down to a word offset. Doing a plain arithmetic compare against `write_ptr` without zero-extending first would silently break for a loop that fills the buffer exactly (comparing against a truncated width). Also needed an explicit range check on `if_pc` itself, not just index math, or a backward exit out of the loop could produce a false "valid" hit off unsigned wraparound. `tb_loop_buffer_edgecases.sv` exists specifically because I did not trust myself to get this right on the first try. I did not, in fact, get it right on the first try.

**Toolchain versions do not travel well.** oss-cad-suite's Icarus install is pinned to whatever version I set up on the PC (12.0). Found out the hard way that rebuilding against a newer local Icarus (13.0) throws fatal "sorry: constant selects" errors on some of the `always_comb` blocks -- a real Icarus limitation with constant part-selects inside procedural blocks (`imm_gen.sv` and `alu.sv` both hit it), not a design bug, but a good reminder to keep prebuilt sim binaries around instead of assuming "eh, it'll just recompile fine anywhere."

**And a dumb one I should probably just remove:** there's still a stray `$display("Branch opcode detected!")` sitting in `control_unit.sv` from when I was bringing up branch decode and needed to sanity-check it was actually firing. Harmless, just clutters up simulation stdout, and I keep forgetting to delete it.
