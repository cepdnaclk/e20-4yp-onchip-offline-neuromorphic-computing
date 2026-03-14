## Plan: Repository Reorganization + FPU Scope Lock

Directly reorganize tooling and firmware-related code into workflow-based structure, clean CPU non-Verilog artifacts, keep fixed-point custom-learning architecture (no RV32F implementation), and verify FU behavior with targeted RTL tests. This minimizes ambiguity for backprop use while preserving RTL source locations.

**Steps**
1. Phase 1 - Baseline Inventory and Freeze
1. Capture a pre-change inventory of all paths under tools, RISC_V/c_program, RISC_V/snn_tests, firmware, code, and CPU non-Verilog artifact files so every move is traceable.
2. Identify all hardcoded path references in docs/scripts that currently point to old locations, especially build/test scripts and analysis tools. This step blocks all later move steps.

2. Phase 2 - Tools Folder Hard Move (workflow taxonomy)
1. Create workflow folders under tools and move scripts by purpose: data prep, inference, learning, weight management, verification, utilities.
2. Move existing subfolders (decoder, spike_gen, sim_runner) into the workflow layout where applicable, preserving script names when possible to reduce downstream edits.
3. Move tool-generated artifact files (csv/txt logs) into dedicated data/reports locations inside tools so source scripts and outputs are separated.
4. Update relative paths inside moved scripts to use repo-root-safe path resolution (Path(__file__) anchored), not cwd assumptions.
5. Update command docs referencing moved tool scripts.

3. Phase 3 - C/Assembly Area Hard Move
1. Consolidate C/assembly content from RISC_V/c_program, RISC_V/snn_tests, firmware, and code into a single coherent firmware layout (startup, src, tests/examples, docs, data/reports, scripts).
2. Remove duplicate startup/linker definitions by selecting one authoritative crt0.s + linker script location and updating all compile commands to point there.
3. Move test/demo/training C files into test/example buckets and separate report/data outputs from source.
4. Update script paths in PowerShell/bash wrappers and all docs that currently say cd into old directories.
5. Keep behavior unchanged: this phase is structural only, no algorithmic change in C code.

4. Phase 4 - CPU Folder Non-Verilog Cleanup (artifacts only)
1. Keep all Verilog/SystemVerilog sources and benches in place.
2. Remove or relocate generated artifacts from CPU folder: vcd, vvp, out/bin logs, sim directories (daidir, csrc), debug dumps.
3. Add/normalize ignore patterns so these artifacts do not reappear in git status.

5. Phase 5 - Git Ignore Normalization
1. Confirm .venv ignore is present (it already exists in current .gitignore) and keep it in the Python section for consistency.
2. Extend ignore patterns to match new build/report/output locations after reorganization.

6. Phase 6 - FU/F-extension Technical Direction
1. Treat current architecture as RV32IM + custom neuromorphic instructions, not RV32F entirely ,inly neccessary insturction for the custom backprop oparations.
2. Validate FU/backprop path correctness using existing custom-unit and CPU benchmark testbenches.

4. Define minimal instruction contract for your backprop firmware: integer control/memory ops + custom instructions only.

7. Phase 7 - Verification and Sign-off
1. Run targeted RTL tests for custom instruction flow and benchmark path; compare key outputs against current expected values.
2. Run path-sanity checks: all docs/scripts compile and run from new folder layout without broken references.
3. Run repository-wide grep for legacy paths and fix remaining stragglers.

**Relevant files**
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/tools](tools) - primary script set to regroup by workflow.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/RISC_V/c_program](RISC_V/c_program) - mixed C sources, reports, and build artifacts to split.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/RISC_V/snn_tests](RISC_V/snn_tests) - startup/linker duplicates and C test programs to consolidate.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/firmware](firmware) - target consolidated firmware root.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/code](code) - assembly example inputs to relocate.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/RISC_V/CPU](RISC_V/CPU) - artifact cleanup only; keep Verilog sources unchanged.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/.gitignore](.gitignore) - normalize .venv and new output ignore rules.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/TESTING.md](TESTING.md) - update moved firmware/tool commands.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/IMPORTANT_COMMANDS.md](IMPORTANT_COMMANDS.md) - update legacy paths.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/VERIFICATION_GUIDE.md](VERIFICATION_GUIDE.md) - update command paths.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/RISC_V/README.md](RISC_V/README.md) - align ISA wording with custom fixed-point scope.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/custom_rv32im/core.py](custom_rv32im/core.py) - confirm compiler ISA flags remain non-F.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/RISC_V/extention/customUnit_tb.v](RISC_V/extention/customUnit_tb.v) - FU path validation.
- [/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/RISC_V/CPU/CPU_tb_benchmark.v](RISC_V/CPU/CPU_tb_benchmark.v) - end-to-end custom learning benchmark.

**Verification**
1. Structural verification: list/match moved files against pre-change inventory (no unexpected drops).
2. Reference verification: search for legacy paths like RISC_V/c_program and old tool script paths in md/sh/ps1/py/v files and resolve all intentional references.
3. Build command verification: run at least one compile/sim flow for firmware path and one for CPU custom-unit benchmark from updated locations.
4. FU correctness verification: run custom unit and CPU benchmark testbenches and compare expected weight-update behavior to current known-good outputs.
5. ISA scope verification: confirm no introduced RV32F compiler flags/instruction decode paths/register-file changes.

**Decisions**
- Reorganization strategy: direct hard move (no compatibility wrapper phase).
- Tools taxonomy: workflow-based grouping.
- C scope: include RISC_V/c_program, RISC_V/snn_tests, firmware, and code.
- CPU scope: artifact cleanup only; do not reorganize Verilog sources.
- Floating-point scope: keep fixed-point custom approach; do not implement RV32F in this cycle.
- .venv: already present in ignore list; normalize placement rather than adding duplicate entry.

**Further Considerations**
1. If you later want partial RV32F, treat it as a separate project phase with explicit compliance target (custom subset vs standard RV32F), because it requires ISA/decode/register/CSR/test expansion beyond this structural task.
2. For the hard move, expect one concentrated follow-up pass over docs/scripts to repair paths; this is normal and included in verification scope.
