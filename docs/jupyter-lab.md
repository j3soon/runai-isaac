# Jupyter Lab

This page is part of the sample applications guide. Follow [README](../README.md) first and stop interactive workloads when finished.

For Docker images that have Jupyter Lab installed, you can skip adding the `/run.sh` scripts and directly launch Jupyter Lab by setting the following in your environment command:

```sh
jupyter lab
--allow-root --ip=0.0.0.0 --no-browser --notebook-dir=/ --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token=''
```
