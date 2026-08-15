# Policy Server and Client Workloads on Run:ai

Several applications here split a robot-policy evaluation into two processes: a **policy
server** holding the model, and a **client** running the simulator and stepping the
environment. They live in different images — the server needs the model framework, the
client needs Isaac Sim — so they cannot share a container, and a Run:ai standard workload
has no sidecar.

This page covers how the two halves talk and how to run them, from both the CLI and the
Run:ai UI.

## The pairs

| Client | Server | Protocol |
| --- | --- | --- |
| [RoboLab](../docker/robolab/README.md) `policies/cosmos3/run.py` | [Cosmos 3](../docker/cosmos3/README.md) `action_policy_server_robolab` | OpenPI WebSocket |
| [RoboLab](../docker/robolab/README.md) `policies/gr00t/run.py` | [Isaac GR00T N1.7](../docker/isaac-gr00t-n1.7/README.md) `run_gr00t_server.py` | GR00T ZMQ |
| [Sim-to-Real SO-101](../docker/sim-to-real-so101-workshop/README.md) `lerobot_eval` | GR00T-protocol server | GR00T ZMQ |

## How they communicate

### OpenPI WebSocket

Used by the RoboLab Cosmos 3 client (`openpi_client.websocket_client_policy`).

- Transport: `ws://<host>:<port>` over `websockets.sync.client`
- Serialization: `msgpack_numpy` — msgpack with a numpy extension, so arrays travel as
  binary rather than JSON lists
- Handshake: the server sends a metadata frame on connect, before any inference
- Request: one observation dict per call, `WebsocketClientPolicy.infer(obs) -> dict`
- Observation keys: `observation/image`, `observation/joint_position`,
  `observation/gripper_position`, `prompt`
- Response: `action`

The server prints its address on startup, which is the simplest place to read the pod IP:

```
Server accessible at: ws://192.168.32.185:8000/
```

### GR00T ZMQ

Used by the RoboLab GR00T client and by the SO-101 workshop's `lerobot_eval`.

- Transport: ZeroMQ `REQ`/`REP` on `tcp://<host>:5555`
- Serialization: msgpack, with ndarrays encoded as
  `{"__ndarray_class__": true, "as_npy": <npy bytes>}`
- Endpoints: `ping`, `reset`, `get_action`, `get_modality_config`, `kill`
- Observation: `{"video": {<camera>: img}, "state": {"single_arm": [5], "gripper": [1]},
  "language": {"annotation.human.task_description": str}}`, each leaf carrying
  `(batch=1, time=1)` leading dimensions
- Response: a `(action, info)` pair, where action is
  `{"single_arm": (1, T, 5), "gripper": (1, T, 1)}`

Because it is `REQ`/`REP`, the socket must stay strictly request-then-reply. A server that
raises without sending a reply wedges the socket, so always answer — with an error payload
if necessary.

`REQ`/`REP` also means the server handles **one client at a time**, with no queueing across
connections. Pointing several evaluation clients at a single server does not fan out; the
first proceeds and the rest sit until they time out. Observed with five concurrent clients
on one server: all five failed. Scale out by running one server per client, not one shared
server.

The server's output is **not deterministic**, and the client's `--seed` does not change that:
the policy runs in a separate process and a diffusion action head samples each chunk. Three
50-episode evaluations of one checkpoint at an identical seed scored 68%, 74% and 66%. Repeat
an evaluation before attributing a difference to a change you made.

The server also reports its expected inputs, so read them rather than guessing:
`get_modality_config` over the wire, or `experiment_cfg/conf.yaml` in the checkpoint. A
client whose camera names do not match gets `RuntimeError: Server error: '<key>'`; a client
whose names match but are **swapped** gets no error at all and a quietly worse score.

### Cosmos 3 HTTP

`action_policy_server_libero` serves plain HTTP instead: `GET /info`, `POST /predict`,
`POST /predict_batch`, JSON bodies with a base64 PNG image.

Prefer **`/predict_batch`**. `/predict` also renders the predicted rollout and returns it
as base64 PNGs, which makes responses ~1.4MB; `/predict_batch` skips the vision decode and
returns only actions. Response shape differs: `/predict` returns `action`, `/predict_batch`
returns `actions` (a list, one entry per item).

> This server has **no proprioceptive state input**. A recipe trained with `use_state=True`
> must be served by `action_policy_server_robolab`, which prepends the current joint state
> as row 0 of the action tensor. Serving such a model from the libero server silently
> produces plausible-looking but wrong actions — see [Cosmos 3](../docker/cosmos3/README.md).

## Networking: address the server by pod IP

Pods in the same project namespace reach each other directly on the pod network. **No
Kubernetes Service is required.** Every RoboLab policy client accepts `--remote-host` /
`--remote-port`, so nothing depends on a `localhost` default.

Two consequences worth planning around:

- The pod IP changes when the pod restarts, so read it at launch instead of hard-coding it.
  For anything long-lived, use a Service.
