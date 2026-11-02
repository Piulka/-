#!/bin/zsh
set -eu
cd "${0:A:h}/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library AndroidWire.swift Tests/AndroidForegroundTests.swift -o "$test_dir/foreground-tests"
"$test_dir/foreground-tests"
swiftc -parse-as-library Environments.swift AccountCatalog.swift CourierDeepLink.swift Tests/ConfigurationTests.swift -o "$test_dir/configuration-tests"
"$test_dir/configuration-tests"
jdk='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
"$jdk/bin/javac" -d "$test_dir" AndroidAutomation/src/local/drivee/qahelper/StandHost.java Tests/StandHostTests.java
"$jdk/bin/java" -cp "$test_dir" local.drivee.qahelper.StandHostTests
"$jdk/bin/javac" -d "$test_dir" AndroidAutomation/src/local/drivee/qahelper/ElementMatch.java Tests/ElementMatchTests.java
"$jdk/bin/java" -cp "$test_dir" local.drivee.qahelper.ElementMatchTests
"$jdk/bin/javac" -d "$test_dir" AndroidAutomation/src/local/drivee/qahelper/TapTree.java Tests/TapTreeTests.java
"$jdk/bin/java" -cp "$test_dir" local.drivee.qahelper.TapTreeTests
swiftc -parse-as-library BuildModels.swift Tests/BuildModelsTests.swift -o "$test_dir/build-models-tests"
"$test_dir/build-models-tests"
swiftc -parse-as-library MediaClipboard.swift Tests/MediaClipboardTests.swift -o "$test_dir/media-clipboard-tests"
"$test_dir/media-clipboard-tests"
python3 -B -m unittest discover -s Tests -p '*_test.py'
