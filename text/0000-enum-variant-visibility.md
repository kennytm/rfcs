- Feature Name: `enum_variant_visibility`
- Start Date: 2020-02-02
- RFC PR: [rust-lang/rfcs#0000](https://github.com/rust-lang/rfcs/pull/0000)
- Rust Issue: [rust-lang/rust#0000](https://github.com/rust-lang/rust/issues/0000)

# Summary
[summary]: #summary

Semantically allow explicitly specifying visibility on enum variants.

# Motivation
[motivation]: #motivation

As of Rust 2018, all enum variants are public. It is not possible to hide implementation details in
an enum. If we do want to enforce internal invariants, we need to add an unnecessary struct wrapper
on top of it.

```rust
enum Es {
    Empty,
    Ascii(String),
    Utf8(String),
    Binary {
        bytes: Vec<u8>,
        valid_utf8_len: usize,
    }
}
// we cannot safely prevent people from constructing `Es::Ascii("🙀".to_owned())`
// or `Es::Binary { bytes: vec![0xff], valid_utf8_len: 1 }`,
// so we cannot make `EncodedStringInternal` public directly.
// Instead we need to wrap it in another struct:
pub struct EncodedString(Es);
```

Examples of wrapper structs in the standard library only due to privacy:

| Outer struct type | Inner enum type |
|------------------:|:----------------|
| [`core::char::ParseCharError`](https://doc.rust-lang.org/core/char/struct.ParseCharError.html) | `CharErrorKind` |
| [`core::char::EscapeDefault`](https://doc.rust-lang.org/core/char/struct.EscapeDefault.html) | `EscapeDefaultState` |
| [`core::num::ParseFloatError`](https://doc.rust-lang.org/core/num/struct.ParseFloatError.html) | `FloatErrorKind` |
| [`alloc::collections::btree_set::Difference`](https://doc.rust-lang.org/alloc/collections/btree_set/struct.Difference.html) | `DifferenceInner` |
| [`alloc::collections::btree_set::Intersection`](https://doc.rust-lang.org/alloc/collections/btree_set/struct.Intersection.html) | `IntersectionInner` |
| [`std::backtrace::Backtrace`](https://doc.rust-lang.org/std/backtrace/struct.Backtrace.html) | `Inner` |
| [`std::ffi::FromBytesWithNulError`](https://doc.rust-lang.org/std/ffi/struct.FromBytesWithNulError.html) | `FromBytesWithNulErrorKind` |
| [`std::io::Error`](https://doc.rust-lang.org/std/io/struct.Error.html) | `Repr` |

In Rust 1.40, we have landed `#[non_exhaustive]` ([RFC #2008]), and in Rust 1.41 we have
*syntactical* support of enum variant privacy ([PR #66183]). These features should make it natural
to support private enum variants *semantically*.

# Guide-level explanation
[guide-level-explanation]: #guide-level-explanation

Let Rust understand visibility on enum variants.

```rust
// All variants and fields are public.
pub enum EsPub {
    pub Empty,
    pub Ascii(pub String),
    pub Utf8(pub String),
    pub Binary {
        pub bytes: Vec<u8>,
        pub valid_utf8_len: usize,
    }
}

// All variants and fields are private (within current module)
pub enum EsPriv {
    pub(self) Empty,
    pub(self) Ascii(String),
    pub(self) Utf8(String),
    pub(self) Binary {
        bytes: Vec<u8>,
        valid_utf8_len: usize,
    }
}

// Different variants have different visibilities
pub enum EsPartial {
    // This variant is public
    pub Empty,
    // This is private
    pub(self) Ascii(String),
    // This is public to parent module
    pub(super) Utf8(pub(super) String),
    // This is public to current crate
    pub(crate) Binary {
        // This is still public to current crate only, capped by the variant.
        pub bytes: Vec<u8>,
        // Without explicit visibility, this field is private.
        valid_utf8_len: usize,
    }
}
```

Either all variants have explicit visibilities, or none of the variants have explicit visibilities.
Mixing them is an error.

```rust
// Current situation. All variants and fields are public.
pub enum EsDefaultPub {
    Empty,
    Ascii(String),
    Utf8(String),
    Binary {
        bytes: Vec<u8>,
        valid_utf8_len: usize,
    }
}

// DISALLOWED in this RFC, mixing of explicit and implicit visibilities
pub enum EsNotAllowed1 {
    pub Empty, // <-- this `pub` is not allowed
    Ascii(String),
    Utf8(String),
    Binary {
        bytes: Vec<u8>,
        valid_utf8_len: usize,
    }
}

// DISALLOWED in this RFC, mixing of explicit and implicit visibilities
pub enum EsNotAllowed2 {
    Empty,
    Ascii(String),
    Utf8(pub String), // <-- this `pub` is not allowed
    Binary {
        bytes: Vec<u8>,
        valid_utf8_len: usize,
    }
}
```

If an enum variant is not visible in a scope, the enum itself is treated as if it is non-exhaustive.
For instance, at crate root the `EsPartial` enum would look like:

```rust
#[non_exhaustive]
enum EsPartial {
    Empty,
    #[non_exhaustive]
    Binary {
        bytes: Vec<u8>,
    },
}
```

```rust
// Assume we are at crate root.

// This line should fail because `EsPartial::Ascii` is private.
let _ = EsPartial::Ascii("😏".to_owned());

// This line should fail because `EsPartial::Binary::valid_utf8_len` is private.
let _ = EsPartial::Binary { bytes: vec![0xff], valid_utf8_len: 1 };

// This line should fail because not all fields are provided.
let _ = EsPartial::Binary { bytes: vec![0xff] };

// This line should succeed.
let _ = EsPartial::Empty;

match &es {
    // This arm should fail because `EsPartial::Ascii` is private.
    EsPartial::Ascii(_) => {}

    // This arm should fail because `valid_utf8_len` is private.
    EsPartial::Binary { bytes, valid_utf8_len } => {}

    // This arm should fail because not all fields are matched.
    EsPartial::Binary { bytes } => {}

    // This arm should succeed.
    EsPartial::Binary { bytes, .. } => {}

    // This arm should succeed.
    EsPartial::Empty => {}

    // This arm is required to exhaust all options.
    _ => {}
}
```

# Reference-level explanation
[reference-level-explanation]: #reference-level-explanation

## Syntax

Explicit visibilities can be added to enum variants and fields.

To avoid misunderstanding, in the 2015 and 2018 editions we require

1. either all enum variants have explicit visibility, or all variants have implicit visibility.
2. if an enum variant has implicit visibility, its fields cannot have any explicit visibility.

We do not dictate how these rules should become in the next editions.

## Declaration

When an enum variant has an explicit visibility, the implicit visibility of this variant's fields
become `pub(self)` instead of `pub`.

A field's visibility is capped by its containing enum variant. A variant's visibility is capped by
its containing enum.

```rust
pub(in x::y::z) enum E {
    // actual visibility = pub(in x::y::z).
    pub(in x::y) V (
        // actual visibility = pub(in x::y::z::w).
        pub(in x::y::z::w) u16,
        // actual visibility = pub(in x::y::z).
        pub u32,
        // actual visibility = implicit = pub(self).
        u8,
    ),
    // actual visibility = pub(self).
    pub(self) W,
}
```

## Usage

Private enum variants and fields behave just like other items. In particular private enum variants
should be compatible with [RFC #2593][] (enum variant types), where the variant types are treated
like structs of their own.

A restricted variant cannot be re-exported beyond its scope ([RFC #2145]).

```rust
pub mod a {
    pub use E::Priv; //~ ERROR [E0365]: `E::Priv` is private, and cannot be re-exported
    pub enum E {
        pub(self) Priv,
    }
}
```

A restricted variant or field cannot be named outside of its visible modules. The behavior is
similar to `#[non_exhaustive]` ([RFC #2008]), except that the limitation kicks in even within the
same crate.

1. if an enum has private variants, matching this enum requires a match-all arm for exhaustiveness.
2. if an enum variant has private fields, matching this variant requires `..` for exhaustiveness.
3. an enum variant with private fields cannot be instantiated, not even through FRU ([RFC #736]).

```rust
match es {
    es2 @ EsPartial::Binary { bytes: _, .. } => {
        let _es3 = EsPartial::Binary { bytes: vec![0xff], ..es2 };
        //~^ ERROR [E0451]: field `valid_utf8_len` of enum variant `EsPartial::Binary` is private
    }
    _ => {}
}
```

# Drawbacks
[drawbacks]: #drawbacks

* Adding `pub(self)` everywhere is annoying, impairs readability, and is a rule which does not
    appear anywhere else.

    > I'm saying that, from my perspective, the "`pub`/`pub(X)` everywhere or no keywords on any of
    > them" fix is such an uncharacteristic bodge that it would be a stain of Rust's grammar.
    >
    > — <https://github.com/rust-lang/rfcs/pull/2028#issuecomment-308198711>

* It is rare to expose some variants and keep the rest private. If we want to hide all variants,
    the wrapper-struct solution already works.
* The implicit visibility of enum variants still differ from struct/union fields.
* The implicit visibility of a field depends on whether the enum variant's visibility is explicit.

# Rationale and alternatives
[rationale-and-alternatives]: #rationale-and-alternatives

## Mixing implicit and explicit visibilities

For all items in Rust except enum variants and trait items, when the visibility is unspecified it
defaults to `pub(self)`. Enum variants (and its fields) and trait items did not allow visibility and
is inherited from its containing enum or trait.

If we allow explicit visibilities on them, it would be confusing whether the implicit visibility
should follow the normal "struct" rule (implicit means `pub(self)`) or old "enum" rule (implicit
means `pub`).

As a compromise, in the current editions (≤2018) we require either all visibilities on enum variants
are implicit (which means `pub`), or all visibilities are explicit.

## Meaning of implicit visibility in future editions

We may change "implicit means `pub`" to "implicit means `pub(self)`" in future editions, but such
transition is very hard, if not impossible. If we can find a suitable solution, the *fastest* time
table would be

| Edition | Implicit visibility behavior |
|---------|------------------------------|
| 2015    | `pub`                        |
| 2018    | `pub` but deprecated         |
| 2021    | error                        |
| 2024    | `pub(self)`                  |

The problem of changing the meaning of implicit visibility are:

1. Technically, we need to determine the behavior of cross-edition of macro invocation, in
    particular the implicit visibility has zero tokens to associate the edition on (unlike `catch`
    or `dyn`).

2. The implicit visibility is currently used in every enum since this is the only option.
    Deprecating this would be very disruptive even with `rustfix`.

3. Moving from "deprecated" to "hard error" in 2018 → 2021 is questionable. According to [RFC #2052],
    such move is *only available when the deprecation is expected to hit a relatively small
    percentage of code*, but certainly implicit visibility of enum variant is not the case. The
    edition mechanism prefers changing this to a deny-by-default lint. Such lint can still be turned
    off, meaning we will be stuck having a deprecated "implicit means `pub`" behavior forever.

4. The exported behavior will silently change if we upgrade the code directly from 2015 to 2024.

On the other hand, we could go the other direction, where we recognize the two kinds of implicit
visibility cannot be unified, and embrace "implicit means `pub`" for enum variants. Declaration like
this can be allowed immediately at the current edition:

```rust
pub enum Es1 {
    Empty,                                  // public
    pub(self) Ascii(String),                // private (the field is capped to private)
    Utf8(String),                           // public (the field is also public)
    Binary {                                // public
        bytes: Vec<u8>,                     //  - public
        pub(self) valid_utf8_len: usize,    //  - private
    }
}
```

Note that the implicit visibility of fields (always `pub`) differ from this RFC (`pub` if variant
has implicit visibility, `pub(self)` if variant has explicit visibility).

## Implicit visibility of enum variant fields

In the current RFC, if an enum variant has an explicit visibility, its fields switch from "implicit
means `pub`" to "implicit means `pub(self)`". The alternatives are:

1. implicit means `pub(self)` (= this RFC)
2. implicit means `pub` (= keep existing behavior)
3. disallow implicit visibility like the variants themselves

We choose behavior 1 over 2, because fields are more like structs which uses "implicit means
`pub(self)`".

We choose behavior 1 over 3, because adding `pub(self)` before every field is too noisy, especially
for tuple variants.

## Granularity of privacy

Associating visibilities to enum variants allow us to partially expose the variants of an enum,
which is not possible today. However, it is questionable whether this flexibility is a good idea. If
we just want to hide all variants, we could e.g. use an attribute to control the entire enum:

```rust
#[variant_pub(self)] // = all variants and their fields are `pub(self)`
pub enum E { ... }
```

We do not go this route, because

1. Using an attribute to control visibility does not fit in with other items of the language.
2. Rust 1.41 already supported explicit visibility on enum variant *syntactically*, so it is natural
    to assign *semantics* on it.

# Prior art
[prior-art]: #prior-art

## [RFC #2028][] (Privacy for enum variants and trait items)

This RFC is almost the same as [RFC #2028], except that RFC #2028 treats implicit visibility as `pub`,
while this RFC rejects mixed implicit/explicit visibility. Such possibility was discussed in the PR
thread without conclusion.

RFC #2028 also covers trait items which is out-of-scope for this RFC.

RFC #2028 was closed in favor of [RFC #2008][] (Future-proofing enums/structs with `#[non_exhaustive]`
attribute), but there are situations which private enum variants can handle but non-exhaustive enums
cannot, and vice-versa.

# Unresolved questions
[unresolved-questions]: #unresolved-questions

None yet.

# Future possibilities
[future-possibilities]: #future-possibilities

## Trait items

Rust 1.41 also added syntactical support of explicit visibility on trait items.
We could apply the all-or-nothing approach on trait item visibility too.

```rust
pub trait Trait {
    pub fn public_method(&self);

    pub(self) fn internal_details(&self) {
        self.public_method();
    }

    fn also_public_method(&self);
    //~^ ERROR: Cannot mix implicit and explicit visibility
    // (suggest adding a `pub`)
}
```

Ideas related to private trait items were previously proposed in

* [RFC #52][] (change to `priv` by default — rejected due to time limit to release 1.0)
* [RFC #227][] (require explicit `pub` on all items — rejected because putting `pub` everywhere is a
    churn, the behavior inside `impl` is unclear, and there is workaround of the main motivation
    (sealed trait))
* [RFC #2028][] (keep `pub` by default, prohibit visibility inside `impl` — closed, plus trait
    wasn't the main motivation at all)

[RFC #52]: https://github.com/rust-lang/rfcs/pull/52
[RFC #227]: https://github.com/rust-lang/rfcs/pull/227
[RFC #736]: https://github.com/rust-lang/rfcs/blob/master/text/0736-privacy-respecting-fru.md
[RFC #2008]: https://github.com/rust-lang/rfcs/blob/master/text/2008-non-exhaustive.md
[RFC #2028]: https://github.com/rust-lang/rfcs/pull/2028
[RFC #2052]: https://github.com/rust-lang/rfcs/blob/master/text/2052-epochs.md
[RFC #2145]: https://github.com/rust-lang/rfcs/blob/master/text/2145-type-privacy.md
[RFC #2593]: https://github.com/rust-lang/rfcs/pull/2593
[PR #66183]: https://github.com/rust-lang/rust/pull/66183/
