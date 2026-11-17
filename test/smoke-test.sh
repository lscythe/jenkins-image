#!/usr/bin/env bash
# Builds and unit-tests a minimal Android app (one Java activity, one JUnit 5 test, one C library built with
# CMake through the NDK), then times a clean assembleDebug with the Gradle daemon stopped and caches warm.
#
# Usage:
#   test/smoke-test.sh container IMAGE   build inside IMAGE, with empty named volumes for the caches
#   test/smoke-test.sh native            build on this machine (needs mise and ANDROID_HOME with the same packages)
set -euo pipefail

readonly AGP_VERSION=8.13.2
readonly GRADLE_VERSION=8.14.7
readonly JUNIT_VERSION=5.14.4
readonly COMPILE_SDK="${SMOKE_COMPILE_SDK:-36}"
readonly BUILD_TOOLS="${SMOKE_BUILD_TOOLS:-36.1.0}"
readonly NDK="${SMOKE_NDK:-26.1.10909125}"
readonly CMAKE="${SMOKE_CMAKE:-3.22.1}"
readonly NATIVE_JAVA="${SMOKE_NATIVE_JAVA:-temurin-17}"

generate_app() {
	local dir="$1"
	mkdir -p "$dir/src/main/java/org/example/smoke" "$dir/src/main/cpp" "$dir/src/test/java/org/example/smoke"

	cat >"$dir/settings.gradle" <<-'EOF'
		pluginManagement {
		    repositories { google(); mavenCentral(); gradlePluginPortal() }
		}
		dependencyResolutionManagement {
		    repositories { google(); mavenCentral() }
		}
		rootProject.name = 'smoke'
	EOF

	cat >"$dir/gradle.properties" <<-'EOF'
		org.gradle.jvmargs=-Xmx2g
	EOF

	cat >"$dir/build.gradle" <<-EOF
		plugins {
		    id 'com.android.application' version '$AGP_VERSION'
		}

		android {
		    namespace 'org.example.smoke'
		    compileSdk $COMPILE_SDK
		    buildToolsVersion '$BUILD_TOOLS'
		    ndkVersion '$NDK'

		    defaultConfig {
		        applicationId 'org.example.smoke'
		        minSdk 24
		        targetSdk $COMPILE_SDK
		        versionCode 1
		        versionName '1.0'
		        ndk { abiFilters 'arm64-v8a', 'x86_64' }
		    }

		    compileOptions {
		        sourceCompatibility JavaVersion.VERSION_17
		        targetCompatibility JavaVersion.VERSION_17
		    }

		    externalNativeBuild {
		        cmake {
		            path 'src/main/cpp/CMakeLists.txt'
		            version '$CMAKE'
		        }
		    }

		    testOptions {
		        unitTests.all { useJUnitPlatform() }
		    }
		}

		dependencies {
		    testImplementation platform('org.junit:junit-bom:$JUNIT_VERSION')
		    testImplementation 'org.junit.jupiter:junit-jupiter'
		    testRuntimeOnly 'org.junit.platform:junit-platform-launcher'
		}
	EOF

	cat >"$dir/src/main/AndroidManifest.xml" <<-'EOF'
		<manifest xmlns:android="http://schemas.android.com/apk/res/android">
		    <application android:label="Smoke">
		        <activity android:name=".MainActivity" android:exported="true">
		            <intent-filter>
		                <action android:name="android.intent.action.MAIN" />
		                <category android:name="android.intent.category.LAUNCHER" />
		            </intent-filter>
		        </activity>
		    </application>
		</manifest>
	EOF

	cat >"$dir/src/main/java/org/example/smoke/MainActivity.java" <<-'EOF'
		package org.example.smoke;

		import android.app.Activity;
		import android.os.Bundle;
		import android.widget.TextView;

		public class MainActivity extends Activity {
		    static {
		        System.loadLibrary("smoke");
		    }

		    private static native String nativeName();

		    @Override
		    protected void onCreate(Bundle savedInstanceState) {
		        super.onCreate(savedInstanceState);
		        TextView text = new TextView(this);
		        text.setText(Greeting.of(nativeName()));
		        setContentView(text);
		    }
		}
	EOF

	cat >"$dir/src/main/java/org/example/smoke/Greeting.java" <<-'EOF'
		package org.example.smoke;

		final class Greeting {
		    private Greeting() {}

		    static String of(String name) {
		        return "Hello, " + name + "!";
		    }
		}
	EOF

	cat >"$dir/src/main/cpp/CMakeLists.txt" <<-EOF
		cmake_minimum_required(VERSION $CMAKE)
		project(smoke C)
		add_library(smoke SHARED smoke.c)
	EOF

	cat >"$dir/src/main/cpp/smoke.c" <<-'EOF'
		#include <jni.h>

		JNIEXPORT jstring JNICALL
		Java_org_example_smoke_MainActivity_nativeName(JNIEnv *env, jclass clazz) {
		    return (*env)->NewStringUTF(env, "native code");
		}
	EOF

	cat >"$dir/src/test/java/org/example/smoke/GreetingTest.java" <<-'EOF'
		package org.example.smoke;

		import static org.junit.jupiter.api.Assertions.assertEquals;

		import org.junit.jupiter.api.Test;

		class GreetingTest {
		    @Test
		    void greetsByName() {
		        assertEquals("Hello, native code!", Greeting.of("native code"));
		    }
		}
	EOF

	# Runs inside the app directory, in the container or natively.
	cat >"$dir/run.sh" <<-EOF
		set -euo pipefail
		mise exec gradle@$GRADLE_VERSION -- gradle wrapper --gradle-version $GRADLE_VERSION --quiet
		./gradlew --quiet assembleDebug testDebugUnitTest
		ls build/outputs/apk/debug/*.apk
		ls build/test-results/testDebugUnitTest/TEST-*.xml
		grep -q 'tests="1" skipped="0" failures="0" errors="0"' build/test-results/testDebugUnitTest/TEST-*.xml
		unzip -l build/outputs/apk/debug/*.apk | grep 'lib/x86_64/libsmoke.so'

		./gradlew --quiet clean
		./gradlew --quiet --stop
		TIMEFORMAT='clean assembleDebug, daemon stopped, caches warm: %Rs'
		time ./gradlew --quiet assembleDebug
		./gradlew --quiet --stop
	EOF

	# Runs in the container only: throwaway builds with the image's cache retention init script in place.
	cat >"$dir/cache-retention.sh" <<-'EOF'
		set -euo pipefail
		gradle8="$(mktemp -d)" gradle7="$(mktemp -d)"
		# The init script sets these before settings.gradle runs; Gradle's own defaults are 30 and 7 days.
		# Gradle's public API can only set retention, so this reads it back through internal accessors (renamed in
		# later 8.x releases) and turns the cut-off timestamp into days.
		cat >"$gradle8/settings.gradle" <<-'SETTINGS'
			def retentionDays = { resource ->
			    def cutOff = resource.metaClass.respondsTo(resource, 'getEntryRetentionTimestampSupplier')
			        ? resource.entryRetentionTimestampSupplier.get()
			        : resource.removeUnusedEntriesOlderThanAsSupplier.get()
			    Math.round((System.currentTimeMillis() - cutOff) / 86400000d)
			}
			def expected = [releasedWrappers: 7, snapshotWrappers: 3, downloadedResources: 14, createdResources: 5]
			if (GradleVersion.current().baseVersion >= GradleVersion.version('8.8')) expected.buildCache = 3
			expected.each { name, days ->
			    def actual = retentionDays(settings.caches."$name")
			    if (actual != days) throw new GradleException("$name keeps entries $actual days, expected $days")
			}
		SETTINGS
		touch "$gradle7/settings.gradle"
		# 8.0 is the first version with cache settings, and 8.8 the first with the build cache's.
		for version in 8.0.2 8.7 8.14.7; do
			(cd "$gradle8" && mise exec "gradle@$version" -- gradle --quiet --no-daemon help)
			echo "Gradle $version builds with the cache retention init script"
		done
		(cd "$gradle7" && mise exec gradle@7.6.4 -- gradle --quiet --no-daemon help)
		echo "Gradle 7.6.4 builds with the cache retention init script"
	EOF
}

run_in_container() {
	local image="$1" dir="$2"
	volumes=("smoke-$$-gradle" "smoke-$$-mise")
	local platform
	platform="$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$image")"
	tar -C "$dir" -c . | docker run --rm -i --platform "$platform" \
		--entrypoint /usr/local/bin/android-agent-init \
		-v "${volumes[0]}:/home/jenkins/.gradle" \
		-v "${volumes[1]}:/home/jenkins/.local/share/mise" \
		"$image" \
		bash -c 'mkdir -p ~/agent/smoke && cd ~/agent/smoke && tar -x && uname -m && bash run.sh && bash cache-retention.sh'
}

run_natively() {
	local dir="$1"
	export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
	(cd "$dir" && uname -m && mise exec "java@$NATIVE_JAVA" -- bash run.sh)
}

app_dir=""
volumes=()
cleanup() {
	rm -rf "$app_dir"
	if [ "${#volumes[@]}" -gt 0 ]; then docker volume rm -f "${volumes[@]}" >/dev/null; fi
}

main() {
	local mode="${1:?usage: test/smoke-test.sh container IMAGE | native}"
	app_dir="$(mktemp -d)"
	trap cleanup EXIT
	local dir="$app_dir"
	generate_app "$dir"
	case "$mode" in
		container) run_in_container "${2:?usage: test/smoke-test.sh container IMAGE}" "$dir" ;;
		native) run_natively "$dir" ;;
		*) echo "unknown mode: $mode" >&2; exit 2 ;;
	esac
	echo "smoke test passed ($mode)"
}

main "$@"
