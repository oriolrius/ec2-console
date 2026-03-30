# JupyterLab (UV)

JupyterLab project managed with [UV](https://docs.astral.sh/uv/).

## Quick start

```bash
cd ~/jupyterlab
./start.sh
```

Launches JupyterLab on `http://<public-ip>:8888` with no authentication
token, bound to all interfaces (`0.0.0.0`).

## VS Code Remote SSH

This project includes `.vscode/settings.json` that auto-selects the correct
Python kernel (`~/jupyterlab/.venv/bin/python`).

1. Add this to your **Windows** SSH config (`C:\Users\<user>\.ssh\config`):

   ```
   Host jupyter-lab
       HostName <public-ip>
       User ubuntu
       IdentityFile C:\Users\<user>\.ssh\ec2-key.pem
   ```

2. In VS Code: `Ctrl+Shift+P` > **Remote-SSH: Connect to Host** > `jupyter-lab`
3. **File > Open Folder** > `/home/ubuntu/jupyterlab`
4. Open any `.ipynb` file — the kernel is auto-selected

When the EC2 IP changes, only update the `HostName` line in your SSH config.

## Adding packages

```bash
uv add pandas matplotlib scikit-learn
```

## Rebuilding the environment

```bash
rm -rf .venv
uv sync --no-install-project
```
