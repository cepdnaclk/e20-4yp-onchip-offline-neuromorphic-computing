# Plan: Testbench CSV Export Refinement

## Completed Steps
1. Deleted unnecessary proxy python scripts (`export_unified_csv.py`, `read_smem_snapshot.py`, `compare_dumps.py`, `verify_spike_counts.py`).
2. Modified `mnist_infertest_tb.v` to natively dump the required CSV format (`smem_all_samples.csv`).
3. Set export schema to: `sample, ts, inp_0...inp_783, spike_h0...spike_h199, spike_o0...spike_o9, vmem_h0...vmem_h199, vmem_o0...vmem_o9`.
4. Extracted the true hardware 8-bit truncated LUT index for `vmem` (`uut.all_pre_spike[... + 23 -: 8]`) rather than using debug Q28 values.
5. Preserved input spike inputs (`ts_input_spikes`) until the dump phase (`S_WAIT_DONE`) to accurately reflect inputs in the CSV.

## Next Steps for Refinement
* Run full simulation with all 320 samples to ensure the correct output dimensions (rows = 320 * 16).
* Process the generated `smem_all_samples.csv` through the downstream ML backprop pipeline to test compatibility.
* Address any column alignment mismatches if the backprop training script expects a different column sequence.
* (Add any details to refine the testbench or data collection mechanism further)
