# Native app

Read [TESTING.md](TESTING.md) before adding or changing tests. Use the shared
`scripts/test.sh` entry point and the layer that owns the behavior. Automated
tests must assert production behavior; rendering an image or writing PASS is not
verification. Store generated evidence in ignored scratch space or run artifacts,
not the repository. Keep manual visual procedures separate from automated tests.
