FROM node:24-slim

# Install dependencies including gh CLI and gosu
RUN apt-get update && apt-get install -y \
    curl \
    git \
    bash \
    gosu \
    jq \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code via native installer and symlink to system PATH
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && cp /root/.local/bin/claude /usr/local/bin/claude

# Create non-root user for running Claude CLI
RUN useradd -m -s /bin/bash claude

# Configure git template
RUN mkdir -p /root-template && \
    git config --global credential.helper store && \
    git config --global user.name "Claude" && \
    git config --global user.email "claude@orangepi.local" && \
    cp /root/.gitconfig /root-template/.gitconfig

# Bake skills into the image (avoids runtime GitHub fetch)
RUN git clone --depth 1 https://github.com/julien51/dotfiles.git /tmp/dotfiles && \
    cp -r /tmp/dotfiles/.claude/skills /skills-template && \
    rm -rf /tmp/dotfiles

# Set working directory
WORKDIR /workspace

# Create entrypoint scripts
COPY common-init.sh /common-init.sh
COPY entrypoint.sh /entrypoint.sh
COPY entrypoint-task.sh /entrypoint-task.sh
RUN chmod +x /common-init.sh /entrypoint.sh /entrypoint-task.sh

ENV DISABLE_AUTOUPDATER=1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
