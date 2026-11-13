#!/usr/bin/env bash
# Checks a built image: architecture, mise tools, SDK packages, system tools and the volume contract.
# Usage: test/verify-image.sh IMAGE
# The checks are scripts that run in the container, so their variables expand there, not here.
# shellcheck disable=SC2016
set -euo pipefail

image="${1:?usage: test/verify-image.sh IMAGE}"
agent_home=/home/jenkins
failures=0

report() {
	local name="$1" output="$2" status="$3"
	if [ "$status" -eq 0 ]; then
		printf 'ok    %s\n' "$name"
	else
		printf 'FAIL  %s\n' "$name"
		printf '%s\n' "$output" | sed 's/^/      /'
		failures=$((failures + 1))
	fi
}

# Runs a check in a fresh container: check NAME SCRIPT [docker run options...]
check() {
	local name="$1" script="$2" output status=0
	shift 2
	output="$(docker run --rm --platform linux/amd64 --entrypoint /usr/local/bin/android-agent-init "$@" "$image" \
		bash -c "set -e; $script" 2>&1)" || status=$?
	report "$name" "$output" "$status"
}

check "runs as x86_64" '[ "$(uname -m)" = x86_64 ]'

check "java is the configured global JDK" '
	expected="$(head -n 1 /etc/android-agent/java-versions)"
	mise ls --global --current java | grep -q -- "$expected"
	java -version'

check "mise globals are installed" '
	for tool in java node ruby bun jq yq android-sdk; do
		mise ls --global --current "$tool" | grep -q . || { echo "missing global: $tool"; exit 1; }
	done
	[ -z "$(mise ls --global --missing)" ]'

check "extra JDKs are installed, not global" '
	while read -r version; do
		mise where "java@$version" >/dev/null
	done < <(tail -n +2 /etc/android-agent/java-versions)'

check "ANDROID_HOME follows the path contract" '
	[ "$ANDROID_HOME" = "$HOME/.local/share/mise/installs/android-sdk/latest" ]
	case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) exit 1 ;; esac
	case ":$PATH:" in *":$HOME/.local/share/mise/shims:"*) ;; *) exit 1 ;; esac
	[ -x "$ANDROID_HOME/cmdline-tools/$(ls "$ANDROID_HOME/cmdline-tools")/bin/sdkmanager" ]'

check "SDK packages are installed" '
	installed="$(sdkmanager --list_installed 2>/dev/null)"
	while read -r package; do
		grep -q -- "^ *$package " <<<"$installed" || { echo "not installed: $package"; exit 1; }
	done < /etc/android-agent/sdk-packages'

check "SDK is writable by the agent user" 'touch "$ANDROID_HOME/.write-test" && rm "$ANDROID_HOME/.write-test"'

check "apkanalyzer and aapt run" 'apkanalyzer --help 2>&1 | grep -q -i usage && aapt version'

check "system and build tools run" '
	jq --version && yq --version && xsltproc --version && xmllint --version && gawk --version \
		&& zip -v && unzip -v && make --version && git --version && ssh -V \
		&& bundle --version && node --version && bun --version && ruby --version'

check "en_US.UTF-8 locale is generated" 'locale -a | grep -q -i "en_US.utf8"'

check "gradle.properties lists every baked JDK" '
	line="$(grep "^org.gradle.java.installations.paths=" "$HOME/.gradle/gradle.properties")"
	[ "$(wc -l < "$HOME/.gradle/gradle.properties")" -eq 1 ]
	while read -r version; do
		case ",${line#*=}," in *",$(mise where "java@$version"),"*) ;; *) echo "missing $version"; exit 1 ;; esac
	done < /etc/android-agent/java-versions'

check "run-time env vars reach the command unchanged" '
	[ "$SOME_PIPELINE_SETTING" = "a value, with spaces=and:symbols" ]' \
	-e "SOME_PIPELINE_SETTING=a value, with spaces=and:symbols"

