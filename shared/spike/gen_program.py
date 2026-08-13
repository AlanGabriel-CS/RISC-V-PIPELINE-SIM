"""
gen_program.py

Generates ONE random program, deterministically from a seed, and writes it
in both forms needed for this comparison:
  - program.hex  (plain hex words, one per line -- what $readmemh expects)
  - program.elf  (minimal ELF32, for Spike)

Restricted to the subset of RV32I the SystemVerilog core actually
implements correctly -- not the full ISA:
  - R-type: all 10 (add/sub/sll/slt/sltu/xor/srl/sra/or/and)
  - I-type arithmetic: all 9 (addi/slti/sltiu/xori/ori/andi/slli/srli/srai)
  - Loads/stores: LW/SW only (the RTL ignores funct3 for loads/stores --
    lb/lh/lbu/lhu/sb/sh would silently behave like lw/sw on real hardware,
    which is a known, separate limitation, not something this comparison
    is trying to catch)
  - Branches: BEQ/BNE/BLT/BGE only (BLTU/BGEU are decoded but never
    resolve taken in this core's branch_taken logic -- again, a known
    limitation, out of scope for THIS comparison)
  - JAL, JALR, LUI, AUIPC
  - Real bounded loops (init counter in x30, straight-line random body,
    decrement, backward branch), interleaved into the random stream at
    ~15% probability per step -- see random_loop_block(). x30 is reserved
    for this exactly like x31 is reserved as the load/store base register.

Load/store addresses are kept within the SV core's actual 64-word
(256-byte) data memory (`ram[0:63]` in data_mem.sv) -- an address outside
that range would be an out-of-bounds array access in the RTL, which isn't
a meaningful thing to compare.

The program always ends with a deliberate infinite self-branch
(`beq x0, x0, 0`) rather than any host/target-interface exit convention --
this sidesteps needing Spike's tohost/fromhost ELF-symbol mechanism
entirely. Both simulators are expected to run into this and sit there;
downstream tooling detects "done" by the PC no longer changing, not by any
simulator-reported clean exit.
"""

import random
import struct
import sys

# ---- encoding helpers -------------------------------------------------

def _u32(v):
    return v & 0xFFFFFFFF


