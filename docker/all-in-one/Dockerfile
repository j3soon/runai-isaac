FROM ubuntu:22.04

# =====Common=====

RUN apt-get update && apt-get install -y \
    curl \
    git \
    htop \
    iputils-ping \
    nano \
    net-tools \
    netcat-traditional \
    ssh \
    tmux \
    tree \
    unzip \
    vim \
    wget \
    zip \
    && rm -rf /var/lib/apt/lists/*

# =====X11=====

RUN apt-get update && apt-get install -y \
    x11-apps x11-utils \
    && rm -rf /var/lib/apt/lists/*

# =====OpenGL=====

# Setup the required capabilities for the container runtime
# Ref: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/docker-specialized.html#driver-capabilities
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all

RUN apt-get update && apt-get install -y \
    libgl1 mesa-utils \
    && rm -rf /var/lib/apt/lists/*

# =====Vulkan=====

RUN apt-get update && apt-get install -y \
    libgl1 vulkan-tools \
    && rm -rf /var/lib/apt/lists/*

# Install Vulkan config files
RUN cat > /etc/vulkan/icd.d/nvidia_icd.json <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD": {
        "library_path": "libGLX_nvidia.so.0",
        "api_version" : "1.3.194"
    }
}
EOF
RUN mkdir -p /usr/share/glvnd/egl_vendor.d && \
    cat > /usr/share/glvnd/egl_vendor.d/10_nvidia.json <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_nvidia.so.0"
    }
}
EOF
RUN cat > /etc/vulkan/implicit_layer.d/nvidia_layers.json <<EOF
{
    "file_format_version" : "1.0.0",
    "layer": {
        "name": "VK_LAYER_NV_optimus",
        "type": "INSTANCE",
        "library_path": "libGLX_nvidia.so.0",
        "api_version" : "1.3.194",
        "implementation_version" : "1",
        "description" : "NVIDIA Optimus layer",
        "functions": {
            "vkGetInstanceProcAddr": "vk_optimusGetInstanceProcAddr",
            "vkGetDeviceProcAddr": "vk_optimusGetDeviceProcAddr"
        },
        "enable_environment": {
            "__NV_PRIME_RENDER_OFFLOAD": "1"
        },
        "disable_environment": {
            "DISABLE_LAYER_NV_OPTIMUS_1": ""
        }
    }
}
EOF

# =====OpenSSH Server=====

# Use supervisor to manage services
RUN apt-get update && apt-get install -y \
    supervisor \
    && rm -rf /var/lib/apt/lists/*

# Install OpenSSH Server
RUN apt-get update && apt-get install -y \
    openssh-server \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir /var/run/sshd
RUN sed -i \
    -e 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' \
    /etc/ssh/sshd_config
# Set environment variables
# Ref: https://stackoverflow.com/a/34631891
RUN env | egrep -v "^(HOME=|USER=|MAIL=|LC_ALL=|LS_COLORS=|LANG=|HOSTNAME=|PWD=|TERM=|SHLVL=|LANGUAGE=|_=)" >> /etc/environment
# Configure supervisor to manage the SSH server
RUN cat <<EOF > /etc/supervisor/conf.d/sshd.conf
[program:sshd]
command=/usr/sbin/sshd -D
stderr_logfile=/var/log/sshd.err.log
stdout_logfile=/var/log/sshd.out.log
EOF

# =====TigerVNC=====

# Install XFCE
RUN apt-get update && apt-get install -y \
    xfce4 \
    && rm -rf /var/lib/apt/lists/*
# Fix "Failed to execute default terminal emulator. Input/output error."
# Ref: https://askubuntu.com/a/1118319
# Ref: https://discourse.ubuntu.com/t/ctrl-alt-t-opens-xterm/60235/2
RUN apt-get update && apt-get install -y \
    xfce4-terminal \
    && rm -rf /var/lib/apt/lists/*
RUN update-alternatives --set x-terminal-emulator /usr/bin/xfce4-terminal.wrapper
# Fix "Failed to execute default Web Browser. Input/output error." by installing Firefox
# Ref: https://support.mozilla.org/en-US/kb/install-firefox-linux
RUN install -d -m 0755 /etc/apt/keyrings
RUN wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null
RUN echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | tee -a /etc/apt/sources.list.d/mozilla.list > /dev/null
RUN echo 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000' | tee /etc/apt/preferences.d/mozilla
RUN apt-get update && apt-get install -y \
    firefox \
    && rm -rf /var/lib/apt/lists/*

# Install TigerVNC
RUN apt-get update && apt-get install -y \
    tigervnc-standalone-server \
    && rm -rf /var/lib/apt/lists/*

# =====noVNC=====

# Install noVNC
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y novnc && \
    rm -rf /var/lib/apt/lists/*

# Link vnc.html to index.html
RUN ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# Configure supervisor to manage the noVNC server
RUN cat <<EOF > /etc/supervisor/conf.d/novnc.conf
[program:novnc]
command=/usr/share/novnc/utils/launch.sh --vnc localhost:5900
stderr_logfile=/var/log/novnc.err.log
stdout_logfile=/var/log/novnc.out.log
EOF

# =====Code Server=====

# Install code-server
# Ref: https://coder.com/docs/code-server/install#debian-ubuntu
RUN CODE_SERVER_VERSION=4.100.3 \
    && curl -fOL https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_amd64.deb \
    && dpkg -i code-server_${CODE_SERVER_VERSION}_amd64.deb \
    && rm code-server_${CODE_SERVER_VERSION}_amd64.deb

# Configure supervisor to manage the code-server
RUN cat <<EOF > /etc/supervisor/conf.d/code-server.conf
[program:code-server]
command=code-server --host 0.0.0.0 --port 8080
stderr_logfile=/var/log/code-server.err.log
stdout_logfile=/var/log/code-server.out.log
EOF

# =====Jupyter Lab=====

# Install pip and Jupyter Lab
RUN apt-get update && apt-get install -y \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*
RUN pip install jupyterlab

# =====Move all password settings to the end=====

# Set the password for the root user
ARG SSH_PASSWORD
RUN if [ -z "${SSH_PASSWORD}" ]; then \
    # Allow empty password login
    passwd -d root && \
    sed -i 's/#PermitEmptyPasswords no/PermitEmptyPasswords yes/' /etc/ssh/sshd_config; \
else \
    # Set password for root user
    echo "root:${SSH_PASSWORD}" | chpasswd; \
fi

# Set the password for VNC
RUN touch ~/.Xauthority
ARG TIGERVNC_PASSWORD
RUN mkdir -p ~/.vnc && \
    echo "${TIGERVNC_PASSWORD}" | vncpasswd -f > ~/.vnc/passwd && \
    chmod 600 ~/.vnc/passwd

# Configure supervisor to manage the TigerVNC server
RUN if [ -z "${TIGERVNC_PASSWORD}" ]; then FLAG="-SecurityTypes None --I-KNOW-THIS-IS-INSECURE"; else FLAG=""; fi && \
cat <<EOF > /etc/supervisor/conf.d/tigervnc.conf
[program:tigervnc]
command=/usr/bin/vncserver :0 -geometry 1920x1080 -depth 24 -localhost no ${FLAG}
stderr_logfile=/var/log/tigervnc.err.log
stdout_logfile=/var/log/tigervnc.out.log
EOF

# Set the password for code-server
ARG CODE_SERVER_PASSWORD
RUN if [ -z "${CODE_SERVER_PASSWORD}" ]; then AUTH="none"; else AUTH="password"; fi && \
mkdir -p ~/.config/code-server/ && \
cat <<EOF > ~/.config/code-server/config.yaml
bind-addr: 127.0.0.1:8080
auth: ${AUTH}
password: ${CODE_SERVER_PASSWORD}
cert: false
EOF

# Configure supervisor to manage the Jupyter Lab server
ARG JUPYTER_LAB_TOKEN
RUN cat <<EOF > /etc/supervisor/conf.d/jupyter-lab.conf
[program:jupyter-lab]
command=jupyter lab --allow-root --ip=0.0.0.0 --no-browser --notebook-dir=/ --NotebookApp.token="${JUPYTER_LAB_TOKEN}"
stderr_logfile=/var/log/jupyter-lab.err.log
stdout_logfile=/var/log/jupyter-lab.out.log
EOF
# We intentionally use `--NotebookApp.*` instead of `--ServerApp.*` to support older versions of Jupyter Lab
# Note: `--NotebookApp.password` may be used as an alternative, but it requires generating a hashed password which adds complexity
# Ref: https://stackoverflow.com/a/77117477

CMD ["/usr/bin/supervisord", "-n"]
