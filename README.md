# Android Jenkins agent image

A Docker image for running Android builds as a Jenkins agent. It holds the tools a typical Android build needs,
installed with [mise](https://mise.jdx.dev) for the agent user, and nothing specific to one project: no
credentials, no internal hosts, no commercial tools. Builds bring secrets and licensed tools at run time.

## Where it runs

The image is built for `linux/amd64` only, because Google ships the Android Linux tools (aapt2, the NDK, CMake)
for x86_64 only.

- **Apple Silicon Macs with [OrbStack](https://orbstack.dev):** turn on **Settings > System > Use Rosetta to run
  Intel code**. Without Rosetta, OrbStack runs amd64 containers under QEMU, which is far too slow for Android
  builds. Check the setting with:

  ```bash
  orb config show | grep rosetta        # expect: rosetta: true
  orb config set rosetta true           # turn it on, then restart OrbStack
  ```

  Then confirm a container runs as x86_64:

  ```bash
  docker run --rm --platform linux/amd64 --entrypoint uname IMAGE -m   # x86_64
  ```

- **Native x86_64 Linux hosts:** nothing else is needed. The image assumes nothing about OrbStack.

### Resources

Large apps need a lot from the Linux VM (OrbStack) or the host:

| Resource | Recommendation | OrbStack |
| --- | --- | --- |
| Memory | 16 GB or more for large apps | Settings > System > Memory limit, or `orb config set memory_mib 16384` |
| CPU | Every core the Mac can spare | Settings > System > CPU limit, or `orb config set cpu 8` |
| Disk | 100 GB or more free for large apps | OrbStack's disk grows on demand; keep that much free on the Mac |

Gradle sizes its daemon heap from the project's `org.gradle.jvmargs`, not from the container, so keep the
container's memory above what the daemon, Kotlin daemon and test workers need together.

### Speed

A clean `assembleDebug` of the minimal smoke-test app (`test/smoke-test.sh`), with the Gradle daemon stopped and
the caches warm, on one Apple Silicon Mac Studio (14 cores, 36 GB; OrbStack VM with 20 GB and Rosetta on):

| Where | Time |
| --- | --- |
| Natively on the Mac | 4.6 s |
| In the container, OrbStack with Rosetta | 18.6 s |

Each number is a single run. Most of a build this small is JVM and Gradle start-up, which Rosetta slows the most,
so the ratio for a large app can differ in either direction. Compare a real build the same way before moving work
to the container.

Under Rosetta, Gradle's file-system watcher logs `Couldn't poll for events, error = 4` and turns itself off for
that build. The build is not affected. To silence it, run Gradle with `--no-watch-fs` or set
`org.gradle.vfs.watch=false` in the project.

## Path contract

Builds can rely on these paths and variables. They do not change between image versions.

| Name | Value |
| --- | --- |
| Agent user | `jenkins`, home `/home/jenkins` |
| `ANDROID_HOME` | `$HOME/.local/share/mise/installs/android-sdk/latest` |
| `PATH` | starts with `$HOME/.local/bin` and `$HOME/.local/share/mise/shims`, then the baked build-tools directory |
| `JAVA_HOME` | empty, so the `java` mise selects for the working directory is used (see below) |
| `JENKINS_JAVA_BIN` | the base image's JDK, which runs the Jenkins agent process only |
| Workspace root | `/home/jenkins/agent` |
| Cache directory | `$HOME/.jenkins-cache`, for tools builds download (such as a scanner) and state they keep between builds |

`latest` is the symlink mise keeps to the newest installed `android-sdk` version. A project that installs a newer
command-line tools version through mise moves `latest` to that version's SDK root, which starts without the baked
packages; Gradle then downloads what it needs there.

## Tools

The tools are mise **global** versions of the agent user (`~/.config/mise/config.toml`):

- A project with its own mise config gets its pinned versions. mise downloads any that are missing on first use.
- A project without one uses these globals.
- mise trusts config files under the workspace root (`MISE_TRUSTED_CONFIG_PATHS`) and never prompts
  (`MISE_YES=1`).

| Tool | Notes |
| --- | --- |
| java | `JAVA_VERSION`, plus `EXTRA_JAVA_VERSIONS` installed but not global |
| node, bun | |
| ruby | with `bundler` |
| jq, yq | yq is also what the android-sdk plugin needs |
| android-sdk | the [mise android-sdk plugin](https://github.com/mise-plugins/mise-android-sdk), pinned to a commit |

The SDK holds `platforms;android-$ANDROID_PLATFORM`, `build-tools;$ANDROID_BUILD_TOOLS`, `platform-tools`,
`ndk;$ANDROID_NDK` and `cmake;$ANDROID_CMAKE`, with every license accepted. The agent user owns the SDK, so the
Android Gradle Plugin can download other platforms and NDKs on demand.

System packages: git, openssh-client, curl, ca-certificates, zip, unzip, jq, xsltproc, libxml2-utils (`xmllint`),
make, gawk, the `en_US.UTF-8` locale, and what Ruby gems need to compile native extensions (build-essential,
libssl-dev, libyaml-dev, zlib1g-dev, libffi-dev). They come from the base image's Debian release.

`~/.gradle/gradle.properties` holds a single property, `org.gradle.java.installations.paths`, listing every JDK
the image installed, so a project using a Gradle Java toolchain finds a baked JDK instead of downloading one.
Builds may add and remove their own properties there.

## Build arguments

| Argument | Default | Purpose |
| --- | --- | --- |
| `BASE_IMAGE` | `jenkins/inbound-agent:3384.v60d89463d9e0-1-jdk17@sha256:b0c4...` | Any Debian-based Jenkins agent image with a `jenkins` user |
| `BASE_ENTRYPOINT` | `/usr/local/bin/jenkins-agent` | The base image's entrypoint, run after the caches are prepared |
| `JAVA_VERSION` | `temurin-17` | The global JDK |
| `EXTRA_JAVA_VERSIONS` | empty | More JDKs, space separated, such as `temurin-21`. Installed, not global |
| `NODE_VERSION` | `20.19.3` | |
| `RUBY_VERSION` | `3.3.13` | |
| `BUNDLER_VERSION` | `4.0.24` | |
| `BUN_VERSION` | `1.4.2` | |
| `JQ_VERSION` | `1.8.2` | The mise jq; Debian's jq is also installed |
| `YQ_VERSION` | `4.54.3` | |
| `MISE_VERSION` | `2026.11.4` | Verified against the release's SHA-256 checksums |
| `ANDROID_SDK_PLUGIN` | the plugin's Git URL `#` a commit | |
| `ANDROID_SDK_VERSION` | `20` | The plugin's version: the SDK command-line tools version |
| `ANDROID_PLATFORM` | `36` | |
| `ANDROID_BUILD_TOOLS` | `36.1.0` | |
| `ANDROID_NDK` | `26.1.10909125` | |
| `ANDROID_CMAKE` | `3.22.1` | |

Build it:

```bash
docker build --platform linux/amd64 -t android-agent .

# A project that also builds with JDK 21:
docker build --platform linux/amd64 --build-arg EXTRA_JAVA_VERSIONS="temurin-21" -t android-agent .
```

mise asks GitHub's API for some versions. To avoid its rate limit, pass a token as a BuildKit secret; it is not
stored in the image:

```bash
GITHUB_TOKEN=... docker build --platform linux/amd64 --secret id=github_token,env=GITHUB_TOKEN -t android-agent .
```

## Volumes

The image works with these mounted, empty or not:

| Mount point | Holds |
| --- | --- |
| `/home/jenkins/.gradle` | Gradle caches and `gradle.properties` |
| `/home/jenkins/.local/share/mise` | mise tools and the Android SDK, including what projects download |
| `/home/jenkins/.jenkins-cache` | tools builds download, SDKs they unpack, and state they keep between builds |
| `/home/jenkins/agent` | the workspace root |

Keep `~/.jenkins-cache` a volume: builds unpack each SDK version into it once and reuse it after that.

Use **named Docker volumes**. Docker fills an empty named volume from the image the first time it is mounted, so
the baked tools and SDK appear in it with the agent user as owner. On OrbStack, named volumes also live inside the
Linux VM, which is much faster than bind-mounting macOS folders for directories with many small files like the
Gradle and mise caches.

Before running the agent, the entrypoint (`android-agent-init`):

1. installs any global mise tool, extra JDK or SDK package missing from the volume, such as after an image upgrade
   or with a volume Docker did not fill (a bind mount, or `volume-nocopy`). Those downloads happen once per volume.
2. writes `org.gradle.java.installations.paths` into `~/.gradle/gradle.properties`, creating the file if needed and
   leaving every other property as it is.
3. creates `~/.jenkins-cache`.

A bind-mounted directory must be writable by the agent user (uid 1000).

### SDK archives from the host

Builds can read SDK zips from a host folder instead of downloading them. Mount the folder read-only and give its
path in an environment variable at run time. The pipeline decides the variable's name; the image passes every
variable through to the agent and its builds unchanged:

```bash
docker run ... \
  -e SDK_ARCHIVE_DIR=/opt/sdk-archives \
  -v /path/on/host/sdk-archives:/opt/sdk-archives:ro \
  IMAGE ...
```

The image holds no archives and no host paths. Builds unzip what they need into `~/.jenkins-cache` (`unzip` is
installed). On OrbStack, any folder under your macOS home can be mounted this way.

## Running it as a Jenkins agent

### Inbound (WebSocket or TCP) agent

1. In Jenkins, add a node under **Manage Jenkins > Nodes > New node**: a permanent agent, remote root directory
   `/home/jenkins/agent`, launch method **Launch agent by connecting it to the controller**. Give it a label such
   as `android`.
2. Start the container with the node's name and secret:

   ```bash
   docker volume create android-agent-gradle
   docker volume create android-agent-mise
   docker volume create android-agent-cache
   docker volume create android-agent-workspace

   docker run -d --name android-agent --restart unless-stopped \
     --platform linux/amd64 \
     --memory 16g \
     -v android-agent-gradle:/home/jenkins/.gradle \
     -v android-agent-mise:/home/jenkins/.local/share/mise \
     -v android-agent-cache:/home/jenkins/.jenkins-cache \
     -v android-agent-workspace:/home/jenkins/agent \
     ghcr.io/OWNER/REPO:VERSION \
     -url https://jenkins.example.com -webSocket -name android-1 -secret SECRET
   ```

   Every argument after the image goes to the base image's `jenkins-agent`, so all of
   [its options](https://github.com/jenkinsci/docker-agent) work, including the `JENKINS_URL`, `JENKINS_SECRET`
   and `JENKINS_AGENT_NAME` environment variables.

3. Run builds on it with `agent { label 'android' }`.

[`docker-compose.example.yml`](docker-compose.example.yml) sets up the same agent, with the volumes and the
optional SDK archive folder, for `docker compose up -d`.

Docker-based clouds (the Docker plugin, Kubernetes) can use the image as their agent template the same way: put
the volumes, the SDK archive mount and its variable in the template's mounts and environment.

### SSH agent

Build on an SSH agent base instead:

```bash
docker build --platform linux/amd64 \
  --build-arg BASE_IMAGE=jenkins/ssh-agent:TAG-jdk17 \
  --build-arg BASE_ENTRYPOINT=/usr/local/bin/setup-sshd \
  -t android-ssh-agent .
```

The entrypoint starts as root there, so the cache preparation runs as `jenkins` and then `setup-sshd` takes over.
SSH sessions do not inherit the image's environment, so pipelines should set `ANDROID_HOME` and `PATH` from the
path contract above.

## Testing the image

```bash
test/verify-image.sh android-agent              # tools, SDK packages, path contract, volumes, SDK archive mount
test/smoke-test.sh container android-agent      # builds and tests a small app with the NDK, and times it
test/smoke-test.sh native                       # the same build on this machine, for comparison
```

## Publishing

`.github/workflows/image.yml` builds the image for `linux/amd64` on every pull request and push, runs both test
scripts, and pushes it to `ghcr.io/OWNER/REPO` when a `v*` tag is pushed, tagged with the version (`1.2.3` and
`1.2`) and the commit (`sha-...`).