- The two workloads schedule independently, so the client must tolerate the server not
  being up yet. Poll before starting:

  ```sh
  until curl -sf -m 5 "$POLICY_URL/info" >/dev/null; do sleep 15; done
  ```

Running them as two workloads also avoids a real VRAM problem: a Cosmos 3 server plus a
RoboLab client measured 49.5GB together, above a `prod` L40's 46GB. Separate pods each get
their own GPU.

## Running from the CLI

```sh
export SSL_CERT_FILE=$HOME/.runai/certs/root-ca.crt

# 1. Server
runai training standard submit <name>-server --project <project> --node-pools prod \
  --image j3soon/runai-cosmos:3 --image-pull-policy Always \
  --gpu-devices-request 1 --large-shm \
  --nfs "server=<server>,path=<export>,mountpath=/mnt/nfs,readwrite" \
  --backoff-limit 0 --restart-policy Never \
  -e HF_HOME=/mnt/nfs/<user>/hf -e HF_TOKEN=<token> \
  --command -- bash -c 'export LD_LIBRARY_PATH=; cd /workspace; python -u -m cosmos_framework.scripts.action_policy_server_robolab --checkpoint-path nvidia/Cosmos3-Edge-Policy-DROID --format-prompt-as-json True --port 8000'

# 2. Read the IP from the server's log line "Server accessible at: ws://<ip>:8000/"
runai training standard logs <name>-server --project <project> | grep "Server accessible at"

# 3. Client, pointed at that IP
runai training standard submit <name>-client --project <project> --node-pools prod \
  --image j3soon/runai-robolab:0.3.0 --image-pull-policy Always \
  --gpu-devices-request 1 --large-shm --user-group-source fromTheImage \
  --nfs "server=<server>,path=<export>,mountpath=/mnt/nfs,readwrite" \
  --backoff-limit 0 --restart-policy Never \
  --command -- bash -c 'cd /workspace/robolab && /workspace/isaaclab/_isaac_sim/python.sh -u policies/cosmos3/run.py --task BananaInBowlTask --headless --num-envs 1 --remote-host <server-pod-ip> --remote-port 8000'
```

## Running from the Run:ai UI

The same split works entirely through the dashboard; the only ordering constraint is that
the server must exist before you can read its IP.

### 1. Submit the server workload

**Workloads → New Workload → Training**, then:

- Project: your project. Cluster: the GPU cluster.
- Environment → **Image URL**: `j3soon/runai-cosmos:3`
- Environment → Image pull policy: **Always pull the image from the registry**
- Runtime settings → **Command**:
  ```
  bash
  ```
  Runtime settings → **Arguments**:
  ```
  -c export LD_LIBRARY_PATH=; cd /workspace; python -u -m cosmos_framework.scripts.action_policy_server_robolab --checkpoint-path nvidia/Cosmos3-Edge-Policy-DROID --format-prompt-as-json True --port 8000
  ```
- Runtime settings → **Environment variables**: `HF_HOME=/mnt/nfs/<user>/hf`, and
  `HF_TOKEN` if the checkpoint or its guardrail models are gated
- Compute resource: a **1 GPU** resource, with the `prod` node pool
- Data source: the `<YOUR_LAB>-nfs` asset
- Security → UID/GID **From the image**

Leave the workload running; a policy server does not exit on its own.

### 2. Read the server's pod IP

Open the workload → **Logs**, and find:

```
Server accessible at: ws://192.168.32.185:8000/
```

That address is authoritative. The pod's IP is also shown under the workload's pod
details, but reading it from the server's own log avoids ambiguity when several pods exist.

### 3. Submit the client workload

**New Workload → Training** again:

- Environment → **Image URL**: `j3soon/runai-robolab:0.3.0`
- Runtime settings → **Command**: `bash`
- Runtime settings → **Arguments**, substituting the IP from step 2:
  ```
  -c mkdir -p /mnt/nfs/<user>/robolab-output && ln -sfn /mnt/nfs/<user>/robolab-output /workspace/robolab/output && cd /workspace/robolab && /workspace/isaaclab/_isaac_sim/python.sh -u policies/cosmos3/run.py --task BananaInBowlTask --headless --num-envs 1 --remote-host 192.168.32.185 --remote-port 8000
  ```
- Compute resource: a **1 GPU** resource, `prod` node pool
- Data source: the same NFS asset (the client writes results there)
- Security → UID/GID **From the image**

### 4. Confirm the link

The client's **Logs** should show `Connected to <ip>:8000.` and the server's **Logs**
should show inbound inference calls. If the client instead retries or errors, the usual
causes are: the server pod restarted and took a new IP, the server had not finished
loading its checkpoint, or the port in the client's arguments does not match the server's
`--port`.

### UI caveats

- Set **Backoff limit** to `0` and restart policy to `Never` for the client. An evaluation
  is not resumable, and a retry silently re-runs a finished job.
- The client writes under its package directory, which is container-local. Symlink it onto
  the NFS mount in the arguments (as above) or the results vanish with the pod.
- Stop the server workload when the client finishes. It holds a GPU indefinitely otherwise.