def enc_r(opcode, funct3, funct7, rd, rs1, rs2):
    return _u32((funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode)


def enc_i(opcode, funct3, rd, rs1, imm):
    return _u32(((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode)


def enc_shift(opcode, funct3, funct7, rd, rs1, shamt):
    return _u32((funct7 << 25) | ((shamt & 0x1F) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode)


def enc_s(opcode, funct3, rs1, rs2, imm):
    imm &= 0xFFF
    return _u32(((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((imm & 0x1F) << 7) | opcode)


def enc_b(opcode, funct3, rs1, rs2, imm):
    imm &= 0x1FFF
    b12, b11 = (imm >> 12) & 1, (imm >> 11) & 1
    b105, b41 = (imm >> 5) & 0x3F, (imm >> 1) & 0xF
    return _u32((b12 << 31) | (b105 << 25) | (rs2 << 20) | (rs1 << 15) |
                (funct3 << 12) | (b41 << 8) | (b11 << 7) | opcode)


def enc_u(opcode, rd, imm20):
    return _u32(((imm20 & 0xFFFFF) << 12) | (rd << 7) | opcode)


def enc_j(opcode, rd, imm):
    imm &= 0x1FFFFF
    b20, b19_12 = (imm >> 20) & 1, (imm >> 12) & 0xFF
    b11, b10_1 = (imm >> 11) & 1, (imm >> 1) & 0x3FF
    return _u32((b20 << 31) | (b19_12 << 12) | (b11 << 20) | (b10_1 << 21) | (rd << 7) | opcode)


R_TYPE = [
    (0x33, 0x0, 0x00), (0x33, 0x0, 0x20), (0x33, 0x1, 0x00), (0x33, 0x2, 0x00),
    (0x33, 0x3, 0x00), (0x33, 0x4, 0x00), (0x33, 0x5, 0x00), (0x33, 0x5, 0x20),
    (0x33, 0x6, 0x00), (0x33, 0x7, 0x00),
]
I_ARITH = [(0x13, f3) for f3 in (0x0, 0x2, 0x3, 0x4, 0x6, 0x7)]
I_SHIFT = [(0x13, 0x1, 0x00), (0x13, 0x5, 0x00), (0x13, 0x5, 0x20)]
BRANCHES = [(0x63, f3) for f3 in (0x0, 0x1, 0x4, 0x5)]  # beq bne blt bge -- not bltu/bgeu


def _reg(rng):
    # x31 is reserved exclusively as the load/store base register (set up
    # once via auipc+addi at the start of random_program). x30 is reserved
    # exclusively as the loop induction/counter register used by
    # random_loop_block below. Excluding both here is necessary, not just
    # tidy: an unrelated randomly-generated instruction landing on rd=31 or
    # rd=30 clobbers the base address or an in-flight loop's trip counter,
    # which then makes every subsequent load/store (or loop iteration
    # count) garbage -- an out-of-bounds SV array read producing 'x', or an
    # infinite/short-circuited loop, from the same single root cause.
    return rng.randint(0, 29)


DATA_MEM_BYTES = 4096      # SV core's data_mem is 1024 words -- ram[0:1023]
LOAD_STORE_WINDOW = 32     # max +/- offset used by any single load/store below

# ---- loop-block generation ---------------------------------------------
#
# Every random program up to this point had exactly one backward branch:
# the trivial infinite `beq x0,x0,0` epilogue. That's enough to exercise
# the loop buffer's *entry* path, but not its actual replay logic -- it
# never has more than one distinct instruction to cache, and it never
# exits back to straight-line code. random_loop_block() generates a real
# bounded loop instead: init a counter (x30, reserved -- see _reg), run a
# straight-line body of ordinary random instructions, decrement, branch
# back if nonzero. This is the shape that stresses the loop buffer the way
# an actual RV32I workload would: varied bodies, varied trip counts, and a
# real fallthrough exit afterward.
LOOP_BODY_WORDS = (1, 5)    # body length range, in instructions
LOOP_TRIP_COUNTS = (2, 8)   # iteration count range
LOOP_BLOCK_PROB = 0.15      # chance of emitting a loop block at each step
                            # (vs. a single straight-line instruction)


def _in_any_range(idx, ranges):
    return any(lo <= idx < hi for lo, hi in ranges)


def _gen_one_instr(rng, written_offsets, allow_branch_jal=True, pos=None, total=None, loop_ranges=()):
    """Generate one random instruction word. Shared by random_program's
    top-level stream and random_loop_block's body -- loop bodies pass
    allow_branch_jal=False to keep the body straight-line, since a nested
    branch/jal would need its own span bookkeeping independent of the
    enclosing loop's fixed backward-branch offset, and isn't needed to
    stress the loop buffer's replay path (that's exercised by the
    enclosing loop's own backward branch). When allow_branch_jal is True,
    pos/total (this instruction's word index and the stream's total word
    count) are required -- same clamped +/-8-word span used by the
    original single-pass generator, so a branch/jal never targets outside
    the stream.

    loop_ranges is the full, precomputed list of (lo, hi) word-index spans
    already claimed by loop blocks elsewhere in the program (see
    random_program's two-pass structure). A top-level branch/jal must never
    target inside one of these: landing on, say, a loop's own backward
    branch instruction after its counter has already hit zero turns that
    single instruction into a permanent not-taken self-loop the moment
    something else jumps back into it -- a real deadlock found by testing
    this generator, not a hypothetical."""
    categories = ["r", "i_arith", "i_shift", "store"]
    weights = [10, 10, 4, 8]
    if allow_branch_jal:
        categories += ["branch", "jal"]
        weights += [8, 3]
    if written_offsets:
        categories.append("load")
        weights.append(8)

    category = rng.choices(categories, weights=weights)[0]

    if category == "r":
        op, f3, f7 = rng.choice(R_TYPE)
        return enc_r(op, f3, f7, _reg(rng), _reg(rng), _reg(rng))
    elif category == "i_arith":
        op, f3 = rng.choice(I_ARITH)
        return enc_i(op, f3, _reg(rng), _reg(rng), rng.randint(-2048, 2047))
    elif category == "i_shift":
        op, f3, f7 = rng.choice(I_SHIFT)
        return enc_shift(op, f3, f7, _reg(rng), _reg(rng), rng.randint(0, 31))
    elif category == "load":
        offset = rng.choice(sorted(written_offsets))
        return enc_i(0x03, 0x2, _reg(rng), 31, offset)  # lw only
    elif category == "store":
        offset = rng.randrange(-LOAD_STORE_WINDOW, LOAD_STORE_WINDOW + 1, 4)
        written_offsets.add(offset)
        return enc_s(0x23, 0x2, 31, _reg(rng), offset)  # sw only
    elif category == "branch":
        # Forward only, same reasoning as JAL above: a top-level backward
        # branch whose condition happens to keep evaluating "taken" (purely
        # because the compared registers aren't touched again before it's
        # next reached -- no bug needed, just bad luck with data-dependent
        # control flow) forms an accidental infinite loop. Tried a
        # low-probability/short-span allowance for backward branches first;
        # at n=400+ it still made most generated programs hang, since the
        # chance that *at least one* of many branches goes bad approaches 1
        # as the branch count grows. Backward-branch coverage isn't lost --
        # random_loop_block's own bne is a real backward branch that's
        # provably terminating by construction (decrementing counter, body
        # can't touch it), and it's exactly what exercises the loop
        # buffer/BTB against a genuine repeated target.
        op, f3 = rng.choice(BRANCHES)
        max_span = min(8, total - 1 - pos) or 1
        candidates = [d for d in range(1, max_span + 1) if not _in_any_range(pos + d, loop_ranges)]
        delta_words = rng.choice(candidates or [1])
        return enc_b(op, f3, _reg(rng), _reg(rng), delta_words * 4)
    elif category == "jal":
        # Forward only, deliberately -- unlike branch, JAL is unconditional.
        # A backward JAL with nothing along the way to conditionally break
        # out forms a guaranteed, permanent deadlock the instant it's
        # reached (found by testing: a 4-instruction span with a backward
        # JAL at the end looped forever, since nothing in the span could
        # ever escape it). Backward control flow that needs a real exit
        # condition is exactly what BRANCH and random_loop_block are for.
        max_span = min(8, total - 1 - pos) or 1
        candidates = [d for d in range(1, max_span + 1) if not _in_any_range(pos + d, loop_ranges)]
        delta_words = rng.choice(candidates or list(range(1, max_span + 1)))
        return enc_j(0x6F, _reg(rng), delta_words * 4)


def random_loop_block(rng, written_offsets, budget_words):
    """Returns (instr_words, retire_count) for one bounded loop, or None if
    it doesn't fit in budget_words. Layout:

        addi x30, x0, trip_count      <- init (1 word)
        <body_len random instructions>  (straight-line only)
        addi x30, x30, -1              <- decrement (1 word)
        bne  x30, x0, -(body_len+1)*4  <- branch back to body start

    Total words = body_len + 3. Retirements = 1 (init) + trip_count *
    (body_len + 2) (body + decrement + branch, repeated trip_count times --
    the branch itself retires every iteration, including the final
    not-taken one that falls through)."""
    max_body = min(LOOP_BODY_WORDS[1], budget_words - 3)
    if max_body < LOOP_BODY_WORDS[0]:
        return None

    body_len = rng.randint(LOOP_BODY_WORDS[0], max_body)
    trip_count = rng.randint(*LOOP_TRIP_COUNTS)

    init = enc_i(0x13, 0x0, 30, 0, trip_count)  # addi x30, x0, trip_count
    body = [_gen_one_instr(rng, written_offsets, allow_branch_jal=False) for _ in range(body_len)]
    decrement = enc_i(0x13, 0x0, 30, 30, -1)    # addi x30, x30, -1
    branch_back = enc_b(0x63, 0x1, 30, 0, -(body_len + 1) * 4)  # bne x30,x0,<back to body start>

    words = [init] + body + [decrement, branch_back]
    retire_count = 1 + trip_count * (body_len + 2)
    return words, retire_count


def random_program(rng: random.Random, n: int):
    """Returns a list of n encoded instruction words (the epilogue is
    appended separately by the caller, not counted in n)."""
    instrs = [None] * n

    # Two constraints, found via seed sweeps against two different reference
    # implementations, that turn out to conflict:
    #   1. Spike models unified memory -- data_offset must land past the
    #      end of the whole program, or a random store can silently
    #      corrupt real code (self-modifying code by accident).
    #   2. The SV core's data_mem is 1024 words (4096 bytes) -- ram[0:1023]
    #      -- so data_offset (plus the load/store window on either side)
    #      must stay inside that tiny range, or Icarus correctly returns
    #      'x' for the out-of-bounds access, which then poisons every
    #      downstream register and eventually the whole trace.
    # These two bounds don't always overlap -- there's no single address
    # that's simultaneously "past all the code" and "inside 256 bytes"
    # once the program gets long enough. Rather than let a violated
    # constraint silently produce garbage, fail loudly here so a too-long
    # program is obvious immediately, not 50 retirements deep in a trace.
    total_words = 31 + n + 1  # 31-instr register-clear preamble + n + epilogue
    program_end_bytes = total_words * 4

    # auipc x31,0 (below) sets x31 to its own pc, not 0 -- that's word index
    # 31, i.e. byte 124, since it sits right after the fixed 31-instruction
    # preamble. The addi immediate therefore has to be program_end_bytes
    # minus that 124, not program_end_bytes itself -- otherwise the final
    # x31 lands 124 bytes further out than intended and reads out-of-range
    # array indices on every load through it (which Icarus correctly
    # returns as 'x').
    #
    # It's not enough to then place x31 at exactly program_end_bytes either:
    # stores use offsets down to -LOAD_STORE_WINDOW, so a store can still
    # land as far back as (x31 - LOAD_STORE_WINDOW), which is inside the
    # program's own text if x31 sits right at the boundary. Spike models
    # unified memory, so that silently overwrites a not-yet-executed
    # instruction as real self-modifying code -- e.g. `sw x17, -20(x31)`
    # overwriting a later instruction's word, which Spike then decodes as
    # an illegal instruction and traps on when it fetches the corrupted
    # word. The SV core never sees this at all -- instruction_mem and
    # data_mem are two physically separate arrays, so a data store can
    # never affect what the SV core fetches, unlike Spike's single unified
    # address space. Pushing x31 an extra LOAD_STORE_WINDOW past
    # program_end_bytes closes the gap: the most-negative store can then
    # reach is exactly program_end_bytes itself, never anything before it.
    AUIPC_PC = 31 * 4
    data_offset = program_end_bytes - AUIPC_PC + LOAD_STORE_WINDOW

    max_valid_end = DATA_MEM_BYTES - 4 - 2 * LOAD_STORE_WINDOW
    assert program_end_bytes <= max_valid_end, (
        f"Program too long for both constraints to hold: n={n} gives "
        f"program_end_bytes={program_end_bytes}, but it must be <= {max_valid_end} "
        f"to fit inside the SV core's 256-byte data_mem AND keep the full "
        f"+/-{LOAD_STORE_WINDOW}-byte store window clear of the program's own "
        f"text. Reduce n (try n <= {max_valid_end // 4 - 32} for this "
        f"preamble/epilogue size)."
    )

    # x31 reserved as the load/store base register. Computed PC-relative
    # (auipc + addi) rather than as an absolute literal (lui + addi) --
    # necessary because the SV core's tiny data memory starts at address
    # 0x0 while Spike permanently reserves 0x0-0x1000 for its own boot
    # stub. auipc x31,0 makes x31 = this instruction's own address on
    # each side; data_offset (now well past the whole program) lands each
    # side in its own valid, non-code-overlapping region.
    instrs[0] = enc_u(0x17, 31, 0)               # auipc x31, 0
    if n > 1:
        instrs[1] = enc_i(0x13, 0x0, 31, 31, data_offset)  # addi x31,x31,data_offset
    start = 2 if n > 1 else 1

    written_offsets = set()  # offsets (relative to x31) this program has stored to so far
    expected_retire = 0
    loop_ranges = []   # (lo, hi) word spans claimed by loop blocks, decided in pass 1
    single_slots = []  # word indices still needing content, filled in pass 2

    # Pass 1: walk the whole n-word budget deciding loop-block placement
    # only. This has to happen before ANY single-instruction content
    # (particularly branch/jal targets) is generated, because a branch
    # placed in pass order could otherwise target a loop block that gets
    # placed *later* in the same walk -- loop_ranges wouldn't know about it
    # yet. Two passes means loop_ranges is complete before pass 2 needs it.
    i = start
    while i < n:
        loop_block = random_loop_block(rng, written_offsets, n - i) if rng.random() < LOOP_BLOCK_PROB else None
        if loop_block is not None:
            words, retire_count = loop_block
            instrs[i:i + len(words)] = words
            loop_ranges.append((i, i + len(words)))
            expected_retire += retire_count
            i += len(words)
        else:
            single_slots.append(i)
            expected_retire += 1
            i += 1

    # Pass 2: fill the deferred single-instruction slots, now that
    # loop_ranges is final -- branch/jal targets in this pass avoid every
    # loop block in the program, not just ones placed earlier.
    #
    # Loads are only viable once something's actually been stored --
    # otherwise the loaded value depends on each simulator's default (and,
    # it turns out, different) memory-initialization convention, which
    # isn't something this comparison is trying to test: Spike returns
    # leftover host memory on a load-before-store, while the SV testbench
    # explicitly zero-initializes. Neither is "wrong" for its own
    # convention, but they're not comparable without this fix. Note pass 2
    # still runs left-to-right, so written_offsets fills in the same order
    # it would have in a single pass -- this doesn't change what's loadable
    # at any given slot, only when branch targets get resolved.
    for i in single_slots:
        instrs[i] = _gen_one_instr(rng, written_offsets, allow_branch_jal=True,
                                    pos=i, total=n, loop_ranges=loop_ranges)

    return instrs, expected_retire


EPILOGUE = enc_b(0x63, 0x0, 0, 0, 0)  # beq x0, x0, 0 -- infinite self-branch


def clear_all_regs_preamble():
    """Spike's own boot stub (auipc/addi/csrr/lw/jr) writes to several
    registers -- x5 in particular ends up holding the ELF entry point
    address -- and never clears them before jumping to the generated
    program. The SV core (real hardware reset) and any from-spec golden
    model both correctly start with all registers at 0, but Spike's
    leftover boot-stub state means x5 (and likely others) genuinely isn't
    0 when the program starts. A real compiled program wouldn't care --
    calling conventions don't guarantee incoming register values -- but a
    raw random instruction stream can and will read a register before
    ever writing it. Rather than track this register-by-register, just
    zero all 31 non-x0 registers explicitly as the program's own first
    instructions, so starting state is fully known and identical either
    way."""
    return [enc_i(0x13, 0x0, r, 0, 0) for r in range(1, 32)]  # addi xr, x0, 0


def build_full_program(rng: random.Random, n: int):
    """Returns (instr_words, expected_retire_count). expected_retire_count
    is 31 (preamble, one retirement each) + the random stream's own
    analytical estimate + 1 (the epilogue's first retirement, before it
    starts repeating -- downstream comparison tooling truncates the
    repeated tail itself, this is just a generation-time sanity budget)."""
    program, program_retire = random_program(rng, n)
    return clear_all_regs_preamble() + program + [EPILOGUE], 31 + program_retire + 1


# ---- minimal ELF32 writer ----------------------------------------------

ENTRY_ADDR = 0x80000000


def build_elf32(instr_words, entry=ENTRY_ADDR):
    """Minimal ELF32 (EM_RISCV) with a single PT_LOAD segment containing
    the raw instruction bytes, loaded at `entry`, plus a minimal section
    header table (a mandatory null section + a .shstrtab section).

    The section headers are not strictly required by the ELF spec for a
    valid executable -- e_shnum=0 is explicitly permitted, meaning "no
    section headers." Spike's loader (elfloader.cc), however, asserts
    e_shstrndx < e_shnum unconditionally, which is false whenever both are
    0 -- so a non-empty section header table must exist even though
    nothing in it is actually used for execution (only the PT_LOAD program
    header actually matters for what gets loaded into memory)."""
    code = b"".join(struct.pack("<I", w) for w in instr_words)

    EHDR_SIZE = 52
    PHDR_SIZE = 32
    SHDR_SIZE = 40

    # Section header string table content: byte 0 must be the empty
    # string (mandatory, sh_name=0 conventionally means "no name"), then
    # ".shstrtab\0" itself.
    shstrtab_content = b"\x00.shstrtab\x00"
    shstrtab_name_offset = 1  # offset of ".shstrtab" within shstrtab_content

    code_offset = EHDR_SIZE + PHDR_SIZE
    shstrtab_offset = code_offset + len(code)
    shoff = shstrtab_offset + len(shstrtab_content)

    e_ident = b"\x7fELF" + bytes([1, 1, 1, 0]) + b"\x00" * 8
    e_type = 2       # ET_EXEC
    e_machine = 243  # EM_RISCV
    e_version = 1
    e_entry = entry
    e_phoff = EHDR_SIZE
    e_shoff = shoff
    e_flags = 0
    e_ehsize = EHDR_SIZE
    e_phentsize = PHDR_SIZE
    e_phnum = 1
    e_shentsize = SHDR_SIZE
    e_shnum = 2        # null section + .shstrtab
    e_shstrndx = 1     # index of .shstrtab within the section header table

    ehdr = e_ident + struct.pack(
        "<HHIIIIIHHHHHH",
        e_type, e_machine, e_version, e_entry, e_phoff, e_shoff, e_flags,
        e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx,
    )

    p_type = 1        # PT_LOAD
    p_offset = code_offset
    p_vaddr = entry
    p_paddr = entry
    p_filesz = len(code)
    p_memsz = len(code)
    p_flags = 5        # PF_X | PF_R
    p_align = 0x1000

    phdr = struct.pack(
        "<IIIIIIII",
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align,
    )

    # Section 0: mandatory null section, all fields zero.
    shdr_null = struct.pack("<IIIIIIIIII", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    # Section 1: .shstrtab itself (SHT_STRTAB = 3).
    shdr_shstrtab = struct.pack(
        "<IIIIIIIIII",
        shstrtab_name_offset,  # sh_name
        3,                      # sh_type = SHT_STRTAB
        0,                      # sh_flags
        0,                      # sh_addr (not loaded into memory)
        shstrtab_offset,        # sh_offset
        len(shstrtab_content),  # sh_size
        0, 0, 1, 0,              # sh_link, sh_info, sh_addralign, sh_entsize
    )

    elf_bytes = ehdr + phdr + code + shstrtab_content + shdr_null + shdr_shstrtab
    assert len(ehdr) == EHDR_SIZE and len(phdr) == PHDR_SIZE
    assert len(shdr_null) == SHDR_SIZE and len(shdr_shstrtab) == SHDR_SIZE
    return elf_bytes


def self_check_elf(elf_bytes):
    """Re-parse the ELF header fields back out and confirm they're
    internally consistent -- the closest thing to validation available
    without an actual ELF loader (Spike) to test against."""
    assert elf_bytes[:4] == b"\x7fELF"
    e_type, e_machine, e_version, e_entry, e_phoff, e_shoff, e_flags, \
        e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = \
        struct.unpack("<HHIIIIIHHHHHH", elf_bytes[16:52])
    assert e_machine == 243, f"expected EM_RISCV=243, got {e_machine}"
    assert e_type == 2, f"expected ET_EXEC=2, got {e_type}"
    p_type, p_offset, p_vaddr = struct.unpack("<III", elf_bytes[e_phoff:e_phoff + 12])
    assert p_type == 1, f"expected PT_LOAD=1, got {p_type}"
    assert p_vaddr == ENTRY_ADDR
    # This exact check is what Spike's loader asserts on.
    assert e_shstrndx < e_shnum, f"e_shstrndx={e_shstrndx} must be < e_shnum={e_shnum}"
    return True


def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 42
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    rng = random.Random(seed)
    program, expected_retire = build_full_program(rng, n)

    with open("program.hex", "w") as f:
        for w in program:
            f.write(f"{w:08x}\n")

    elf_bytes = build_elf32(program)
    self_check_elf(elf_bytes)
    with open("program.elf", "wb") as f:
        f.write(elf_bytes)

    print(f"Generated {len(program)} instructions (seed={seed}) -> program.hex, program.elf")
    print(f"ELF entry point: 0x{ENTRY_ADDR:08x}")
    print(f"Estimated retirement count (incl. preamble, excl. epilogue repeats): ~{expected_retire}")


if __name__ == "__main__":
    main()