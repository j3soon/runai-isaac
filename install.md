# Install Run:ai

Follow [the self-hosted installation guide](https://run-ai-docs.nvidia.com/guides/self-hosted-installation/installation).

> Tested on Run:ai v2.20.29.

## Patches

### Workload Cannot Launch Successfully

Apply the following patch:

```
kubectl patch RunaiConfig runai -n runai --type=merge -p '{"spec":{"workload-controller":{"externalAuthUrlEnabled": false}}}'
```

> Details to be confirmed.

### Run:ai Dashboard Connection Issue

After launching some workloads, the Run:ai Dashboard may be unreachable. This is due to a known issue with the Ingress controller.

```sh
kubectl get pod -A | grep ingress
kubectl delete pods -n ingress-nginx ingress-nginx-controller-xxxxxxxxxx-xxxxx
kubectl logs -n ingress-nginx ingress-nginx-controller-xxxxxxxxxx-xxxxx | grep alert
```

Observe the following error:

```
[alert] 48#48: socketpair() failed while spawning "worker process" (24: No file descriptors available)
```

This issue commonly occurs on machines with many CPU cores, as the Ingress controller divides the total number of available file descriptors by the number of cores for each worker process. With many cores, this division results in too few file descriptors per worker, causing them to run out of available descriptors.

Apply the following patch:

```sh
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.config.worker-processes="4" \
  --set controller.config.worker-connections="10240" \
  --set controller.config.worker-rlimit-nofile="65536"
```

References:

- [Ingress-controller exited with fatal code 2 and cannot be respawned](https://github.com/kubernetes/ingress-nginx/issues/6141)
- [num of worker_processes set to max num of cores of cluster node with cgroups-v2](https://github.com/kubernetes/ingress-nginx/issues/11518)
- [关于nginx-ingress-controller中worker参数的差异分析](https://zhuanlan.zhihu.com/p/359700475)
- [追踪nginx ingress最大打开文件数问题](https://ieevee.com/tech/2019/09/29/ulimit.html)

## More Information

For more information on how to use Run:ai, please refer to the [Run:ai Documentation](https://run-ai-docs.nvidia.com/).
