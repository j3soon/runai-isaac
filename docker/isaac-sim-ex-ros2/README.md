# Isaac Sim (Extended) with ROS 2 Interactive Workspace

Build the docker image:

```sh
# Isaac Sim 5.1.0 + ROS 2 Jazzy
docker build -t j3soon/runai-isaac-sim-ex:5.1.0-ros2-jazzy -f docker/isaac-sim-ex-ros2/Dockerfile_5_1_0_ros2_jazzy .
docker push j3soon/runai-isaac-sim-ex:5.1.0-ros2-jazzy
# Isaac Sim 6.0.0 + ROS 2 Jazzy
docker build -t j3soon/runai-isaac-sim-ex:6.0.0-ros2-jazzy -f docker/isaac-sim-ex-ros2/Dockerfile_6_0_0_ros2_jazzy .
docker push j3soon/runai-isaac-sim-ex:6.0.0-ros2-jazzy
```

> **Note:** These images are self-contained (Ubuntu 24.04 base, not the official Isaac Sim container) and download Isaac Sim (~10 GB) during the build. Build time is significantly longer than the other variants. They include ROS 2 Jazzy.

## Run:ai

Refer to [Isaac Sim (Extended) Interactive Workspace](../isaac-sim-ex/README.md) for Run:ai setup instructions.

## Brev

TODO
