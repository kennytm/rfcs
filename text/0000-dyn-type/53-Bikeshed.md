# Alternatives

This section lists some arbitrary decisions not related to the semantics.

<!-- TOC depthFrom:2 -->

- [Naming](#naming)
    - [Associated type `Meta`](#associated-type-meta)
    - [Trait `Object`](#trait-object)
    - [Trait `DynSized`](#trait-dynsized)
    - [Trait `RegularSized`](#trait-regularsized)
    - [Trait `InlineSized`](#trait-inlinesized)
    - [Functions `into_raw_parts`/`from_raw_parts`](#functions-into_raw_partsfrom_raw_parts)
    - [Function `compact_size_of`](#function-compact_size_of)
- [Syntax](#syntax)

<!-- /TOC -->

<!-- spell-checker:ignore japaric’s -->

## Naming

### Associated type `Meta`

There was no unified name for the concept, although “metadata” seems the most common. The name
`Meta` is the same as that in [RFC #1524]. Other potential names:

* Meta
* Metadata
* Info (used in [@japaric’s draft])
* Extra
* ExtraInfo

### Trait `Object`

The name `Object` is picked since this is the base class in Java. A better name is `Any`, but we
cannot repurpose `std::any::Any` due to the `'static` bound ([RFC issue #2280]). The name should
convey idea that it is the base trait of everything. Example alternatives:

* Object
* Base
* Bottom
* Type

### Trait `DynSized`

A trait implements for types which we can know the size at run-time. The name `DynSized` is taken
from [RFC #1993].

* DynSized
* DynamicSized
* RuntimeSized

### Trait `RegularSized`

This is called “regular” because all Rust types before introducing `extern type` can be described by
this sizing method.

It should not be called “fat” because `Sized` types also implement `RegularSized` but are thin.

### Trait `InlineSized`

This is called “inline” because the sizing information is stored directly in-line with the memory.

It should not be called “thin” because foreign types are thin but do not implement `InlineSized`.

### Functions `into_raw_parts`/`from_raw_parts`

These are named after `std::slice::from_raw_parts` as they do exactly the same thing. However, this
also means these two functions can easily be confused with each other.

* `into_raw_parts`/`from_raw_parts`
* `repr`/`new` (from [@japaric’s draft])
* `disassemble`/`assemble` (from [this comment][RFC #1524/comment 775])
* `decompose`/`compose`
* `from_fat`/`into_fat`


### Function `compact_size_of`

* `compact_size_of`
* `inner_size_of` (suggested in [RFC issue #1397])

[@japaric’s draft]: https://github.com/japaric/rfcs/blob/unsized2/text/0000-unsized-types.md
[C++’s standard layout]: http://en.cppreference.com/w/cpp/language/data_members#Standard_layout
[RFC #1524/comment 775]: https://github.com/rust-lang/rfcs/pull/1524#issuecomment-272020775

## Syntax

The custom DST declaration syntax proposed by this RFC is:

```rust
dyn type Dst<T>(C; M) where T: Bounds;
dyn type Dst<T>(C; ..) where T: Bounds;
```

This requires 2 words to introduce the item, similar to `extern crate` and `auto trait`. While it is
possible to just use `dyn Dst<T>(...)`, we feel that it may have conflict with the trait object type
syntax `dyn Fn(X, Y)`, and thus the keyword `type` is inserted next to it.

As an alternative to `dyn type`, we could introduce two contextual keywords

```rust
regular_sized Dst<T>(C; M) where T: Bounds;
inline_sized Dst<T>(C; ..) where T: Bounds;
```

Instead of `..`, we could specify the DST kinds through a contextual keyword

```rust
dyn type Dst<T>(C; regular: M) where T: Bounds;
dyn type Dst<T>(C; inline) where T: Bounds;
```

We could use a other separators instead of `;`, and also other brackets. Using `;` draws similarity
to `[T; n]`.

```rust
dyn type Dst(C; M);
dyn type Dst[C; M];
dyn type Dst { C; M }

dyn type Dst(C, M);
dyn type Dst[C, M];
dyn type Dst { C, M }
```

[RFC #738]: http://rust-lang.github.io/rfcs/0738-variance.html
[RFC #1524]: https://github.com/rust-lang/rfcs/pull/1524
[RFC #1993]: https://github.com/rust-lang/rfcs/pull/1993
[RFC issue #997]: https://github.com/rust-lang/rfcs/issues/997
[RFC issue #1397]: https://github.com/rust-lang/rfcs/issues/1397
[RFC issue #2190]: https://github.com/rust-lang/rfcs/issues/2190
[RFC issue #2255]: https://github.com/rust-lang/rfcs/issues/2255
[RFC issue #2280]: https://github.com/rust-lang/rfcs/issues/2280
[PR #46108]: https://github.com/rust-lang/rust/pull/46108