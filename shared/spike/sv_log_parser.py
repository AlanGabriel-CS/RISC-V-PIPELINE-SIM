"""
sv_log_parser.py

Parses commit_log.txt (produced by tb_commit_log.sv) into the same
canonical record format as spike_log_parser.py:

    [{"idx": 0, "pc": 0x80000000, "reg": (rd, value) | None,
      "mem": (addr, value) | None}, ...]

Log format written by the testbench:
    PC  <idx> <pc_hex>
    REG <idx> <rd_decimal> <value_hex>
    MEM <idx> <addr_hex> <value_hex>

Note the SV core's own reset vector is 0x00000000, not Spike's
0x80000000 -- the two traces' PCs won't line up numerically even when the
underlying instruction stream is identical. compare_accuracy.py handles
this by comparing PC *deltas* (was this instruction's target the same
number of words forward/backward from where it started) rather than raw
absolute addresses.
"""

import re
import sys

PC_RE = re.compile(r"^PC\s+(\d+)\s+([0-9a-fA-F]+)$")
REG_RE = re.compile(r"^REG\s+(\d+)\s+(\d+)\s+([0-9a-fA-F]+)$")
MEM_RE = re.compile(r"^MEM\s+(\d+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)$")


def parse_sv_log(path):
    pc_by_idx = {}
    reg_by_idx = {}
    mem_by_idx = {}
    unrecognized = []

    with open(path) as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            m = PC_RE.match(line)
            if m:
                idx, pc = int(m.group(1)), int(m.group(2), 16)
                pc_by_idx[idx] = pc
                continue
            m = REG_RE.match(line)
            if m:
                idx, rd, val = int(m.group(1)), int(m.group(2)), int(m.group(3), 16)
                reg_by_idx[idx] = (rd, val & 0xFFFFFFFF)
                continue
            m = MEM_RE.match(line)
            if m:
                idx, addr, val = int(m.group(1)), int(m.group(2), 16), int(m.group(3), 16)
                mem_by_idx[idx] = (addr, val & 0xFFFFFFFF)
                continue
            unrecognized.append((line_no, line))

    records = []
    for idx in sorted(pc_by_idx):
        records.append(dict(
            idx=idx, pc=pc_by_idx[idx],
            reg=reg_by_idx.get(idx), mem=mem_by_idx.get(idx),
        ))
    return records, unrecognized


def truncate_at_self_loop(records, repeat_threshold=3):
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
    path = sys.argv[1] if len(sys.argv) > 1 else "commit_log.txt"
    records, unrecognized = parse_sv_log(path)
    print(f"Parsed {len(records)} retirement records from {path}")
    if unrecognized:
        print(f"WARNING: {len(unrecognized)} unrecognized lines (first 5 shown):")
        for ln, raw in unrecognized[:5]:
            print(f"  line {ln}: {raw}")
    truncated = truncate_at_self_loop(records)
    print(f"After truncating the trailing self-loop: {len(truncated)} records")