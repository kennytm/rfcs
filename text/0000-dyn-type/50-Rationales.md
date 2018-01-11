# Rationales

This section lists the rationales why some minor semantic decisions are made this way.

<!-- TOC depthFrom:2 -->

- [Variance of custom DST](#variance-of-custom-dst)
- [`DynSized` as a (non-)default bound](#dynsized-as-a-non-default-bound)
- [Trait safety](#trait-safety)
- [(Not) Exposing the “Content” type](#not-exposing-the-content-type)

<!-- /TOC -->

## Variance of custom DST

We treat the variance of `dyn type Dst<T>(C; M)` as the same as that of `(C, M)`, for simplicity in
user’s understanding as well as correctness in implementation.

As an example showing why this is practically a better solution (even if wrong theoretically),
consider a weird DST:

```rust ,ignore
dyn type Weird<T>((), regular: PhantomData<T>);
```

Now check the type `&mut Weird<T>`. A `&mut` reference is invariant in its borrowed content.
However, this DST is actually represented as `(&mut (), PhantomData<T>)`, which is covariant! This
is totally unexpected to the reader.

To check the soundness, we compare `P<(C, M)>` and `(P<C>, M)` between different variances, where
`P` is a reference or pointer. We see the following results:

* If `P<T>` is covariant (e.g. `&T`), `P<(C, M)>` and `(P<C>, M)` have exactly the same variance.
* If `P<T>` is invariant (e.g. `&mut T`), `P<(C, M)>` is the more conservative choice.
* If `P<T>` is bivariant, `(P<C>, M)` is the more conservative choice.
* If `P<T>` is contravariant, the two choices are incompatible.

The last two cases (`P<T>` being bivariant or contravariant) are in fact irrelevant:

1. In Rust, no types can actually be bivariant, since it will cause error E0392 “parameter is never
    used”.
2. Built-in references and pointers are never contravariant.
3. The only built-in contravariant type, `fn(T)`, is always a thin pointer, thus irrelevant.
4. Custom “contravariant smart pointer” like `(PhantomData<fn(T)>, T::Meta)` does not matter, since
    we are referring to `T::Meta` explicitly, forcing `T` to be invariant.

Anyway, if these arguments are not convincing enough, or if we want to defy [RFC #738] and support
declared variance…

```rust ,ignore
struct ContraPtr<#[contravariant] T: ?Sized>(*mut T);
```

… one could always issue an error when the metadata type is not invariant or bivariant.

```
error[E9999]: metadata type cannot depend on generic parameters
 --> src/lib.rs:1:31
  |
1 | dyn type Weird<T>((), regular: PhantomData<T>);
  |                                ^^^^^^^^^^^^^^
```

<details><summary>Enumeration of variances</summary>

| C | M | `P<(C, M)>` | `(P<C>, M)` | Note    |
|:-:|:-:|:-----------:|:-----------:|:--------|
| + | + | +P          | +P ∧ +      | `P<(C, M)>`’s variance is too loose (− or ∞) when `P` is − or ∞ |
| + | 0 | 0           | 0           |         |
| + | − | 0           | +P ∧ −      |         |
| + | ∞ | +P          | +P          |         |
| 0 | + | 0           | 0           |         |
| 0 | 0 | 0           | 0           |         |
| 0 | − | 0           | 0           |         |
| 0 | ∞ | 0           | 0           |         |
| − | + | 0           | −P ∧ +      |         |
| − | 0 | 0           | 0           |         |
| − | − | −P          | −P ∧ −      | `P<(C, M)>`’s variance is too loose (+ or ∞) when `P` is − or ∞ |
| − | ∞ | −P          | −P          |         |
| ∞ | + | +P          | +           | `P<(C, M)>` has opposite variance (−) when `P` is − |
| ∞ | 0 | 0           | 0           |         |
| ∞ | − | −P          | −           | `P<(C, M)>` has opposite variance (+) when `P` is − |
| ∞ | ∞ | ∞           | ∞           |         |

* \+ = covariant
* 0 = invariant
* − = contravariant
* ∞ = bivariant
* +P = variance of `P<T>`
* −P = contraposition of variance of `P<T>` (swap + and −)
* *x* ∧ *y* = [greatest-lower-bound]

[greatest-lower-bound]: https://github.com/rust-lang/rust/blob/53a6d14e5/src/librustc_typeck/variance/xform.rs

</details>

## `DynSized` as a (non-)default bound

This RFC does not propose `DynSized` as a default bound. The side-effect to existing library is
that,

* Accessing the offset of an unsized struct may cause runtime panic, and the best we could do is
    emit a lint.
* We can never make `size_of_val`, `Box<T>` etc to require the `DynSized` bound due to stability
    guarantee.

An alternative is to make `DynSized` a default bound, and user must write `?DynSized` to opt-out.
The advantage is

* We can iteratively relax the bound from `?Sized` to `?DynSized` without breaking backward
    compatibility, and thus does not need to introduce any new lints or attributes, nor wait for a
    new epoch.

The disadvantage of this is

* Majority of `?Sized` usage does not require `DynSized`, as we have seen in the survey. Introducing
    `?DynSized` leaves the ecosystem in a less flexible state, which induces “update pressure” to
    package maintains to check whether the bound should be relaxed.

Further discussion of `?DynSized` can be found in [RFC issue #2255] and [PR #46108].

## Trait safety

This RFC introduced or modified 7 core traits. Out of which, `InlineSized` and `Unsized` are
designated unsafe to implement, and `RegularSized` is considered safe to implement. The rest cannot
be implemented manually and thus safety is irrelevant.

| Trait | Safety |
|-------|--------|
| Object | (sealed) |
| DynSized | (sealed) |
| Aligned | (sealed) |
| Sized | (sealed) |
| RegularSized | safe |
| InlineSized | unsafe |
| Unsize | unsafe |

`InlineSized` is unsafe due to `size_of_ptr`. Suppose we can mutably access the content of `CStr`,
and the user writes or remove a `\0` somewhere, the size will be completely changed and causes
buffer overflow. `InlineSized` types are extremely unsafe if the type allows unconstrained mutable
access, and the implementor must uphold the contract that *no safe code* can change the size via
`&mut Self`.

On the other hand, `RegularSized` is safe. This is because the size information, recorded in the
metadata, is stored outside of the type’s memory space. Thus even with an `&mut Self` the size is
still immutable.

`Unsize` is unsafe because we need to guarantee the source and target types have the same memory
representation.

We may argue that `RegularSized` can actually be unsafe because we can’t ensure the implementation
is pure.

```rust
impl RegularSized for Shapeshifter {
    fn size_of_meta(meta: Self::Meta) -> usize {
        random()
    }
}
// allocating a `Box<Shapeshifter>` is going to be fun...
```

## (Not) Exposing the “Content” type

In a `dyn type` declaration, the “content” type is only used to determine alignment, variance and
auto trait implementation. The type itself has no meaning to the DST otherwise.

```rust ,ignore
// these two are equivalent.
dyn type Mat<T>(T; MatMeta);
dyn type Mat<T>([[[T; 12]; 34]]; MatMeta);
```

Because of this, we also do not include the type in the `Object` trait, unlike [@japaric’s draft]
which provided the `Data` associated type for this. The lack of such associated type also forces us
to make `into_raw_parts`/`from_raw_parts` use an untyped pointer.

```rust ,ignore
fn into_raw_parts<T: Object + ?Sized>(ptr: *const T) -> (*const u8, T::Meta);
//                                                       ^~~~~~~~~
unsafe fn from_raw_parts<T: Object + ?Sized>(ptr: *const u8, meta: T::Meta) -> *const T;
//                                                ^~~~~~~~~
```

We could expose the content type to avoid the ugly `*const u8` casts.

```rust ,ignore
trait Object {
    type Content: Sized;
}
impl<T> Object for T {
    type Content = Self;
}
impl<T> Object for [T] {
    type Content = T;
}
impl Object for dyn Trait {
    type Content = ();
}
```

But the content for struct and tuples are not so simple. One will need to generate a new struct to
represent this content type

```rust ,ignore
struct Foo<T, U: ?Sized> {
    a: T,
    b: u8,
    c: U,
}
impl<T, U: ?Sized> Object for Foo<T, U> {
    type Content = Foo_Content<T, U>;
}
// auto generated struct
#[repr(rustc_maybe_unsized_tail)]
struct Foo_Content<T, U: ?Sized> {
    a: T,
    b: u8,
    c: U::Content,
}
```

There is also the issue of inconsistent overlapping implementations: the `Content` of `Foo<u8, u8>`
will be `Foo<u8, u8>` from the sized-type angle, but `Foo_Content<u8, u8>` from the DST-struct
angle.

Given the complexity related to the content type, this RFC decides not to support it.
