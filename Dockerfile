# syntax=docker/dockerfile:1.10

# A Jenkins agent for Android builds. Build it for linux/amd64: Google ships aapt2, the NDK and CMake for
# x86_64 Linux only. See README.md for the build arguments and the paths builds can rely on.

ARG BASE_IMAGE=jenkins/inbound-agent:3384.v60d89463d9e0-1-jdk17@sha256:b0c41a6b69468ac7c72ad25c2a364e6b5f116a1ea44510642bd629a6323f0fab

FROM ${BASE_IMAGE}

# The base image's entrypoint, which android-agent-init runs once the caches are ready.
ARG BASE_ENTRYPOINT=/usr/local/bin/jenkins-agent
ARG AGENT_USER=jenkins
ARG AGENT_HOME=/home/jenkins
ARG WORKSPACE_ROOT=/home/jenkins/agent
# The JDK that runs the Jenkins agent process, which stays separate from the builds' JDK.
ARG AGENT_JAVA_BIN=/opt/java/openjdk/bin/java

ARG MISE_VERSION=2026.11.4
ARG JAVA_VERSION=temurin-17
ARG EXTRA_JAVA_VERSIONS=""
ARG NODE_VERSION=20.19.3
ARG RUBY_VERSION=3.3.13
ARG BUNDLER_VERSION=4.0.24
ARG BUN_VERSION=1.4.2
ARG JQ_VERSION=1.8.2
ARG YQ_VERSION=4.54.3
ARG ANDROID_SDK_PLUGIN=https://github.com/mise-plugins/mise-android-sdk.git#da7b1e78aafcd203bf64c7016140ff790b3cbdc8
ARG ANDROID_SDK_VERSION=20
ARG ANDROID_PLATFORM=36
ARG ANDROID_BUILD_TOOLS=36.1.0
ARG ANDROID_NDK=26.1.10909125
ARG ANDROID_CMAKE=3.22.1

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		build-essential \
		ca-certificates \
		curl \
		gawk \
		git \
		jq \
		libffi-dev \
		libssl-dev \
		libxml2-utils \
		libyaml-dev \
		locales \
		make \
		openssh-client \
		unzip \
		xsltproc \
		zip \
		zlib1g-dev \
	&& sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
	&& locale-gen \
	&& rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
RUN case "${TARGETARCH:-amd64}" in \
		amd64) mise_arch=x64 ;; \
		arm64) mise_arch=arm64 ;; \
		*) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
	esac \
	&& asset="mise-v${MISE_VERSION}-linux-${mise_arch}" \
	&& base="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}" \
	&& curl -fsSL -o "/tmp/${asset}" "${base}/${asset}" \
	&& curl -fsSL "${base}/SHASUMS256.txt" | grep " \./${asset}$" | sed "s| \./| /tmp/|" | sha256sum -c - \
	&& install -m 0755 "/tmp/${asset}" /usr/local/bin/mise \
	&& rm "/tmp/${asset}"

COPY --chmod=0755 rootfs/usr/local/bin/android-agent-init /usr/local/bin/android-agent-init
COPY rootfs/etc/android-agent/cache-retention.gradle /etc/android-agent/cache-retention.gradle
RUN ln -s "${BASE_ENTRYPOINT}" /usr/local/bin/base-entrypoint \
	&& echo "${AGENT_USER}" > /etc/android-agent/agent-user \
	&& printf '%s\n' "${JAVA_VERSION}" ${EXTRA_JAVA_VERSIONS} > /etc/android-agent/java-versions \
	&& printf '%s\n' \
		"platforms;android-${ANDROID_PLATFORM}" \
		"build-tools;${ANDROID_BUILD_TOOLS}" \
		"platform-tools" \
		"ndk;${ANDROID_NDK}" \
		"cmake;${ANDROID_CMAKE}" \
		> /etc/android-agent/sdk-packages

# JAVA_HOME is empty so builds get the JDK mise picks for their directory: a project's pinned JDK wins.
ENV LANG=en_US.UTF-8 \
	LC_ALL=en_US.UTF-8 \
	ANDROID_HOME=${AGENT_HOME}/.local/share/mise/installs/android-sdk/latest \
	JAVA_HOME="" \
	JENKINS_JAVA_BIN=${AGENT_JAVA_BIN} \
	MISE_YES=1 \
	MISE_TRUSTED_CONFIG_PATHS=${WORKSPACE_ROOT}
ENV PATH=${AGENT_HOME}/.local/bin:${AGENT_HOME}/.local/share/mise/shims:${ANDROID_HOME}/build-tools/${ANDROID_BUILD_TOOLS}:${PATH}

USER ${AGENT_USER}
# These exist before any volume is mounted, so Docker copies them, owned by the agent user, into empty named volumes.
RUN mkdir -p "${AGENT_HOME}/.gradle" "${AGENT_HOME}/.jenkins-cache" "${AGENT_HOME}/.local/bin" \
		"${AGENT_HOME}/.local/share/mise" "${WORKSPACE_ROOT}"

# A token only raises GitHub's API rate limit while mise resolves versions. It is never written to the image.
RUN --mount=type=secret,id=github_token,uid=1000 \
	if [ -s /run/secrets/github_token ]; then GITHUB_TOKEN="$(cat /run/secrets/github_token)"; export GITHUB_TOKEN; fi \
	&& mise use -g "jq@${JQ_VERSION}" "yq@${YQ_VERSION}" \
	&& mise use -g "java@${JAVA_VERSION}" "node@${NODE_VERSION}" "ruby@${RUBY_VERSION}" "bun@${BUN_VERSION}" \
	&& for version in ${EXTRA_JAVA_VERSIONS}; do mise install "java@${version}"; done \
	&& gem install bundler --version "${BUNDLER_VERSION}" --no-document \
	&& mise reshim \
	&& mise cache clear

RUN --mount=type=secret,id=github_token,uid=1000 \
	if [ -s /run/secrets/github_token ]; then GITHUB_TOKEN="$(cat /run/secrets/github_token)"; export GITHUB_TOKEN; fi \
	&& printf '\n[plugins]\nandroid-sdk = "%s"\n' "${ANDROID_SDK_PLUGIN}" >> "${AGENT_HOME}/.config/mise/config.toml" \
	&& mise use -g "android-sdk@${ANDROID_SDK_VERSION}" \
	&& test -x "${ANDROID_HOME}/cmdline-tools/"*/bin/sdkmanager \
	&& (set +o pipefail; yes | sdkmanager --licenses > /dev/null) \
	&& mapfile -t packages < /etc/android-agent/sdk-packages \
	&& sdkmanager "${packages[@]}" \
	&& mise cache clear \
	&& rm -rf "${AGENT_HOME}/.android/cache" /tmp/*

RUN android-agent-init --prepare \
	&& cat "${AGENT_HOME}/.gradle/gradle.properties"

WORKDIR ${AGENT_HOME}
ENTRYPOINT ["/usr/local/bin/android-agent-init", "/usr/local/bin/base-entrypoint"]
