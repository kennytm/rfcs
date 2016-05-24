- Feature Name: -
- Start Date: 2016-05-24
- RFC PR: (leave this empty)
- Rust Issue: (leave this empty)

# Summary
[summary]: #summary

Add a `cargo list-outputs` subcommand to list the path of the output files of all artifacts in JSON
format. Address [rust-lang/cargo#2508][cargo-2508].

# Motivation
[motivation]: #motivation

This subcommand allows us **to determine artifact location**. The final output of the
test/benchmark executables contain an "extra filename" (a 64-bit hash) to prevent name conflict.
The extra filename cannot be easily determined, which means we don't know the exact path of the
test executables. But why must we add the command directly to cargo?

1. **Extra-filename highly depends on the exact cargo version.** The extra filename is computed
   from the [SIP hash][hex.rs] of [the PackageId][package_id.rs] which depends not only on the
   structure of this structure, but also external structures, mainly `semver::SemVer` and
   `url::Url`. This means the exact value of an extra-filename can change whenever Cargo upgrades
   its dependencies (FWIW, 0.9.0, 0.10.0 and 0.11.0 all produce different extra-filenames).

2. **We cannot create a proper Cargo subcommand on crates.io to provide this function.**
   The `cargo` crate exposes the `cargo::ops::cargo_rust::Context::target_filenames()` function to
   retrieve the output files of each artifact. However, as explained in motivation 1, the output
   filenames of the test targets are correct only in one version of Cargo. Since a crate cannot
   depend on multiple versions of the same crate, we need to provide multiple crates like
   `cargo-list-outputs-1_8_0`, `cargo-list-outputs-1_9_0`, `cargo-list-outputs-1_10_0-2015-05-24`, …
   to properly support all versions. Clearly this is not a good solution. The only sane way to
   obtain this information is let the Cargo binary tell us where to find the outputs

3. **We cannot glob.** Again due to issue 2, if we run `cargo test` from three different
   installations of Cargo, we will get three test executables differing just by the extra filename.
   If we do a glob like `target/debug/crate_name-*`, we will not know which of the three is the
   file we want.

But why do we want to determine the exact path of the test program?

4. **Instrumentation.**
   [The `kcov` tool][kcov-tutorial] needs to run the test executables directly to collect coverage.
   Probably the same for `gdb` and `valgrind`.

5. **External build systems.** Tools like `gradle` will resolve dependency better if you could tell
   them the list of output filenames.

6. **IDE integration.** See [rust-lang/cargo#1924][cargo-1924].

7. **Simplify Cargo subcommands.** Subcommands like `cargo-lipo` and `cargo-profiler` can simplify
   some of the code using the structured output of the target list. Also,
   [travis-cargo][travis-cargo.py] doesn't need to execute the test case twice just to fetch the
   location of the executables.

# Detailed design
[design]: #detailed-design

Add a built-in subcommand

    cargo list-outputs [-v | --verbose] [--color auto]
        [--release]
        [--target TRIPLE]
        [--manifest-path PATH]
        [--format-version 1]

which lists all outputs in JSON format. For instance,

    cargo-list-output-test/
        Cargo.toml
        build.rs
        src/
            lib.rs
            main.rs
            bin/
                first.rs
        examples/
            third.rs
        tests/
            fifth.rs
        benches/
            seventh.rs

Would generate the following JSON (pretty-printed for human consumption):

```js
[
    {
        "kind": ["rlib", "dylib", "staticlib"],
        "name": "cargo-list-output-test",
        "outputs": [
            "/path/to/cargo-list-output-test/target/debug/libcargo_list_output_test.a",
            "/path/to/cargo-list-output-test/target/debug/libcargo_list_output_test.rlib",
            "/path/to/cargo-list-output-test/target/debug/libcargo_list_output_test.so",
        ]
    },
    {
        "kind": ["test"],
        "name": "cargo-list-output-test",
        "outputs": ["/path/to/cargo-list-output-test/target/debug/cargo_list_output_test-a941428a8bce681a"]
    },
    {
        "kind": ["bin"],
        "name": "cargo-list-output-test",
        "outputs": ["/path/to/cargo-list-output-test/target/debug/cargo-list-output"]
    },
    {
        "kind": ["test"],
        "name": "cargo-list-output-test",
        "outputs": ["/path/to/cargo-list-output-test/target/debug/cargo_list_output_test-723a247238b3ca3d"]
    },
    {
        "kind": ["bin"],
        "name": "first",
        "outputs": ["/path/to/cargo-list-output-test/target/debug/first"]
    },
    {
        "kind": ["custom-build"],
        "name": "build-script-build",
        "outputs": ["/path/to/cargo-list-output-test/target/debug/build/cargo-list-output-test-4235bdd03478219f/build-script-build"]
    },
    {
        "kind": ["example"],
        "name": "third",
        "outputs": ["/path/to/cargo-list-output-test/target/debug/third"]
    },
    {
        "kind": ["test"],
        "name": "fifth",
        "outputs": ["/path/to/cargo-list-output-test/target/debug/fifth-158ffb7a4afb95ce"]
    },
    {
        "kind": ["bench"],
        "name": "seventh",
        "outputs": ["/path/to/cargo-list-output-test/target/debug/seventh-17a6aaae6d0cc034"]
    }
]
```

# Drawbacks
[drawbacks]: #drawbacks

* External programs have to wait for the train to arrive before being able to take advantage of it
* We need to maintain one more subcommand

# Alternatives
[alternatives]: #alternatives

* **Make the generated filename deterministic and stablize it** as in
  [rust-lang/cargo#1924][cargo-1924], e.g.

    * change the extra filenames to `-<kind>-test`.
    * stablize the hash algorithm so the same (package ID + crate version + kind + filename)
      combination will always generate the same hash regardless of the Cargo structure or the
      external dependencies (semver, url). Publish, document and add the algorithm to regression
      test cases.

  This addresses motivation 1. External programs still need to `read_dir` to discover all target
  executables but at least they can be more confident that there is no irrelevant files.

* **Integrate the output directly into `cargo metadata`.** This means adding back something similar
  to the Target::metadata field removed in [rust-lang/cargo#2219][cargo-2219].

* **Allow a crate to depend on multiple versions of the same crate.**

* **Allow `build.rs` to rewrite the list of dependencies.** Both of these address motivation 2. But
  these solutions are pretty ugly.

* **Include rustc/Cargo version into the target output folder name,** e.g.
  `target/cargo-0.11.0/debug/`. This addresses motivation 3.

* Output format other than JSON — not discussed here, please redirect to
  [rust-lang/cargo#2313][cargo-2313].

# Unresolved questions
[unresolved]: #unresolved-questions

* Should we seperate the output for the four kinds of libraries?
* Do we want to distinguish between integrated tests, library tests and binary tests?
* Do we want to include more information in the `list-outputs` JSON?

[hex.rs]: https://github.com/rust-lang/cargo/blob/ca743f3118532e7fc5f74938801ebac369665c89/src/cargo/util/hex.rs
[package_id.rs]: https://github.com/rust-lang/cargo/blob/ca743f3118532e7fc5f74938801ebac369665c89/src/cargo/core/package_id.rs#L138
[kcov-tutorial]: https://users.rust-lang.org/t/tutorial-how-to-collect-test-coverages-for-rust-project/650
[cargo-1924]: https://github.com/rust-lang/cargo/issues/1924
[cargo-2219]: https://github.com/rust-lang/cargo/pull/2219
[cargo-2313]: https://github.com/rust-lang/cargo/issues/2313
[cargo-2508]: https://github.com/rust-lang/cargo/issues/2508
[travis-cargo.py]: https://github.com/huonw/travis-cargo/blob/af51893dda0a1e20ece7f9c5b73c2805eb7b9059/travis_cargo.py#L182

