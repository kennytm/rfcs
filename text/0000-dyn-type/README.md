- Feature Name: `dyn_type`
- Start Date: 2018-01-04
- RFC PR: (leave this empty)
- Rust Issue: (leave this empty)

# Summary

Generalize the concept of Dynamic Sized Types (DSTs) and enable custom DSTs.

# Motivation
[motivation]: #motivation

This RFC is a replacement of [RFC #1524]. The main motivations of custom DSTs are:

* DST allows us to get rid of combinatorial explosion when interacting with smart pointers. Instead
    of defining `BoxMatrix`, `RcMatrix`, `GcMatrix` etc, we get `Box<Matrix>`, `Rc<Matrix>`,
    `Gc<Matrix>` from a single type.

* The `Index` and `Deref` trait requires us to return a reference without allocation, i.e. indexing
    operation can’t return a `MatrixRef<'a>` even if this is the only solution without custom DST.

* Allow more possibilities for modifying existing APIs involving DST types without breakage.

We expect many types will benefit from custom DSTs, here are some examples:

* Multi-dimensional arrays (matrix and tensor libraries).
* Length-prefixed structures e.g. Pascal strings or C structures with a flexible array member.
* `CStr`.
* `OsStr` on Windows (WTF-8 slice or multi-encoded string).
* Bit array.

[RFC #1524]: https://github.com/rust-lang/rfcs/pull/1524

# Guide-level explanation
[guide-level-explanation]: #guide-level-explanation

* [Tutorial](0000-dyn-type/20-Tutorial.html)
* [Examples](0000-dyn-type/21-Examples.html)

# Reference-level explanation
[reference-level-explanation]: #reference-level-explanation

* [Changes](0000-dyn-type/30-Changes.html)
* [Custom DST from scratch](0000-dyn-type/31-Custom-DST-from-scratch.html)

# Drawbacks
[drawbacks]: #drawbacks

* [Drawbacks](0000-dyn-type/40-Drawbacks.html)

# Rationale and alternatives
[alternatives]: #alternatives

* [Rationales](0000-dyn-type/50-Rationales.html)
* [Alternatives](0000-dyn-type/51-Alternatives.html)
* [Extensions](0000-dyn-type/52-Extensions.html)
* [Bikeshed](0000-dyn-type/53-Bikeshed.html)

# Unresolved questions
[unresolved]: #unresolved-questions

* Does `#[may_dangle]` make sense when implementing `Drop` for unsized types?