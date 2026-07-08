# android-dev: reproducible Android build toolchain + Claude Code + gh, driven over CRD/SSH.
# Networking (Tailscale) and the desktop (Chrome Remote Desktop) live on the host VM;
# this container runs with --network=host so adb reaches your laptop over the tailnet.
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG ANDROID_API=34
ARG BUILD_TOOLS=34.0.0
ARG CMDLINE_TOOLS_VERSION=11076708  # Android cmdline-tools 11.0

ENV ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    LANG=C.UTF-8

# Base tooling: JDK, git, node (for Claude Code), gh, common build deps.
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-17-jdk-headless git curl wget unzip zip ca-certificates gnupg \
        sudo python3 python3-pip tmux vim less locales \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Android SDK: cmdline-tools -> platform-tools (adb), a platform, build-tools.
RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" \
    && cd /tmp \
    && wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" -O cmdline-tools.zip \
    && unzip -q cmdline-tools.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools" \
    && mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest" \
    && rm cmdline-tools.zip
ENV PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator:${PATH}"
RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager --install \
        "platform-tools" \
        "platforms;android-${ANDROID_API}" \
        "build-tools;${BUILD_TOOLS}" \
        "emulator" \
        "system-images;android-${ANDROID_API};google_apis;x86_64" >/dev/null

# Claude Code CLI.
RUN npm install -g @anthropic-ai/claude-code

# Non-root dev user with passwordless sudo.
RUN useradd -m -s /bin/bash -G sudo dev \
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
    && chown -R dev:dev "${ANDROID_SDK_ROOT}"
USER dev
WORKDIR /home/dev/work

# A ready-to-run AVD, owned by dev. Creating it needs no KVM; *booting* it does
# (nested-virt machines, phase 2). Baked so `emulator @android${ANDROID_API}` just works.
RUN echo "no" | avdmanager create avd -n "android${ANDROID_API}" \
        -k "system-images;android-${ANDROID_API};google_apis;x86_64" -d pixel_6 >/dev/null 2>&1 || true

COPY --chown=dev:dev container/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=dev:dev scripts/push-build.sh /usr/local/bin/push-build
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
