# Custom DST from scratch

This section provides an in-depth description about how custom DST is designed to the current form.

<!-- TOC depthFrom:2 -->

- [What do we want to support?](#what-do-we-want-to-support)
- [Syntax](#syntax)
- [`Object` trait](#object-trait)
- [Automatically implementing `Object` for every type](#automatically-implementing-object-for-every-type)
- [Customizing size and alignment](#customizing-size-and-alignment)
- [Reduction](#reduction)
- [Aliasing](#aliasing)
- [Unsized enum](#unsized-enum)
- [Deallocation](#deallocation)
- [Unsizing](#unsizing)
- [Regular and inline DST](#regular-and-inline-dst)
- [Allocation](#allocation)
- [Stability guarantees: Survey of existing DST usage](#stability-guarantees-survey-of-existing-dst-usage)

<!-- /TOC -->

<!-- spell-checker:ignore japaric’s alloca’ed -->

## What do we want to support?

“Custom DST” as a concept itself is not precise enough, if we just say we want to “allow customizing
the metadata type and `size_of_val` function” without going into details, we may make the design too
narrow, or accidentally block more general applications, or even worse, leads ourselves into
inconsistency. Here we first list all scenarios we want this RFC to achieve.

1. Support 2D matrix `Mat<T>`, the first canonical example when introducing custom DST.

    * This means a custom DST must be generic, which leads to the question of *variance*.
    * We want to be able to coerce `&[[T; m]; n]` → `&Mat<T>`, similar to `&[T; m]` → `&[T]`, which
        means we should allow *custom unsizing*.

2. Support thin C string `CStr`, the second canonical example when introducing custom DST.

    * Unlike other DSTs, the `size_of_val` of `CStr` can only be computed by inspecting the memory
        content.
    * C strings are supposed to be passed to C libraries, and thus our custom DST should consider
        how it works with *FFI*.

3. Support using WTF-8 slice (`OsStr` on Windows) with the `Pattern` 2.0 API (a better [RFC #1309]),
    i.e. it should be valid to slice a surrogate pair in half.

4. Support changing the `OsStr` representation on Windows as a union of `str` and `[u16]`, while
    keeping the ability to slice the `OsStr` (inspired by [this discussion thread][i.rlo/6277])

5. Support bit slice (indicated by [this comment][RFC #1524/comment 5527])

6. Support Pascal strings, length-prefixed arrays, and C-style flexible array structures.

7. Support turning most fat pointers into thin pointers (inspired by
    [this comment][RFC #1909/comment 1432]).

8. Allow using the same custom DST construct to cover existing DSTs: slices, trait objects and
    foreign types (`extern type`, [RFC #1861]).

    * Be aware that the *alignment* of trait object depends on the metadata value.
    * Be also aware that foreign types has no size or alignment even at runtime.

9. Ensure unsized struct still works with all custom DSTs mentioned above.

10. Ensure `&T`, `*const T`, `Box<T>` and `Rc<T>` work properly, if not simpler.

11. Ensure existing code taking `T: ?Sized` keep compiling even after introducing custom DSTs.

12. Investigate the possibility of unsized *enum*.

13. Investigate how to *allocate* a custom DST besides unsizing.

    * For instance, a `Box<CStr>` cannot be constructed through unsizing.

[i.rlo/6277]: https://internals.rust-lang.org/t/make-std-os-unix-ffi-osstrext-cross-platform/6277
[RFC #1524/comment 5527]: https://github.com/rust-lang/rfcs/pull/1524#issuecomment-281415527
[RFC #1909/comment 1432]: https://github.com/rust-lang/rfcs/pull/1909#issuecomment-330901432

## Syntax

While there are many different DST examples, the memory content of all of these can be safely
expressed as an ordinary DST struct:

```rust ,ignore
struct Mat<T>([T]);
struct CStr([c_char]);
struct Wtf8Buf([u8]);
#[repr(align(2))] struct OsStr([u8]);
struct BitSlice([u8]);
struct PArray<T>(usize, [T]);
struct Thin<T: ?Sized>(T::Meta, T);
```

What makes custom DST different is just their metadata.

We opt for declaring a custom DST using a dedicated syntax, unlike [RFC #1524] which expresses this
via a normal struct declaration + an impl, since being a custom DST is a property of the type
itself. This is similar to the auto trait syntax, changing from a normal trait + `impl Trait for ..`
to a dedicated syntax `auto trait Trait {}`.

Our custom DST should provide their custom metadata, and the underlying DST struct representation.
Therefore we choose our first syntax like this:

```rust ,ignore
dyn struct CStr(())([c_char]);
//              ^~ ^~~~~~~~~~
//               |  underlying representation
//               |
//               metadata

#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
struct MatMeta {
    height: usize,
    width: usize,
    stride: usize,
}
dyn struct Mat<T>(MatMeta) {
    elements: [T],
}

enum Encoding {
    Utf8,
    Ucs2,
}
#[repr(align(2))]
dyn struct OsStr(Encoding)([u8]);

dyn struct Thin<T: ?Sized>(()) {
    header: T::Meta,
    content: T,
}
```

“`dyn`” is picked because it means dynamic, and will likely be converted to a keyword thanks to
`dyn Trait` ([RFC #2113]), so we don’t need to introduce another contextual keyword. Adding a
`struct` makes it spell out “dynamic struct“, as well as preventing potential misinterpretation as a
`dyn Trait`.

## `Object` trait

When manipulating generic DSTs, we often need to use its metadata type. This can be exposed via
associated type if the DST implements some trait.

```rust
trait Object {
    type Meta: Sized;
}
```

That is, every type `&Dst` will be represented as the tuple `(&Something, Dst::Meta)` in memory.

We need to ensure `&T` and `*T` still works, i.e. all existing traits implemented for these pointer
types must not be affected by custom DST. This imposes many restrictions on `Meta`:

* `Copy` — `&T` and `*T` are both `Copy`
* `Send` — `&T` is `Send` if `T` is `Sync`, without considering `T::Meta`.
* `Sync` — `&T` is `Sync` if `T` is `Sync`, without considering `T::Meta`.
* `Ord` — `*T` is ordered by the pointer value + metadata together. Demonstration:

    ```rust
    let a: &[u8] = &[1, 2, 3];
    let b: &[u8] = &a[..2];
    let a_ptr: *const [u8] = a;
    let b_ptr: *const [u8] = b;
    // the thin-pointer part are equal...
    assert_eq!(a_ptr as *const u8, b_ptr as *const u8);
    // but together with the metadata, they are different.
    assert!(a_ptr > b_ptr);
    ```

* `Hash` — `*T` hashes the pointer value + metadata together.
* `'static` — `*T` should outlive `T`, thus `T::Meta` should outlive `T`. There is no `'self`
    lifetime, nor it makes sense to complicate the matters by making `Meta` a GAT, thus the
    `'static` bound.

Thus, the final constraint would be:

```rust ,ignore
trait Object {
    type Meta: Sized + Copy + Send + Sync + Ord + Hash + 'static;
}
```

In principle `Meta` should be further bound by `UnwindSafe` and `RefUnwindSafe`, but these traits
are defined in libstd instead of libcore, so they cannot be included in the bound. One may need to
explicitly opt-out of `RefUnwindSafe` according to the metadata type.

```rust ,ignore
impl<T: ?Sized> !RefUnwindSafe for T {}
impl<T: ?Sized> RefUnwindSafe for T where T::Meta: UnwindSafe {}
```

Fortunately, `RefUnwindSafe` is only excluded for `UnsafeCell<T>`, and `UnwindSafe` is only excluded
for `&mut T`, both of which are satisfied by the `Copy` bound already.

The `Meta` type should also be bound by `Freeze` (i.e. cell-free), but `Freeze` is a private trait,
thus cannot be exposed to public. Again, `Copy` already eliminated the possibility of having cells.

## Automatically implementing `Object` for every type

The `Meta` associated types should be available for sized types. This can be done by making `Object`
special, and be implemented by the compiler like the `Sized` trait.

| Type | Meta |
|:-----|:-----|
| All sized types, including closures and generators | `()` |
| Slice `[T]` | `usize` |
| `str` | `usize` |
| `dyn Trait` | `&'static TraitMeta<TraitVtable>` |
| `extern type` | `()` |
| ADTs | `<LastField>::Meta` |
| `dyn struct` | `Meta` |

## Customizing size and alignment

The size and alignment are arbitrary functions and have to be provided by user.

```rust ,ignore
trait Object {
    type Meta: Copy + Send + Sync + Ord + Hash + 'static;
    fn size_of_val(&self) -> usize;
    fn align_of_val(&self) -> usize;
}
```

Rust does not support “partial trait implementation”, which means we cannot ask the user to
implement `Object` again.

```rust ,ignore
dyn type Slice<T>(T; usize);
// Wrong.
impl<T> Object for Slice<T> { ... }
```

This can be fixed by delegating the actual implementation to a second trait, `DynSized`, and the
automatically-implemented `Object` calls methods in this second trait. That means, a custom DST
declaration will expand to

```rust ,ignore
dyn struct Dst(M)(C);
impl Object for Dst {
    type Meta = M;
    fn size_of_val(&self) -> usize {
        <Self as DynSized>::size_of_val(self)
    }
    fn align_of_val(&self) -> usize {
        <Self as DynSized>::align_of_val(self)
    }
}
```

and the user will need to implement `DynSized` manually.

```rust ,ignore
trait DynSized: Object {
    fn size_of_val(&self) -> usize;
    fn align_of_val(&self) -> usize;
}
```

Now, while `std::mem::{size_of_val, align_of_val}` takes the whole DST reference as input, it may
not make sense for `align_of_val` to use its pointer as input. To wit, consider an unsized struct:

```rust ,ignore
struct S<T: ?Sized> {
    a: u8,
    b: T,
}
let s: &S<Dst> = ...;
let t: &Dst = &s.b;
```

In order to get the address `&s.b`, we first need to find out the offset of `b` in `S<Dst>`. This
requires knowing the alignment of `Dst`, which is `align_of_val(&s.b)`, and that leads to a circular
dependency! Hence, our `align_of_val` should not depend on the pointer part of the reference at all.

```rust ,ignore
trait Object {
    type Meta: Copy + Send + Sync + Ord + Hash + 'static;
    fn align_of_meta(meta: Self::Meta) -> usize;
    fn size_of_val(&self) -> usize;
}
```

The alignment needs to read `Meta` because of how trait objects are implemented. Consider the
types `*S<u8>` and `*S<u16>`.

```text
┏━━━━━━━┓    ┏━━━━━━━━━━━━━━━┓
┃ S<u8> ┃    ┃    S<u16>     ┃
┡━━━┯━━━┩    ┡━━━┯━━━┯━━━━━━━┩
│ a │ b │    │ a │   │   b   │
└───┴───┘    └───┘   └───────┘
0   1   2    0   1   2   3   4
```

Both types can be *coerced* into `*S<dyn Debug>`. The type `S<dyn Debug>` itself does not tell us
the alignment of field `b`. This can only be obtained via the type information stored in the trait
object’s metadata.

## Reduction

Recall that every custom DST has a corresponding ordinary DST struct. We want to be able to treat
every aspect of the custom DST as if the ordinary DST to maintain safety. So what the user should
provide is not `size_of_val`/`align_of_val`, but a function which produces the original DST which we
compute the size and alignment from it instead. We could such process **reduction**.

```rust ,ignore
trait Object {
    type Meta: Copy + Send + Sync + Ord + Hash + 'static;
    type Reduced: ?Sized;
}

trait Reduce: Object {
    fn reduced_meta(&self) -> Self::Reduced::Meta;
}
```

When we create a `dyn struct`, the compiler should provide an anonymous “reduced” struct

```rust ,ignore
dyn struct Mat<T>(MatMeta)([T]);

#[anonymous]
struct Foo_Reduced<T>([T]);

impl<T> Object for Foo<T> {
    type Meta = MatMeta;
    type Reduced = Foo_Reduced<T>;

    fn align_of_meta(meta: Self::Meta) -> usize { /* to be explored later */ }
    fn size_of_val(&self) -> usize { reduce(self).size_of_val() }
}
```

and user just need to provide

```rust ,ignore
impl<T> Reduce for Mat<T> {
    fn reduced_meta(&self) -> usize { // the metadata of [T] is a usize, the length.
        meta(self).len()
    }
}
```

The problem here is that we cannot forward `align_of_meta` to `reduced_meta` since we don’t have
`self` in the first place. This forces us to either make `reduced_meta` take only `Self::Meta`, or
make `align_of_meta` not rely on reduction. To support thin DSTs like `CStr`, `reduced_meta` must be
allowed to read the content, which leaves us with the other option.

This means custom DSTs must have a compile-time alignment. This rules out using trait objects as a
part of custom DSTs. Hopefully this will be a rare case.

To distinguish between trait objects and other DSTs, we have to introduce a new trait, `Aligned`,
which marks the type as having a compile-time alignment. This also has a nice side effect of
relaxing the bounds of `core::mem::align_of`.

## Aliasing

Representing custom DSTs through reduction allows the compiler to manipulate them as if normal Rust
types, but there is a potential hazard regarding borrow-checking.

Let’s revisit matrix. A matrix’s metadata consists of three numbers, the width, height and stride.
The stride can be larger than the width when the rectangular slice does not include all columns.

```
┌┄┄┄┄┬┄┄┄┄┲━━━━┳━━━━┱┄┄┄┄┐  highlighted region:
┆  0 ┆  1 ┃  2 ┃  3 ┃  4 ┆      width = 2
├┄┄┄┄┼┄┄┄┄╊━━━━╋━━━━╉┄┄┄┄┤      height = 2
┆  5 ┆  6 ┃  7 ┃  8 ┃  9 ┆      stride = 5
├┄┄┄┄┼┄┄┄┄╄━━━━╇━━━━╃┄┄┄┄┤
┆ 10 ┆ 11 ┆ 12 ┆ 13 ┆ 14 ┆
└┄┄┄┄┴┄┄┄┄┴┄┄┄┄┴┄┄┄┄┴┄┄┄┄┘
```

In the linear representation as a `[T]`, it will contain `[2, 3, 4, 5, 6, 7, 8]`. Note that the
irrelevant entries `4, 5, 6` are included. This means providing mutable access to the reduced type
is unsafe. Ideally we should represent this memory as `∃w,h,s: [([T; w], [Opaque<T>; s-w]); h]`, but
encoding this thing in the type system is just as error-prone as writing actual checking code, and
thus decided against doing this.

This also means even if we have two `&mut Mat<T>`, there memory may be physically overlapping,
although they are still logically disjoint. It is hard to know what LLVM is going to do with two
`noalias` pointers pointing at different but overlapping memory, if it turns out to cause
mis-compilation ([issue #31681]), we may need to remove `noalias` annotations for custom DSTs.

## Unsized enum

Now let’s consider what if we want to implement unsized enum:

```rust ,ignore
enum E<T: ?Sized, U: ?Sized> {
    A(T),
    B(U),
}
```

We wish unsized enums respect unsize coercion, e.g. `E<[u16; 6], [u32; 3]>` can be coerced into
`E<[u16], [u32]>`.

The metadata is going to be any of `T::Meta` or `U::Meta`, depending on which variant is chosen.
The metadata in one of the three representations:

1. Struct — `struct E::Meta { a: T::Meta, b: U::Meta }`
2. Union — `union E::Meta { a: T::Meta, b: U::Meta }`
3. Enum — `enum E::Meta { A(T::Meta), B(U::Meta) }`

* ***If we picked struct/union as metadata —***

    We cannot correctly implement `Object::align_of_meta`, which we can’t know which variant is
    active. The only way to properly compute the alignment is if it doesn’t depend on the metadata
    at all, i.e. all custom DSTs must be `Aligned`.

* ***If we picked enum as metadata —***

    The discriminant will appear in two places, once inside the memory (cannot be eliminated due to
    unsize coercion), and once in the metadata. This will cause trouble if we cannot ensure the two
    copies are kept in sync. Fortunately, one may not assign to an unsized type even with unsized
    rvalue ([RFC #1909]), which means the discriminant of an unsized enum is immutable once created.

    Also, a sized enum cannot have any metadata, causing a strange discontinuity with its unsized
    counterpart.

We do not decide which representation should be chosen. Though, it does show that aligned DST would
probably be easier to reason with.

## Deallocation

Since we claimed a custom DST has the same memory representation as its reduction, the compiler
could use it to drop its fields. The type can also implement `Drop` if needed. The destructor
(`drop_in_place`) will be generated as:

```rust ,ignore
// Pseudo code for compiler's intrinsic implementation.
pub fn drop_in_place<T: ?Sized>(ptr: *mut T) {
    if !needs_drop::<T>() {
        return;
    }
    if T: Drop {
        T::drop(&mut *ptr);
    }
    if T: Copy || T is union || T is leaf type {
        // do nothing
    } else if T is struct || T is enum || T is custom DST {
        for field in T.fields() {
            drop_in_place(&mut ptr.field);
        }
    }
}
```

The `needs_drop` intrinsic would be relaxed to be allowing unsized types.

```rust ,ignore
// Pseudo code for compiler's intrinsic implementation.
pub const fn needs_drop<T: ?Sized>() -> bool {
    //                     ^~~~~~ relaxed
    if T: Drop {
        true
    } else if T: Copy || T is union || T is leaf type {
        false
    } else if T is struct || T is enum || T is custom DST {
        T.fields().any(|F| needs_drop::<F>())
    } else {
        false
    }
}
```

The `needs_drop` function should return the following when an unsized type is given:

| Type                      | Result                        |
|---------------------------|-------------------------------|
| Slices `[T]`              | `needs_drop::<T>()`           |
| `str`                     | false                         |
| Trait objects `dyn Trait` | true                          |
| `extern type`             | false                         |
| Custom DST                | `needs_drop::<T::Reduced>`    |

See the [Customizing `needs_drop`](0000-dyn-type/52-Extensions#customizing-needs_drop) extension for
further ideas.

## Unsizing

Unsizing is a kind of coercion between two smart pointers `*T` and `*U` where both interprets the
memory content in the same way. And thus unsizing from `*T` to `*U` is mainly a way to fabricate a
correct `U::Meta` value.

```rust ,ignore
impl<T, const n: usize> Unsize<[T]> for [T; n] {
    const UNSIZED_META: usize = n;
}
```

In [RFC #401] where unsizing was first introduced, unsizing is implemented for:

* Arrays to slices (`[T; n]` → `[T]`)
* Concrete types to dynamic trait objects (`T` → `dyn Trait`)
* Sized struct to unsized struct (`(u8, T)` → `(u8, U)` where `T: Unsize<U>`)

With custom DST, we wish to allow custom unsizing as well, for instance it should make sense to
coerce any `[[T; m]; n]` to a `Mat<T>`.

```rust ,ignore
unsafe impl<T, const width: usize, const height: usize> Unsize<Mat<T>> for [[T; width]; height] {
    const UNSIZED_META: MatMeta = MatMeta {
        width,
        height,
        stride: width,
    };
}
```

However, it also makes sense to “unsize” an already unsized type, `[[T; m]]` → `Mat<T>`. And thus
the custom metadata should be an associated function, not an associated constant.

```rust ,ignore
unsafe impl<T, const width: usize> Unsize<Mat<T>> for [[T; width]] {
    fn unsize(height: Self::Meta) -> MatMeta {
        MatMeta {
            width,
            height,
            stride: width,
        }
    }
}
```

This definition has problem with [unsized enum](#unsized-enum). Again recall the 3 choices of
metadata type.

* ***If we picked struct as metadata —***

    Then `Unsize` can be implemented using just the source metadata alone

    ```rust
    unsafe impl<T, const a: usize, U, const b: usize> Unsize<E<[T], [U]>> for E<[T; a], [U; b]> {
        fn unsize(_: Self::Meta) -> E<[T], [U]>::Meta {
            E<[T], [U]>::Meta { a, b }
        }
    }
    ```

    The disadvantage of this representation is wasted space.

* ***If we picked union/enum as metadata —***

    Then `Unsize` will need to actually read the memory content to know which variant is picked.

    ```rust
    unsafe impl<T, const a: usize, U, const b: usize> Unsize<E<[T], [U]>> for E<[T; a], [U; b]> {
        fn unsize(&self) -> E<[T], [U]>::Meta {
            match *self {
                E::A(_) => E::<[T], [U]>::Meta { a },
                E::B(_) => E::<[T], [U]>::Meta { b },
            }
        }
    }
    ```

    This is a huge departure from other coercion rules defined in [RFC #401] which will never read
    from the pointed memory. In particular this means coercing a `*const E` becomes an unsafe
    operation.

In *this* RFC, we suggest only providing the function that maps a metadata to another metadata.

```rust
unsafe trait Unsize<Target: ?Sized> {
    fn unsize(meta: Self::Meta) -> Target::Meta;
}
```

Note that most unsizing implementations requires const generics ([RFC #2000]) to make sense.

## Regular and inline DST

Most requirements of custom DSTs fall into two categories:

* **Regular DSTs, or “fat pointers”**

    Examples: slice, trait object, matrix, `OsStr`, bit slice. These types carry a nonzero metadata,
    and the size can be entirely derived from the metadata alone.

* **Inline DSTs, or “thin pointers”**

    Examples: `CStr`, Pascal strings, length-prefixed arrays. These types has no metadata and thus
    the pointer is thin and can be used in FFI. The size can only be obtained by parsing the memory
    content itself.

To make custom DSTs simpler to create by requiring them only to provide the necessary information,
we restrict the kinds of DSTs to these two.

```rust
trait RegularSized: DynSized {
    fn reduce_with_meta(meta: Self::Meta) -> Self::Reduced::Meta;
}

trait InlineSized: DynSized<Meta = ()> + Aligned {
    fn reduce_with_ptr(ptr: *const u8) -> Self::Reduced::Meta;
}
```

Since the customization of DSTs are now distributed into these two traits, the `DynSized` trait can
now be changed to a simple marker trait.

```rust
trait DynSized: Object {}
```

We also modify the syntax for declaring a custom inline DST.

```rust
dyn struct CStr(..)([c_char]);
//              ^~
```

## Allocation

We want to allow allocating a DST in a box. This means we may need to modify the placement protocol
([RFC #809]). Recall that the placement protocol for sized types `let boxed: P = placer() <- expr()`
work like:

```rust ,ignore
let placer = placer();                  // type is P: Placer<T>
let mut place = placer.make_place();    // type is P::Place: InPlace<T>
let ptr = place.pointer();              // type is *mut T
intrinsics::move_val_init(ptr, expr());
let boxed = place.finalize();           // type is P::Place::Owner, which can be anything sized
```

```
╔════════╗ make_place()  ╔═══════╗
║ placer ║━━━━━━━━━━━━━━▶║ place ║━━━━┓ pointer()
╚════════╝               ╚═══════╝    ┃
                             │        ▼
                             │     ╔═════╗
                             │     ║ ptr ║
                             │     ╚═════╝
                             │        ┃ std::ptr::write() ╔══════╗
                             ┢━︎━━━━━━━┛◀━━━━━━━━━━━━━━━━━━║ expr ║
╔═══════╗                    ┃                            ╚══════╝
║ boxed ║◀━━━━━━━━━━━━━━━━━━━┛
╚═══════╝      finalize()
```

The protocol cannot work directly on DSTs due to the following reasons:

1. Syntactically, we doesn’t yet have “DST expression”. [RFC #1909] is a promising solution allowing
    moving unsized rvalue and copy-initializing a *slice*, but it provides no solution to custom
    DSTs.

2. In terms of the protocol, a DST does not have a known size before evaluating `expr()`, thus the
    placer cannot properly allocate memory with the correct size. We need a language construct to
    evaluate the size of `expr()` *without* actually evaluating `expr()` itself.

This RFC doesn’t try to specify how the protocol should be upgraded to handle unsized boxes.
However, we should modify the associated traits to prepare for the change. The general idea is that,
the compiler should be able to analyze `expr()` and extract the size, alignment, metadata with
minimal evaluation. For instance, the VLA expression `box [elem(); len()]`, we must evaluate `len()`
to get the size, but we can delay `elem()` until the actual `std::ptr::write()` call.

This RFC thus propose to modify the protocol to:

```rust ,ignore
type T = typeof(expr());    // type should be known without evaluating `expr()`...
let size = size_of::<T>();
let align = align_of::<T>();    // and thus size and alignment are known statically...
let placer = placer();
let mut place = placer.make_place(size, align); // we provide the size and alignment when making the place...
let ptr = place.pointer() as *mut T;
intrinsics::move_val_init(ptr, expr());
let boxed = place.finalize(());
```

```
                                                        ╔═══════╗
╔════════╗                                              ║ size, ║
║ placer ║━━┓◀━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━║ align ║
╚════════╝  ┃ make_place()                              ╚═══╤═══╝
            ┃                                               ╎
            ┃              ╔════════╗                       ╎
            ┗━━━━━━━━━━━━━▶║ placer ║━━━┓ pointer()         ╎
                           ╚════════╝   ┃                   ╎
                               │        ▼                   ╎
                               │     ╔═════╗                ╎
                               │     ║ ptr ║                ╎
                               │     ╚═════╝                ╎
                               │        ┃ (initialize)  ╔═══╧═══╗
                               ┢━︎━━━━━━━┛◀━━━━━━━━━━━━━━║ expr  ║
                               ┃                        ╚═══╤═══╝
                               ┃                            ╎
╔═══════╗                      ┃                        ╔═══╧═══╗
║ boxed ║◀━━━━━━━━━━━━━━━━━━━━━┛◀━━━━━━━━━━━━━━━━━━━━━━━║ meta  ║
╚═══════╝        finalize()                             ╚═══════╝
```

* `make_place()` now needs to know the size and alignment, since they cannot be derived from the
    type itself.
* `pointer()` returns an *untyped* pointer (`*mut u8`), since such information is useless for DST
    without its metadata anyway. Even if we do provide the metadata to get a valid `*mut T`, the
    metadata will be useless for filling in bytes.
* Instead, `finalize()` now takes the metadata, and the placer can attach it to the returned `Owned`
    if needed.

## Stability guarantees: Survey of existing DST usage

As a final sanity check for stability, we want to know how the community uses DST. We gather this
information by categorizing DST usage of the “[top 100 packages] + dependencies” (totally 191
packages) provided by Rust playground. We consider a piece of code is “using DST” whenever `?Sized`,
`size_of_val` or `align_of_val` appears.

From the list, many usage patterns are not affected by custom DST, since they often just needs to
give a pointer address to method.

<!-- spell-checker:disable -->

* <details><summary>142 packages (≈76%) do not use any of these DST features</summary>

    ```
    adler32
    advapi32-sys
    atty
    backtrace-sys
    bit-set
    bit-vec
    bitflags
    build_const
    cc
    cfg-if
    chrono
    cmake
    color_quant
    cookie
    crc
    crossbeam
    crypt32-sys
    csv-core
    data-encoding
    dbghelp-sys
    debug_unreachable
    deflate
    docopt
    dtoa
    either
    enum_primitive
    env_logger
    extprim
    filetime
    fixedbitset
    flate2
    foreign-types
    foreign-types-shared
    fuchsia-zircon
    fuchsia-zircon-sys
    futf
    futures-cpupool
    gcc
    getopts
    glob
    hpack
    html5ever
    httparse
    hyper-tls
    idna
    image
    inflate
    iovec
    itoa
    jpeg-decoder
    kernel32-sys
    language-tags
    lazy_static
    lazycell
    libflate
    libz-sys
    log
    lzw
    mac
    markup5ever
    matches
    memchr
    memmap
    mime
    mime_guess
    miniz-sys
    native-tls
    num
    num-bigint
    num-complex
    num-integer
    num-iter
    num-rational
    num-traits
    percent-encoding
    phf_codegen
    phf_generator
    pkg-config
    precomputed-hash
    regex-syntax
    relay
    rustc-demangle
    rustc_version
    safemem
    same-file
    scoped-tls
    scoped_threadpool
    scopeguard
    secur32-sys
    select
    semver
    semver-parser
    serde_codegen_internals
    serde_derive
    serde_derive_internals
    siphasher
    slab
    smallvec
    solicit
    string_cache
    string_cache_codegen
    string_cache_shared
    strsim
    synom
    syntex_errors
    syslog
    take
    tempdir
    term
    term_size
    termcolor
    termion
    textwrap
    thread-id
    threadpool
    time
    tokio-core
    tokio-proto
    tokio-tls
    typeable
    unicode-bidi
    unicode-normalization
    unicode-segmentation
    unicode-width
    unicode-xid
    unreachable
    url
    utf-8
    utf8-ranges
    uuid
    vcpkg
    vec_map
    version_check
    void
    walkdir
    winapi
    winapi-build
    winapi-i686-pc-windows-gnu
    winapi-x86_64-pc-windows-gnu
    wincolor
    ws2_32-sys
    xattr
    ```

    </details>

* **Static trait object** —

    ```rust
    fn read_from<R: Read + ?Sized>(r: &mut R) -> Result<Self>;
    //              ^~~~              ^~~~~~
    ```

    A function takes an `&T` or `&mut T` reference, where the type `T` implements a trait. The
    `?Sized` bound allows the function to cover dynamic trait objects since `dyn Trait: Trait`. Its
    usage is typically limited to functions provided by the trait, and seldom needs to know the size
    or alignment.

    <details><summary>This pattern is used in 14 packages.</summary>

    ```
    aho-corasick
    ansi_term
    csv (via serde)
    mio
    nix
    phf_shared
    png
    rayon-core
    reqwest
    serde
    serde_json
    serde_urlencoded (via serde)
    syn
    toml (via serde)
    ```

    </details>

* **AsRef** —

    ```rust
    fn open_file<P: AsRef<Path> + ?Sized>(p: &P) -> Result<Self>;
    //              ^~~~~~~~~~~              ^~
    ```

    A function takes an `&T` reference, where `T` implements `AsRef<X>` meaning the `&T` can be
    converted to an `&X` without allocation. This is typically used to accept various kinds of
    strings which are unsized, thus the `?Sized` bound. The function usually immediately call
    `.as_ref()` to obtain the `&X`, and again seldom access the runtime size or alignment.

    <details><summary>This pattern is used in 10 packages.</summary>

    ```
    aho-corasick
    base64
    clap
    mio
    miow
    quote
    regex
    syntex_pos
    unicase
    xml-rs
    ```

    </details>

* **Delegation** —

    ```rust
    impl<'a, T: Read + ?Sized> Read for &'a mut T { ... }
    //          ^~~~           ^~~~     ^~~~~~~~~
    ```

    A trait is reimplemented for smart pointers implementing the trait. The implementation typically
    just dereference the pointer and forward the method. Thus, the allocation aspect of the smart
    pointers are not touched.

    Delegation targets are seen in various forms:

    * <details><summary><code>&T</code> and <code>&mut T</code>: 10 packages</summary>

        ```
        aho-corasick
        bytes
        futures
        quote
        rand
        rayon
        rustc-serialize
        serde
        tokio-io
        toml
        ```

        </details>
    * <details><summary><code>Box&lt;T&gt;</code>: 8 packages</summary>

        ```
        bytes
        futures
        quote
        rand
        rustc-serialize
        serde
        tokio-io
        tokio-service
        ```

        </details>
    * <details><summary><code>Cow&lt;T&gt;</code>: 4 packages</summary>

        ```
        quote
        rayon
        rustc-serialize
        serde
        ```

        </details>
    * <details><summary><code>Rc&lt;T&gt;</code> and <code>Arc&lt;T&gt;</code>: 2 packages</summary>

        ```
        serde
        tokio-service
        ```

        </details>

* **Extension trait** —

    ```rust
    impl<T: Read + ?Sized> ReadExt for T { ... }
    //      ^~~~           ^~~~~~~     ^
    ```

    A trait is blanket-implemented for an existing trait. The `?Sized` is for completeness, and
    otherwise usually implemented like a typical trait.

    <details><summary>This pattern is used in 5 packages.</summary>

    ```
    byteorder
    gif
    itertools
    petgraph
    png
    ```

    </details>

* **Using `size_of_val` like C’s `sizeof`** —

    ```rust
    let value: c_int = 1;
    setsockopt(
        sck,
        SOL_SOCKET,
        SO_REUSEPORT,
        &value as *const c_int as *const c_void,
        size_of_val(&value),
    //  ^~~~~~~~~~~~~~~~~~~
    );
    ```

    Most `size_of_val` calls are not used to obtain the runtime size of a DST, but to mimic C’s
    `sizeof` operator on a value, which are sized types. Thus it is also usually used in FFI
    scenario.

    <details><summary>This pattern is used in 10 packages.</summary>

    ```
    backtrace
    error-chain
    libc
    mio
    miow
    net2
    num_cpus
    schannel
    syntex_syntax
    unix_socket
    ```

    </details>

* **Comparison** —

    ```rust
    fn find_first<Q: PartialEq<K> + ?Sized>(&self, key: &Q) -> Option<&K> { ... }
    //               ^~~~~~~~~~~~                       ^~
    ```

    A function takes an `&T` reference which implements `PartialEq<X>`, `PartialOrd<X>`,
    `Borrow<X>`, `Hash` or some similar methods that allows comparing the `&T` with an `&X`. This is
    typically used in data-structure types.

    <details><summary>This pattern is used in 5 packages.</summary>

    ```
    bytes
    hyper
    ordermap
    phf
    serde_json
    ```

    </details>

* Miscellaneous usages for `?Sized` bounds such as,
    * just want to use a `&T` without caring what `T` is (`error-chain`, `serde_json`, `tendril`)
    * use it for `Cow<T>` (`ansi_term`)
    * use it in associated type `type T: ?Sized` in order to be generic in accepting a string or
        byte slice (`ansi_term`, `regex`, `tendril`)

Now some usages which will be negatively affected by custom DST.

* **Box** —

    ```rust
    struct P<T: ?Sized>(Box<T>);
    //                  ^~~~~~
    ```

    A type which contains a box of arbitrary unsized type. This is used in:

    * hyper (`PtrMapCell<V>`)
    * syntex_syntax (`P<T>`)
    * thread_local (`TableEntry<T>`)

* **Maybe-unsized struct** —

    ```rust
    struct Spawn<T: ?Sized> {
        id: usize,
        data: LocalMap,
        obj: T,
    //  ^~~~~~
    }
    ```

    This is used in:

    * futures (`Spawn<T>`)
    * tar (`Archive<R>`)

* **Unsafe memory copying** —

    ```rust
    let mut target = vec![0u8; size_of_val(&v)];
    //                         ^~~~~~~~~~~~~~~
    ```

    Using `size_of_val` on a maybe-unsized type to `memcpy` the content somewhere else. This is used
    in:

    * nix (`copy_bytes`)

* **Transmuting** —

    Just tries to inspect the DST detail by transmutation or other unsafe tricks. This is used in:

    * traitobject

<!-- spell-checker:enable -->

These are affected all because `size_of_val` or `align_of_val` of an `extern type` is invalid. Due
to Rust’s stability guarantee, using `Spawn<ExternType>` should continue to compile, even if it may
panic at runtime. The compiler can issue a lint at monomorphization time, if `size_of_val`,
`align_of_val` or an unsized struct is instantiated with an extern type (or `T: !DynSized` in
general), it should issue a forward-compatibility lint.

When `DynSized` trait was introduced in [RFC #1993], it was expected to be a “default bound” similar
to `Sized`, which needs to be explicitly opt-out via `?DynSized`. The `?Trait` feature was
considered confusing, and causing pressure and churn to package authors to generalization every
`?Sized` to `?DynSized` ([RFC issue #2255]), and thus the first implementation of `DynSized`
([PR #46108]) was eventually postponed.

This RFC introduces not just `DynSized`, but also `Aligned` and `RegularSized`, all of which
will be implied by the `Sized` bound. Should we make them default bounds as well? We suggest **no**,
where `?Sized` is repurposed to mean opt-out of *all* bounds.

As we can see from the above statistics, in the 49 packages using DST features, only 12 packages
really assume `DynSized`, and out of which, 5 packages uses `Box<T>`/`Rc<T>`/`Arc<T>` simply for
delegation. This means it is more popular for `?Sized` to just mean “nothing is assumed”.
Furthermore, `?Sized` already requires `?Aligned` due to trait objects, so it is not convincing to
say `DynSized` should be a default-bound because of `Sized: DynSized`.

Still, it makes sense to restrict `size_of_val`/`align_of_val`/`Box`/`Rc`/etc to
`T: DynSized + ?Sized` in the next epoch. This would mean the lint mentioned before is a
necessary requirement for this RFC.

[top 100 packages]: https://github.com/integer32llc/rust-playground/blob/c7e63b77f/compiler/base/crate-information.json

[RFC #401]: http://rust-lang.github.io/rfcs/0401-coercions.html
[RFC #809]: http://rust-lang.github.io/rfcs/0809-box-and-in-for-stdlib.html
[RFC #1309]: https://github.com/rust-lang/rfcs/pull/1309
[RFC #1358]: http://rust-lang.github.io/rfcs/1358-repr-align.html
[RFC #1524]: https://github.com/rust-lang/rfcs/pull/1524
[RFC #1598]: http://rust-lang.github.io/rfcs/1598-generic_associated_types.html
[RFC #1733]: http://rust-lang.github.io/rfcs/1733-trait-alias.html
[RFC #1860]: http://rust-lang.github.io/rfcs/1860-manually-drop.html
[RFC #1861]: http://rust-lang.github.io/rfcs/1861-extern-types.html
[RFC #1909]: https://github.com/rust-lang/rfcs/pull/1909
[RFC #1932]: https://github.com/rust-lang/rfcs/pull/1932
[RFC #1993]: https://github.com/rust-lang/rfcs/pull/1993
[RFC #2000]: http://rust-lang.github.io/rfcs/2000-const-generics.html
[RFC #2113]: http://rust-lang.github.io/rfcs/2113-dyn-trait-syntax.html
[RFC issue #997]: https://github.com/rust-lang/rfcs/issues/997
[RFC issue #1397]: https://github.com/rust-lang/rfcs/issues/1397
[RFC issue #2255]: https://github.com/rust-lang/rfcs/issues/2255
[@japaric’s draft]: https://github.com/japaric/rfcs/blob/unsized2/text/0000-unsized-types.md
[issue #47034]: https://github.com/rust-lang/rust/issues/47034
[PR #46108]: https://github.com/rust-lang/rust/pull/46108