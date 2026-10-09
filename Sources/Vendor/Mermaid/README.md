# Mermaid 11.6.0 source correspondence

The runtime bundle remains the unmodified pinned Sumatra asset in
`Sources/Sumra/Resources/Reader/mermaid.min.js`. Its bytes match the official
Mermaid 11.6.0 published legacy distribution; hashes and URLs are recorded in
`provenance.json`. Nothing in this directory is an application resource or a
new build dependency. The existing source packager includes it under `Sources`.

`mermaid.min.js.map.gz` retains the matching published source map, compressed
with a zero timestamp. Decompress with `gzip -dk mermaid.min.js.map.gz`. All
1,089 mapped sources have complete `sourcesContent`; package and source
inventories retain content hashes and generated mapping evidence.

The `release-*` files are focused build references recovered at registry-declared
release source commit `7b2083926dbe3b6280f42376a0d4195b2c72fb8e`. The lock and
RoughJS patch agree with the patch hash in the actual map. These files are not a
complete standalone upstream checkout. The complete project revision is at
https://github.com/mermaid-js/mermaid/tree/7b2083926dbe3b6280f42376a0d4195b2c72fb8e.
An exact rebuild and cryptographic attestation verification have not been run.

The flattened Microsoft URI sources match both published 3.0.8 and 3.1.0 source
maps; the texts do not distinguish those versions. The path-browserify source
matches published 1.0.1. Generated webpack runtime version remains unproven.
Source mapping establishes participation, not that every original line survived
tree shaking. Bundled nested contributor code needs its own matching notices.
Full component terms are retained in `Licenses/Mermaid-Dependencies.txt`.
