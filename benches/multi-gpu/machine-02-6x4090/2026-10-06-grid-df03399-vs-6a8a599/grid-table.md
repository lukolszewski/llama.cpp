| Workload | Context | Upstream llama.cpp | llama.cpp-multigpu | Improvement |
| --- | --- | --- | --- | --- |
| 1 slot - prefill | 5k | 1964 | 2954 | 1.50x (+990 t/s) |
| 1 slot - generate | 5k | 62.2 | 62.8 | 1.01x (+0.7 t/s) |
| 1 slot - prefill | 50k | 1728 | 7050 | 4.08x (+5322 t/s) |
| 1 slot - generate | 50k | 46.2 | 57.5 | 1.24x (+11.3 t/s) |
| 1 slot - prefill | 150k | 1039 | 8078 | 7.78x (+7040 t/s) |
| 1 slot - generate | 150k | 29.3 | 51.1 | 1.74x (+21.8 t/s) |
| 1 slot - prefill | 200k | 866 | 7601 | 8.77x (+6735 t/s) |
| 1 slot - generate | 200k | 25.1 | 50.1 | 2.00x (+25.0 t/s) |
| 1 slot - prefill | 250k | 744 | 7403 | 9.95x (+6659 t/s) |
| 1 slot - generate | 250k | 21.0 | 48.7 | 2.32x (+27.7 t/s) |
| 5 slots - concurrent - prefill | 5k | not run | 6596 (2781/slot) | n/a |
| 5 slots - concurrent - generate | 5k | not run | 245.6 (60.2/slot) | n/a |
| 5 slots - concurrent - prefill | 50k | not run | 8805 (6351/slot) | n/a |
| 5 slots - concurrent - generate | 50k | not run | 208.8 (55.1/slot) | n/a |
| 5 slots - concurrent - prefill | 150k | not run | 7932 (7139/slot) | n/a |
| 5 slots - concurrent - generate | 150k | not run | 136.1 (38.9/slot) | n/a |
| 5 slots - concurrent - prefill | 200k | not run | 7606 (6985/slot) | n/a |
| 5 slots - concurrent - generate | 200k | not run | 86.5 (26.0/slot) | n/a |
| 5 slots - concurrent - prefill | 250k | not run | 7241 (6836/slot) | n/a |
| 5 slots - concurrent - generate | 250k | not run | 101.1 (30.8/slot) | n/a |
