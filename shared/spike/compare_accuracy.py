"""
compare_accuracy.py

Aligns Spike's trace and the SV core's commit log (both already truncated
at their trailing infinite self-loop) and reports an accuracy metric.

Handles one structural wrinkle: the SV core resets to PC 0x00000000, while
Spike's ELF entry point is 0x80000000 (standard RISC-V convention) -- so
raw PC values are never expected to match, and PC-relative results
(auipc, jal/jalr return address) will legitimately differ by exactly that
same 0x80000000 offset. See the comparison logic below for how both are
handled without needing to know per-instruction identity.

Usage:
    python3 compare_accuracy.py spike_trace.log commit_log.txt
"""

import sys

from spike_log_parser import parse_spike_log, truncate_at_self_loop as trunc_spike
from sv_log_parser import parse_sv_log, truncate_at_self_loop as trunc_sv

BASE_OFFSET = 0x80000000
MASK32 = 0xFFFFFFFF


def values_match_allowing_pc_base(sv_val, spike_val):
    """True if the values match directly, OR differ by exactly the
    SV<->Spike reset-vector offset in either direction -- covers
    PC-derived register results (auipc, jal/jalr link register) without
    needing to know which instruction produced them."""
    if sv_val == spike_val:
        return True
    if (sv_val + BASE_OFFSET) & MASK32 == spike_val:
        return True
    if sv_val == (spike_val + BASE_OFFSET) & MASK32:
        return True
    return False


def trim_boot_stub(records, entry_addr=0x80000000):
    """Spike always runs its own small boot stub (auipc/addi/csrr/lw/jr)
    before jumping to the ELF entry point --
    discard everything before the first record at entry_addr, rather than
    assuming a fixed instruction count that could vary by Spike
    version/config."""
    for i, r in enumerate(records):
        if r["pc"] == entry_addr:
            return records[i:]
    return records  # entry_addr never seen -- leave as-is, something else is wrong


