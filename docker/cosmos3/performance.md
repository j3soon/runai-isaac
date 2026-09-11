# Cosmos 3 Action-Policy SFT Performance

Measured on Run:ai, `prod` node pool, **NVIDIA L40 (46GB, `sm_89`)**, image
`j3soon/runai-cosmos:3`. Node: 8x L40, 128 CPU, 1007GB RAM, PCIe (no NVLink).

Workload: `Cosmos3-Edge` (3.86B) action-policy SFT, `joint_pos` action space with
`use_state`, `concat_view` at 256x512, `chunk_length=16` (17-frame video window),
`activation_checkpointing=full`, bf16, FSDP. Steady-state iteration time is the mean of
the last iterations, excluding the first, which is dominated by `torch.compile` warmup
(~30-50s).

## Single GPU: batch-size sweep

`data_parallel_shard_degree=1`, so each rank holds the full model, optimizer, and EMA.

| per-rank batch | s/iter | samples/s | peak reserved |
| ---: | ---: | ---: | ---: |
| 2 | 0.41 | 4.88 | 39.8 GB |
| 4 | 0.59 | 6.76 | 39.2 GB |
| 8 | 0.96 | 8.32 | 39.4 GB |
| **16** | **1.70** | **9.41** | 39.8 GB |
| 32 | 4.34 | 7.37 | 41.2 GB |

Two things worth noting:

- **Memory is nearly flat in batch size** (39.2-41.2 GB across an 16x range). It is
  dominated by model + optimizer + EMA state, not activations, so batch size is close to
  free until it isn't.
- **Batch 32 regresses**, and not marginally: throughput drops ~22% below batch 16 while
  peak memory climbs to 41.2 GB of 46 GB. The same regression appears at 8 GPUs, so it is
  a property of the workload rather than of memory pressure on one card. Do not assume
  more batch is more throughput; measure it.

## 8 GPUs, one node

`data_parallel_shard_degree=8`, `data_parallel_replicate_degree=1`.

| per-rank batch | global batch | s/iter | samples/s | peak reserved |
| ---: | ---: | ---: | ---: | ---: |
| **16** | **128** | **2.15** | **59.5** | **11.0 GB** |
| 32 | 256 | 5.01 | 51.1 | 13.3 GB |
| 64 | 512 | 18.16 | 28.2 | 18.0 GB |

- **FSDP sharding cuts per-rank memory from 39.8 GB to 11.0 GB** at the same per-rank
  batch. Sizing the batch from a single-GPU run therefore understates what an 8-GPU run
  can hold by a wide margin — roughly 35 GB of headroom goes unused at batch 16.
- **Scaling efficiency is 79%** (59.5 vs 8 x 9.41 = 75.3 ideal). The ~21% loss is the
  FSDP all-gather over PCIe with no NVLink. That is the tax for choosing this GPU class,
  and it is the main argument for `Cosmos3-Edge` over `Cosmos3-Nano` here: Edge moves
  ~7.7 GB of bf16 parameters per step against Nano's ~31.5 GB.
- **Throughput falls off a cliff past batch 16**, and the fall is superlinear: doubling
  16 -> 32 costs 2.3x the iteration time, and 32 -> 64 costs a further 3.6x, while memory
  barely moves (11.0 -> 18.0 GB). That shape is consistent with attention over the packed
  sequence rather than with memory pressure: more samples per batch means a longer packed
  sequence, and attention is quadratic in it. `max_num_tokens_after_packing` caps the
  sequence, not the per-batch sample count, so it does not protect against this.

The practical rule: **batch 16 per rank**, and treat larger values as a regression to be
measured, not an optimization to be assumed. Memory headroom is not the binding constraint
here — 35 GB of the 46 GB card sits unused at the optimum.

## Edge vs Nano on the same 8x L40 node

Same recipe, same per-rank batch 16, only the model tier differs.

| model | params | s/iter | samples/s | peak reserved |
| --- | ---: | ---: | ---: | ---: |
| `Cosmos3-Edge` | 3.86B | 2.15 | 59.5 | 11.0 GB |
| `Cosmos3-Nano` | 15.75B | 6.77 | 18.9 | 35.6 GB |

**Nano does fit** on a 46GB L40 at shard degree 8, with ~10GB to spare — full activation
checkpointing and 8-way FSDP sharding are what make that possible. It is **3.15x slower**
than Edge, which is a smaller penalty than the 4x parameter ratio would suggest, because
the PCIe all-gather is partly overlapped.

So the Edge-over-Nano choice on this hardware is about throughput, not feasibility. At
3600 iterations that is ~2.2 h for Edge against ~6.8 h for Nano. Pick Edge for iteration
speed; Nano remains available when capacity matters more than turnaround.

## Practical sizing

For a ~15k-window dataset at global batch 128, one epoch is ~119 iterations, so a
30-epoch run is ~3600 iterations, about **2.2 hours** on one 8x L40 node.

`DeviceMonitor` defaults to `every_n=50`, so a short run reports no memory at all.
Set `trainer.callbacks.device_monitor.every_n=5` when the point of the run is to measure.
