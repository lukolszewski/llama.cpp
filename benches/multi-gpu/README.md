# Benchmark result directories

Raw measurement output lives here, one directory per machine, so that `docs/multigpu/benchmarks.md`
can stay readable while the underlying data remains available.

| directory | machine | status |
| --- | --- | --- |
| `machine-01-7950x-6x3090/` | AMD Ryzen 9 7950X + 192 GB + 6 x RTX 3090 (constrained PCIe), Debian 12 | hardware record captured 2026-10-04, **grid measured 2026-10-05** (`2026-10-05-grid-…/`) |
| `machine-02-TBD/` | reserved, candidate: multiple RTX 4090 | does not exist until the machine is provisioned |
| `machine-03-TBD/` | reserved, candidate: multiple RTX 5090 (`sm_120`) | does not exist until the machine is provisioned |

Rules:

- **Never mix machines in one table.** A row belongs to exactly one machine directory; comparisons
  across machines are made by linking two tables, each with its own hardware record and its own
  upstream/patched commit pair.
- Every run directory keeps the tool output (`*.json`, `*.log`), the captured environment snapshot, and
  the exact command lines used.
- A file with no recorded upstream commit, patched commit, model + quant and config is not a result and
  should not be committed.

This layout follows the existing upstream convention (`benches/dgx-spark/`, `benches/nemotron/`,
`benches/mac-m2-ultra/`).

machine-01 holds the first measured grid (2026-10-05); machine-02/03 do not exist yet.
