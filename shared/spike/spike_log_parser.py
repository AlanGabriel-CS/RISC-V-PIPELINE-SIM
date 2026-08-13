"""
spike_log_parser.py

Parses Spike's combined `-l --log-commits` trace output into a canonical
list of retirement records:

    [{"idx": 0, "pc": 0x80000000, "reg": (rd, value) | None,
      "mem": (addr, value) | None}, ...]

CONFIDENCE NOTE: this parser was built from real-world reference examples
(GitHub issues showing actual Spike output), not from a live Spike
instance. The two patterns below are high-confidence, verified verbatim
across multiple independent real logs:

    core   0: 0x0000000080000000 (0x00000013) nop
    core   0: 3 0x0000000080000016 (0xfff00f1b) x30 0xffffffffffffffff

The exact memory-write commit line format could not be confirmed from
reference material alone. The MEM_RE pattern below is a best-effort guess
(mirroring the register-write line's structure with "mem 0x<addr>" instead
of "x<rd>"), not a verified fact.

If this script reports "N unrecognized lines" for what should be a
memory-heavy program, that's the first thing to check -- paste a few of
those raw lines back and the regex can be fixed in one pass rather than
guessed at again.
"""

import re
import sys

# Plain disassembly line (from -l), used to recover the PC-per-retirement
# sequence -- present for every instruction, register-writing or not.
PLAIN_RE = re.compile(
    r"core\s+\d+:\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)\s+(\S+.*)$"
)

# Register-commit line (from --log-commits), verified format.
REG_RE = re.compile(
    r"core\s+\d+:\s+\d+\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)\s+x\s*(\d+)\s+0x([0-9a-fA-F]+)"
)

# Memory-commit line -- best-effort guess, not independently confirmed.
MEM_RE = re.compile(
    r"core\s+\d+:\s+\d+\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)\s+mem\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)"
)

# "Bare" commit line: an instruction that writes neither a register nor
# memory (e.g. jr, or a branch) still gets a --log-commits line, just with
# nothing after the instruction word. Carries
# no information beyond the paired PLAIN_RE line for the same instruction,
# so it's recognized here purely to avoid flagging it as unparsed noise.
BARE_COMMIT_RE = re.compile(
    r"core\s+\d+:\s+\d+\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)\s*$"
)

EXCEPTION_RE = re.compile(r"core\s+\d+:\s+exception\s+(\S+)")


def parse_spike_log(path, entry_addr=0x80000000):
    records_by_pc_seq = []  # list of dicts, one per PLAIN_RE line seen, in order
    reg_by_line_context = {}  # keyed by (pc, instr_hex) -> (rd, value); best-effort correlation
    mem_by_line_context = {}

    unrecognized = []
    exceptions = []

    with open(path) as f:
        for line_no, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip():
                continue

            if line.strip().startswith("warning:"):
                continue  # e.g. the expected tohost/fromhost warning -- deliberately not using that mechanism

            m_exc = EXCEPTION_RE.search(line)
            if m_exc:
                exceptions.append((line_no, m_exc.group(1), line))
                continue

            m_reg = REG_RE.search(line)
            if m_reg:
                pc = int(m_reg.group(1), 16)
                instr = int(m_reg.group(2), 16)
                rd = int(m_reg.group(3))
                val = int(m_reg.group(4), 16) & 0xFFFFFFFF
                reg_by_line_context.setdefault((pc, instr), []).append((rd, val))
                continue

            m_mem = MEM_RE.search(line)
            if m_mem:
                pc = int(m_mem.group(1), 16)
                instr = int(m_mem.group(2), 16)
                addr = int(m_mem.group(3), 16)
                val = int(m_mem.group(4), 16) & 0xFFFFFFFF
                mem_by_line_context.setdefault((pc, instr), []).append((addr, val))
                continue

            m_bare = BARE_COMMIT_RE.search(line)
            if m_bare:
                continue  # no new info beyond the paired PLAIN_RE line

            m_plain = PLAIN_RE.search(line)
            if m_plain:
                pc = int(m_plain.group(1), 16)
                instr = int(m_plain.group(2), 16)
                records_by_pc_seq.append(dict(pc=pc & 0xFFFFFFFF, instr=instr & 0xFFFFFFFF))
                continue

            unrecognized.append((line_no, line))

    # Correlate: walk the PC sequence in order, pulling matching reg/mem
    # commits by (pc, instr) key. This assumes no single (pc, instr) pair
    # is legitimately re-visited with different side effects between two
    # consecutive appearances in a way that would confuse FIFO consumption
    # -- true here since consumption happens in strict appearance order and
    # a loop revisiting the same PC produces its commits in the same
    # relative order they were queued.
    records = []
    for idx, rec in enumerate(records_by_pc_seq):
        key = (rec["pc"], rec["instr"])
        reg = reg_by_line_context[key].pop(0) if reg_by_line_context.get(key) else None
        mem = mem_by_line_context[key].pop(0) if mem_by_line_context.get(key) else None
        records.append(dict(idx=idx, pc=rec["pc"], instr=rec["instr"], reg=reg, mem=mem))

    return records, unrecognized, exceptions


def truncate_at_self_loop(records, repeat_threshold=3):
    """Cut the record list once the PC has repeated `repeat_threshold`
    times in a row -- this is how the deliberate infinite self-branch
    epilogue is detected without needing Spike to cleanly exit."""
    if not records:
        return records
    run_pc = records[0]["pc"]
    run_len = 1
    for i in range(1, len(records)):
        if records[i]["pc"] == run_pc:
            run_len += 1
            if run_len >= repeat_threshold:
                return records[: i - repeat_threshold + 2]
        else:
            run_pc = records[i]["pc"]
            run_len = 1
    return records


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "spike_trace.log"
    records, unrecognized, exceptions = parse_spike_log(path)
    print(f"Parsed {len(records)} retirement records from {path}")
    if exceptions:
        print(f"WARNING: {len(exceptions)} exception lines encountered:")
        for ln, kind, raw in exceptions[:5]:
            print(f"  line {ln}: {kind}")
    if unrecognized:
        print(f"WARNING: {len(unrecognized)} unrecognized lines (first 5 shown):")
        for ln, raw in unrecognized[:5]:
            print(f"  line {ln}: {raw}")
    truncated = truncate_at_self_loop(records)
    print(f"After truncating the trailing self-loop: {len(truncated)} records")