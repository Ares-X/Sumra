#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/sumra-packaging-tests.XXXXXX")
test_source="$test_directory/main.swift"
trap 'rm -rf "$test_directory"' EXIT
# Run the same implementation with its entry point disabled; no product build needed.
tail -n +2 scripts/package-release.swift > "$test_source"
cat Tests/Packaging/PackageReleaseTests.swift >> "$test_source"
swift -D PACKAGING_TESTS "$test_source"
# Exercise the bundle's actual UTI list without building, signing or registering an app.
tail -n +2 scripts/bundle.swift > "$test_source"
cat Tests/Packaging/QuickLookRegistrationTests.swift >> "$test_source"
swift -D BUNDLE_METADATA_TESTS "$test_source" "$test_directory"