def compare(spike_path, sv_path):
    spike_records_raw, spike_unrec, spike_exc = parse_spike_log(spike_path)
    sv_records_raw, sv_unrec = parse_sv_log(sv_path)

    spike_records_trimmed = trim_boot_stub(spike_records_raw)
    spike_records = trunc_spike(spike_records_trimmed)
    sv_records = trunc_sv(sv_records_raw)

    print(f"Spike: {len(spike_records_raw)} raw records, "
          f"{len(spike_records_raw) - len(spike_records_trimmed)} discarded as boot stub, "
          f"{len(spike_records)} after truncating the trailing self-loop")
    print(f"SV:    {len(sv_records_raw)} raw records, {len(sv_records)} after "
          f"truncating the trailing self-loop")

    if spike_unrec:
        print(f"\nWARNING: Spike log had {len(spike_unrec)} unrecognized lines "
              f"(first 3): ")
        for ln, raw in spike_unrec[:3]:
            print(f"  line {ln}: {raw}")
        print("  If these look like memory-write commit lines, the MEM_RE regex "
              "in spike_log_parser.py needs adjusting -- paste these lines back "
              "and it can be fixed directly.")
    if spike_exc:
        print(f"\nWARNING: Spike log had {len(spike_exc)} exception lines -- "
              f"the program likely hit something Spike couldn't execute. "
              f"First: {spike_exc[0]}")
    if sv_unrec:
        print(f"\nWARNING: SV log had {len(sv_unrec)} unrecognized lines "
              f"(first 3):")
        for ln, raw in sv_unrec[:3]:
            print(f"  line {ln}: {raw}")

    if len(spike_records) != len(sv_records):
        print(f"\nNOTE: retirement counts differ ({len(spike_records)} vs "
              f"{len(sv_records)}) -- comparing up to the shorter length. "
              f"A length mismatch on its own often means the two simulators "
              f"diverged on a branch outcome partway through and never "
              f"reconverged (each retired a different number of instructions "
              f"before settling into ITS OWN self-loop).")

    n = min(len(spike_records), len(sv_records))
    if n == 0:
        print("\nNo comparable records -- can't compute accuracy.")
        return

    spike_base_pc = spike_records[0]["pc"]
    sv_base_pc = sv_records[0]["pc"]

    total = 0
    passed = 0
    mismatches = []

    for i in range(n):
        sp, sv = spike_records[i], sv_records[i]
        total += 1
        ok = True
        reasons = []

        sp_delta = (sp["pc"] - spike_base_pc) & MASK32
        sv_delta = (sv["pc"] - sv_base_pc) & MASK32
        if sp_delta != sv_delta:
            ok = False
            reasons.append(f"pc_delta mismatch: spike={sp_delta:#x} sv={sv_delta:#x}")

        sp_reg, sv_reg = sp["reg"], sv["reg"]
        # Spike omits the register-commit portion of its log entirely for
        # x0 destinations (no architectural effect: an srli writing x0
        # produces no "x0 0x..." commit line at all). The SV testbench logs
        # every reg_write-flagged retirement
        # regardless of destination, since reg_write is asserted by the
        # control unit independent of which register it targets. Both are
        # correct -- x0 stays 0 either way -- so a "sv has an x0 entry,
        # spike has none" pairing is normalized here rather than flagged.
        if sp_reg is None and sv_reg is not None and sv_reg[0] == 0:
            sv_reg = None
        if sv_reg is None and sp_reg is not None and sp_reg[0] == 0:
            sp_reg = None

        if (sp_reg is None) != (sv_reg is None):
            ok = False
            reasons.append(f"reg presence mismatch: spike={sp_reg} sv={sv_reg}")
        elif sp_reg is not None:
            sp_rd, sp_val = sp_reg
            sv_rd, sv_val = sv_reg
            # x0 is architecturally always 0 regardless of what the
            # hardware's internal write-back bus happened to compute --
            # normalize both sides before comparing so a harmless internal
            # difference on a discarded x0 write doesn't get reported as a
            # mismatch.
            if sp_rd == 0:
                sp_val = 0
            if sv_rd == 0:
                sv_val = 0
            if sp_rd != sv_rd:
                ok = False
                reasons.append(f"reg rd mismatch: spike=x{sp_rd} sv=x{sv_rd}")
            elif not values_match_allowing_pc_base(sv_val, sp_val):
                ok = False
                reasons.append(f"reg value mismatch: spike=0x{sp_val:x} sv=0x{sv_val:x}")

        sp_mem, sv_mem = sp["mem"], sv["mem"]
        if (sp_mem is None) != (sv_mem is None):
            ok = False
            reasons.append(f"mem presence mismatch: spike={sp_mem} sv={sv_mem}")
        elif sp_mem is not None:
            sp_addr, sp_val = sp_mem
            sv_addr, sv_val = sv_mem
            # Addresses are now PC-relative (auipc-derived base), so they
            # legitimately differ by the same reset-vector offset as
            # register values do -- same fallback, applied to the address
            # only. The stored value itself is never PC-derived and must
            # match exactly.
            addr_ok = values_match_allowing_pc_base(sv_addr, sp_addr)
            val_ok = sv_val == sp_val
            if not (addr_ok and val_ok):
                ok = False
                reasons.append(
                    f"mem mismatch: spike=(addr=0x{sp_addr:x},val=0x{sp_val:x}) "
                    f"sv=(addr=0x{sv_addr:x},val=0x{sv_val:x})"
                )

        if ok:
            passed += 1
        elif len(mismatches) < 15:
            mismatches.append(dict(idx=i, spike=sp, sv=sv, reasons=reasons))

    print(f"\n{'=' * 60}")
    print(f"ACCURACY: {passed}/{total} ({passed / total * 100:.2f}%) instructions matched")
    print(f"{'=' * 60}")

    if mismatches:
        print(f"\nFirst {len(mismatches)} mismatches:")
        for m in mismatches:
            print(f"\n  retirement #{m['idx']}:")
            print(f"    spike: pc=0x{m['spike']['pc']:x} instr=0x{m['spike']['instr']:08x} "
                  f"reg={m['spike']['reg']} mem={m['spike']['mem']}")
            print(f"    sv:    pc=0x{m['sv']['pc']:x} reg={m['sv']['reg']} mem={m['sv']['mem']}")
            for r in m["reasons"]:
                print(f"    -> {r}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 compare_accuracy.py <spike_trace.log> <commit_log.txt>")
        sys.exit(1)
    compare(sys.argv[1], sys.argv[2])