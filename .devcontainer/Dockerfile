FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

USER root
COPY dev/setup.sh /tmp/ai-renamer-dev/dev/setup.sh
COPY ci/install-bend.sh /tmp/ai-renamer-dev/ci/install-bend.sh
RUN sh /tmp/ai-renamer-dev/dev/setup.sh /opt/bend \
    && chown -R vscode:vscode /opt/bend \
    && rm -rf /var/lib/apt/lists/* /tmp/ai-renamer-dev

ENV BEND_HOME=/opt/bend
ENV PATH=/opt/bend/bin:$PATH
ENV BEND_NO_TELEMETRY=1
USER vscode