# Empty named volumes on every documented mount point.
suffix="verify-$$"
volumes=(gradle mise cache workspace)
archives="$(mktemp -d)"
cleanup() {
	rm -rf "$archives"
	for volume in "${volumes[@]}"; do docker volume rm -f "$suffix-$volume" >/dev/null; done
}
trap cleanup EXIT
for volume in "${volumes[@]}"; do docker volume create "$suffix-$volume" >/dev/null; done
mounts=(
	-v "$suffix-gradle:$agent_home/.gradle"
	-v "$suffix-mise:$agent_home/.local/share/mise"
	-v "$suffix-cache:$agent_home/.jenkins-cache"
	-v "$suffix-workspace:$agent_home/agent"
)

check_with_volumes() {
	check "$1" "$2" "${mounts[@]}"
}

# A read-only host folder of SDK zips, named by an env var, unpacks once into the cache volume.
mkdir -p "$archives/sdk-1.0" && echo "sdk" >"$archives/sdk-1.0/VERSION"
(cd "$archives" && zip -q -r sdk-1.0.zip sdk-1.0 && rm -r sdk-1.0)
check "a read-only SDK archive folder unzips into the cache volume" '
	! touch "$SDK_ARCHIVE_DIR/write-test" 2>/dev/null
	unzip -q "$SDK_ARCHIVE_DIR/sdk-1.0.zip" -d ~/.jenkins-cache/sdk
	[ "$(cat ~/.jenkins-cache/sdk/sdk-1.0/VERSION)" = sdk ]' \
	"${mounts[@]}" -e SDK_ARCHIVE_DIR=/opt/sdk-archives -v "$archives:/opt/sdk-archives:ro"
check "the unzipped SDK stays in the cache volume" '
	[ "$(cat ~/.jenkins-cache/sdk/sdk-1.0/VERSION)" = sdk ]' "${mounts[@]}"

check_with_volumes "empty named volumes are writable and tools still run" '
	for dir in ~/.gradle ~/.local/share/mise ~/.jenkins-cache ~/agent; do
		touch "$dir/.write-test" && rm "$dir/.write-test" || exit 1
	done
	grep -q "^org.gradle.java.installations.paths=" ~/.gradle/gradle.properties
	java -version && sdkmanager --list_installed >/dev/null'

# A volume that already holds Gradle state but no gradle.properties gets one seeded.
docker run --rm --platform linux/amd64 --entrypoint bash -v "$suffix-gradle:$agent_home/.gradle" "$image" \
	-c 'rm -f ~/.gradle/gradle.properties'
check_with_volumes "gradle.properties is seeded into a used volume" '
	grep -q "^org.gradle.java.installations.paths=" ~/.gradle/gradle.properties'

# A build's own properties survive, and a stale JDK list is replaced.
docker run --rm --platform linux/amd64 --entrypoint bash -v "$suffix-gradle:$agent_home/.gradle" "$image" \
	-c 'printf "%s\n" "org.gradle.java.installations.paths=/gone" "build.owned=1" > ~/.gradle/gradle.properties'
check_with_volumes "existing gradle.properties keeps build properties" '
	grep -q "^build.owned=1$" ~/.gradle/gradle.properties
	! grep -q "=/gone$" ~/.gradle/gradle.properties
	[ "$(grep -c "^org.gradle.java.installations.paths=" ~/.gradle/gradle.properties)" -eq 1 ]'

# A mise volume Docker did not fill from the image (a bind mount, or volume-nocopy) gets every tool on start.
# This downloads the JDK, Ruby and the SDK packages again.
unfilled=(--mount "type=volume,src=$suffix-mise-unfilled,dst=$agent_home/.local/share/mise,volume-nocopy")
volumes+=(mise-unfilled)
docker volume create "$suffix-mise-unfilled" >/dev/null
docker run --rm --platform linux/amd64 --user root --entrypoint chown "${unfilled[@]}" "$image" \
	1000:1000 "$agent_home/.local/share/mise"
check "an unfilled mise volume gets every tool on start" '
	[ -z "$(mise ls --global --missing)" ]
	java -version
	while read -r package; do
		[ -e "$ANDROID_HOME/${package//;//}" ] || { echo "missing $package"; exit 1; }
	done < /etc/android-agent/sdk-packages' "${unfilled[@]}"

if [ "$failures" -ne 0 ]; then
	echo "$failures check(s) failed"
	exit 1
fi
echo "all checks passed"
