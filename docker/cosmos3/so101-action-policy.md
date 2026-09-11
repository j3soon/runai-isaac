# Cosmos 3 SO-101 Action-Policy Post-Training

An end-to-end record of post-training [Cosmos 3](./README.md) into an SO-101 vial-to-rack
action policy and evaluating it closed-loop in the
[Sim-to-Real SO-101 Workshop](../sim-to-real-so101-workshop/README.md) environment.

The headline result is negative — the policy does not complete the task — but the path to
that result contains several traps that are easy to fall into and hard to detect, so the
failures are documented alongside the numbers.

## What was trained

Action policy, not a world model. `mode="wam"` (Cosmos 3's world-action mode) with
`action_space="joint_pos"`, training the generation and action heads
(`moe_gen`, `time_embedder`, `vae2llm`, `llm2vae`, `action2llm`, `llm2action`,
`action_modality_embed`). Upstream's dedicated world model is a separate recipe,
`action_fd_droid_posttrain` with `mode="forward_dynamics"`, which is **not** used here.

| | |
| --- | --- |
| Dataset | `sreetz-nv/so101_teleop_vials_rack_left_sim_and_real`, LeRobot v3.0 |
| Training set | 75 simulation episodes, 18,250 frames, **15,211 windows** (~11 min of robot data) |
| Action | 6D absolute joint position, `[Joint(5), Gripper]` |
| Observation | `concat_view` 256x512 (third-person left, wrist right), chunk 16 at 30fps |
| Base | `Cosmos3-Edge` (3.86B) or `Cosmos3-Edge-Policy-DROID` |
| Hardware | 8x L40 46GB, one node, ~2.2 h for 3600 iterations |

## The serving contract is the biggest trap

**A recipe must be trained for the server that will serve it.** The two action policy
servers have incompatible, undocumented contracts:

| server | proprioceptive state | action normalization |
| --- | --- | --- |
| `action_policy_server_libero` | **none** | `--action-normalization` + `--action-stats-path` |
| `action_policy_server_robolab` | `--use-state` (prepends state as action row 0) | **none** — assumes raw actions |

Upstream's recipes each match exactly one server: the DROID recipe pairs `use_state=True`
with `action_normalization=None`; the LIBERO recipe uses neither state nor raw actions.

Combining `use_state=True` **and** `action_normalization="quantile"` produces a checkpoint
that **neither server can serve**. It trains cleanly and its loss curve looks healthy, but
at inference the libero server silently drops the state, and the robolab server returns
normalized values without denormalizing (off by ~50x). Both produce plausible-looking
actions in roughly the right numeric range, and both are useless.

The two self-consistent pairings are:

- `use_state=False` + `action_normalization="quantile"` -> `action_policy_server_libero`
- `use_state=True` + `action_normalization=None` -> `action_policy_server_robolab`

`action_policy_server_robolab` additionally hardcodes DROID's embodiment: it validates
`observation/joint_position` as exactly **7** joints and applies `1.0 - x` to the gripper
(a 0..1 convention). SO-101 has 5 joints and records raw servo units, where that flip goes
negative. Both are patchable — `action_dim - 1` reproduces 7 for DROID, so the joint-count
change is behaviour-preserving.

### Proprioception is effectively unavailable through either server

Both attempts to serve a `use_state=True` checkpoint failed, for different reasons, and
neither is a one-line fix:

| checkpoint | server | mean err/std | cause |
| --- | --- | ---: | --- |
| state + quantile | robolab + output denorm patch | 1.43 | training normalizes the **whole** action tensor *including* the prepended state row (`base_dataset.py`), so the model expects a normalized state at row 0; the server feeds raw joint values there |
| state + raw actions | robolab | 0.85 | joints fine (0.24-0.43); the **gripper** alone is wrong (3.62) because `Gripper()` assumes a 0..1 convention while SO-101 records 1..52 servo units |

Serving a state-conditioned SO-101 policy therefore needs the server to normalize the
state row on input *and* rescale the gripper, on top of the joint-count and gripper-flip
patches.

The input-normalization half was then built and tested: `action_policy_server_libero` was
patched to accept a `state` field, normalize it with the same q01/q99 used for actions
(`(x - min)/range * 2 - 1`), prepend it as action row 0, and strip that row from the
prediction. The patch is correct -- the model returns `chunk + 1` rows, confirmed because
stripping row 0 leaves exactly the 16 the client expects -- and it moves the gate from
~1.5 to **0.89**. That is a large improvement and still a FAIL.

| serving configuration | mean err/std |
| --- | ---: |
| state + quantile -> libero, state dropped | ~1.5 |
| state + quantile -> libero, **state normalized and prepended** | **0.89** |
| `use_state=False` + quantile -> libero | **0.08** |

So serving is no longer what blocks proprioception. The state-conditioned checkpoints are
simply worse predictors than the state-free ones -- 0.89 against 0.08 on the same server,
same data, same iteration count. Per-joint, the gripper is fine (0.38) while every arm
joint sits at 0.90-1.22, i.e. no better than guessing the mean.

`use_state=False` therefore remains the only configuration that both serves correctly and
predicts well, but that is now a statement about these checkpoints rather than about the
server.

This matters because the GR00T baseline that reaches ~70% on this dataset **does** consume
proprioception, so this is a known gap between the two recipes rather than a settled
comparison.

## Always gate on offline action accuracy first

Closed-loop evaluation cannot distinguish "the model did not learn" from "the serving path
is wrong": both give a flat 0% that reads like a model result. An offline check separates
them in minutes.

Feed real dataset observations, compare the predicted chunk against the recorded actions,
and normalize by each joint's spread in the data:

| serving configuration | mean err/std | reading |
| --- | ---: | --- |
| `use_state=True` + quantile, served by **libero** (state dropped) | ~1.5 | worse than predicting the mean |
| `use_state=True` + quantile, served by **robolab** (not denormalized) | 3.18 | badly wrong scale |
| `use_state=False` + quantile, served by **libero** (matched) | **0.08** | predictions track ground truth |

A ratio below ~0.6 means the policy is genuinely predicting; above ~1.0 means it is no
better than guessing the dataset mean, which is a serving fault, not a training one.

Running this gate before any episodes would have saved ~150 closed-loop episodes that only
measured a broken serving path.

## Closed-loop results

Evaluated with `lerobot_eval` on `Lerobot-So101-Teleop-Vials-To-Rack-Eval`, 30 episodes,
against the 0/30 random and hold baselines documented in the
[workshop guide](../sim-to-real-so101-workshop/README.md).

| variant | init | data | chunk | success |
| --- | --- | --- | ---: | ---: |
| `ns_base` | `Cosmos3-Edge` | sim only | 16 | 0/30 |
| `ns_droid` | `Cosmos3-Edge-Policy-DROID` | sim only | 16 | 0/30 |
| `ns_simreal` | `Cosmos3-Edge-Policy-DROID` | sim + 5 real | 16 | 0/30 |
| `ns_chunk32` | `Cosmos3-Edge-Policy-DROID` | sim only | 32 | 0/30 |

Two eval-time hypotheses were tested and eliminated:

- **Distribution mismatch** — training data comes from the `-DR` env (randomized robot
  colour, lighting, mat) while `-Eval` fixes the robot orange with no randomization.
  Re-running on `-DR-Eval` also gives 0/30.
- **Open-loop chunk too long** — horizon 16 at 30fps executes 0.53s blind per query.
  Horizon 4 also gives 0/30.

Environment frames were also verified well-formed (`dtype=uint8`, min 0, max 243), ruling
out an image-conversion fault.

## Why it fails: control, not conditioning

Logging every predicted chunk during a rollout and comparing its spread against the
demonstrations:

| joint | demo std | policy std | ratio |
| --- | ---: | ---: | ---: |
| shoulder_pan | 10.69 | 5.78 | 0.54 |
| shoulder_lift | 29.79 | 19.00 | 0.64 |
| elbow_flex | 23.65 | 7.54 | 0.32 |
| wrist_flex | 36.31 | 5.97 | **0.16** |
| wrist_roll | 4.72 | 2.58 | 0.55 |
| gripper | 12.00 | 4.84 | 0.40 |

Mean ratio **0.435** — the policy responds to its observations rather than replaying a
canned trajectory. But the trajectory converges:

```
first chunks: [-5.2, -57.1, 51.7, 48.1, -55.8, 18.4]   varied
last chunks:  [18.9, -22.9, 40.8, 37.0, -48.0, 34.2]
              [18.9, -22.9, 40.9, 37.4, -48.0, 34.3]   identical to ~0.5 units
              [18.6, -23.4, 41.4, 37.0, -48.1, 34.2]
```

The policy moves early, drifts off the demonstration manifold, then settles into a fixed
pose and stays there for the rest of the 450-step episode. `wrist_flex` — the joint most
needed for the final placement — is the most suppressed at 0.16.

This is behavioural-cloning collapse under covariate shift, not a plumbing fault: serving
is verified correct, observations are well-formed, and the policy is demonstrably
observation-dependent. A useful corroboration of the partial-credit signal: a **random**
policy sampling within the demonstrated joint range grasps the vial 12 times in 30
episodes, while the trained policy grasps **0** times — accurate on-distribution, inert
once off it.

## Practical conclusion

**The dataset is sufficient.** Isaac GR00T N1.6 and N1.7 have been trained on this same
dataset and reach roughly **70% simulation success rate**. So the flat 0/30 here is a
defect in this Cosmos 3 recipe, not a property of the data, and any conclusion about
"too few demonstrations" is contradicted by that result.

An earlier revision of this page concluded the opposite. That was wrong: low training loss
plus zero success plus a converging trajectory is *consistent with* data scarcity, but it
is equally consistent with a recipe fault, and a working reference on the same data
distinguishes them. Do not infer a data limit without one.

### The GR00T baseline, measured here

Reproduced on this cluster rather than taken from the report: the published GR00T finetune
of this dataset scores **104/150 (69.3%)** on `-Eval` with upstream's exact evaluation
configuration and the sim-only checkpoint upstream names, measured over three independent
50-episode runs. The sim+real variant of the same finetune scores 5/10, and 11/30 (36.7%)
with the camera map inverted and the prompt wrong.
See the
[workshop guide](../sim-to-real-so101-workshop/README.md#reference-point-the-published-groot-finetune).

So the reference is not merely "better than this recipe" — it is close to saturating the
evaluation these variants score 0/30 on, using the same data and the same environment.

That reference also settles the training-budget question. The checkpoint's own
`experiment_cfg` records `max_steps: 10000` at `global_batch_size: 32`, which is **21
epochs** over the 15,211 windows. The Cosmos 3 runs here did 3600 iterations at global
batch 128, or **30 epochs** — more, not less. An earlier revision of this page claimed the
recipe was under-trained by ~2.8x, derived from a generic `20000 x 64` figure in Cosmos 3's
own guide rather than from this task's reference. It was wrong. Read the budget off the
reference checkpoint, not off a framework-level example.

### Where this recipe differs from the GR00T baseline

Candidates, roughly in order of suspicion:

- **Proprioception.** The workshop's GR00T client sends `state.single_arm` and
  `state.gripper` every step, and GR00T conditions on it. The variants evaluated at 0/30
  were trained `use_state=False` — no proprioceptive input at all — because that is the
  only pairing the libero server supports. The drift-into-a-fixed-pose failure is exactly
  what losing state would cause. The `use_state=True` + raw-action pairing served by
  `action_policy_server_robolab` is the like-for-like comparison.
- **View handling.** This recipe resizes each 640x480 camera to 256x256 and concatenates
  to 256x512, which squashes a 4:3 image to 1:1. GR00T consumes the cameras separately at
  their native aspect.
- **Objective.** `mode="wam"` trains vision generation alongside actions, so part of the
  capacity and gradient budget goes to predicting pixels. GR00T optimizes actions only.
- **Action horizon and control rate**, which interact with the 30fps recording.

### What would not help

More epochs. The reference reaches 69.3% in 21 epochs; these runs did 30 and scored
zero, training loss fell cleanly to ~0.6 in every variant, and both eval-time hypotheses
(distribution match, shorter horizon) were eliminated. The failure is in what the policy is
conditioned on and what it optimizes, not in how long it trained.

This is now measured rather than argued. Four runs at GR00T-comparable budgets were trained to
10,000 iterations and evaluated closed-loop at `iter_000010000`, 30 episodes each:

| run | init | success | grasps |
| --- | --- | ---: | ---: |
| `long` | `Cosmos3-Edge` | 0/30 | 0 |
| `longdroid` | `Cosmos3-Edge-Policy-DROID` | 0/30 | 0 |
| `longwrist` | wrist-view variant | 0/30 | 0 |
| `longres` | resolution variant | 0/30 | 0 |

Same 0/30 and the same **zero grasps** as the 3600-iteration runs. Nearly tripling the
iteration count, from 30 to 83 epochs over the 15,211 windows, changes nothing — while the
GR00T reference reaches 69.3% in 21 epochs on the same data. Training budget is not the
constraint.

All four trained with `use_state=False` + `action_normalization="quantile"` and were served by
`action_policy_server_libero`, the pairing that gates at 0.08, so this is a policy result and
not a serving artifact. The server logs confirm `normalization=quantile` with the SO-101
q01/q99 stats loaded, `chunk_length=16`, `raw_action_dim=6`.

### Method notes worth reusing

- **Validate the harness with a known-good policy before trusting any number from it.** Two
  full rounds of Cosmos 3 evaluation here measured an eval configuration, not a policy. A
  reference checkpoint costs one job and one hour.
- **Test the hypothesis, do not reason about it.** A confident theory that the robolab
  server returned 17 action rows with state at index 0 turned out to be false — the server
  returns 16. Stripping a row "just in case" would have silently corrupted every result.
- **Compare against a floor.** 0/30 only means something next to a random baseline that
  also scores 0/30 but grasps 12 times.
