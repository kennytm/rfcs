# Changes

This section provides instructions what needs to be added and changed in the standard library and
compiler to implement this RFC.

<!-- TOC depthFrom:2 -->

- [Core traits](#core-traits)
- [Core functions](#core-functions)
- [Size and alignment](#size-and-alignment)
- [Drop](#drop)
- [Unsize](#unsize)
- [Sized types](#sized-types)
- [Slices](#slices)
- [Trait objects](#trait-objects)
- [Tuples](#tuples)
- [Structs](#structs)
- [Foreign types](#foreign-types)
- [Custom DST](#custom-dst)
    - [Custom regular DST](#custom-regular-dst)
    - [Custom inline DST](#custom-inline-dst)
- [Placement protocol](#placement-protocol)
- [Lints](#lints)
    - [Milestone 0: Warning period](#milestone-0-warning-period)
    - [Milestone 1: Denial period](#milestone-1-denial-period)
    - [Milestone 2: A new epoch](#milestone-2-a-new-epoch)
    - [Milestone 3: Proper trait bounds](#milestone-3-proper-trait-bounds)

<!-- /TOC -->
<!-- spell-checker:ignore nonoverlapping -->

## Core traits

Introduce the `core::marker::Object` trait:

```rust ,ignore
#[unstable(feature = "dyn_type", issue = "999999")]
#[lang = "object"]
#[fundamental]
pub trait Object {
    type Meta: Sized + Copy + Send + Sync + Ord + Hash + 'static;
    fn size_of_val(val: *const Self) -> usize;
    fn align_of_meta(meta: Self::Meta) -> usize;
}
```

Introduce the `core::marker::DynSized` marker trait:

```rust ,ignore
#[unstable(feature = "dyn_type", issue = "999999")]
#[lang = "dyn_sized"]
#[rustc_on_unimplemented = "`{Self}` does not have a size known at run-time"]
#[fundamental]
pub trait DynSized: Object {}
```

Introduce the `core::marker::CustomDst` trait:

```rust ,ignore
#[unstable(feature = "dyn_type", issue = "999999")]
#[lang = "custom_dst"]
pub trait CustomDst: DynSized {
    type Reduced: DynSized + ?Sized;
    fn reduced_meta(val: *const Self) -> Self::Reduced::Meta;
}
```

Introduce the `core::marker::RegularDst` trait:

```rust ,ignore
#[unstable(feature = "dyn_type", issue = "999999")]
#[lang = "regular_dst"]
pub trait RegularDst: CustomDst {
    fn reduce_with_meta(meta: Self::Meta) -> Self::Reduced::Meta;
}
```

Introduce the `core::marker::InlineDst` trait:

```rust ,ignore
#[unstable(feature = "dyn_type", issue = "999999")]
#[lang = "inline_dst"]
pub unsafe trait InlineDst: DynSized<Meta = ()> + Aligned {
    fn reduce_with_ptr(ptr: *const u8) -> Self::Reduced::Meta;
}
```

The above traits should not appear inside `std::prelude::v1::*`.

Introduce the `core::marker::Aligned` marker trait:

```rust ,ignore
#[unstable(feature = "dyn_type", issue = "999999")]
#[lang = "aligned"]
#[rustc_on_unimplemented = "`{Self}` does not have a constant alignment known at compile-time"]
#[fundamental]
pub trait Aligned: DynSized {}
```

Modify the `core::marker::Sized` marker trait to:

```rust ,ignore
#[stable(feature = "rust1", since = "1.0.0")]
#[lang = "sized"]
#[rustc_on_unimplemented = "`{Self}` does not have a constant size known at compile-time"]
#[fundamental]
pub trait Sized: Aligned {}
//               ^~~~~~~ new
```

Trying to implement `Object`, `Aligned`, `DynSized`, `CustomDst`, or `Sized` should emit error
[E0322].

> The new trait hierarchy, visualized.
>
> ```
>               ┏━━━━━━━━━━┓
>               ┃  Object  ┃
>               ┗━━━━━┯━━━━┛
>               ┏━━━━━┷━━━━┓
>               ┃ DynSized ┃
>               ┗━━━━━┯━━━━┛
>             ╭───────┴────────╮
>        ┏━━━━┷━━━━┓     ┏━━━━━┷━━━━━┓
>        ┃ Aligned ┃     ┃ CustomDst ┃
>        ┗━━━━┯━━━━┛     ┗━━━━━┯━━━━━┛
>      ╭──────┴─────╮   ╭──────┴───────╮
> ┏━━━━┷━━━━┓   ┏━━━┷━━━┷━━━┓   ┏━━━━━━┷━━━━━┓
> ┃  Sized  ┃   ┃ InlineDst ┃   ┃ RegularDst ┃
> ┗━━━━━━━━━┛   ┗━━━━━━━━━━━┛   ┗━━━━━━━━━━━━┛
> ```

Pointers and references `&T` will be represented as `(&(), T::Meta)` in memory.

`Object` is a default bound which *cannot be opt-out* (similar to `std::any::Any`). Writing
`<T: ?Sized>` would still result in `T: Object`, except that the members of the traits are not
visible. As an example, the following should type-check:

```rust ,ignore
fn g<T: Object + ?Sized>();
fn f<T: ?Sized>() { g::<T>() }
```

## Core functions

Implement `core::mem::meta` function as

```rust ,ignore
pub fn meta<T: ?Sized>(val: *const T) -> T::Meta {
    unsafe {
        let res: (*const u8, T::Meta) = transmute(val);
        res.1
    }
}
```

Implement `core::mem::reduce_raw` function as

```rust ,ignore
pub fn reduce_raw<T: CustomDst + ?Sized>(val: *const T) -> *const T::Reduced {
    let ptr = val as *const u8;
    let meta = T::reduced_meta(val);
    unsafe { from_dst_raw_parts(ptr, meta) }
}
```

Similarly, provide the following functions:

```rust ,ignore
pub fn reduce<T: CustomDst + ?Sized>(val: &T) -> &T::Reduced;
pub fn reduce_mut<T: CustomDst + ?Sized>(val: &mut T) -> &mut T::Reduced;
pub fn reduce_raw_mut<T: CustomDst + ?Sized>(val: *mut T) -> *mut T::Reduced;
```

Implement `core::mem::from_dst_raw_parts` function as

```rust ,ignore
pub unsafe fn from_dst_raw_parts<T: ?Sized>(ptr: *const u8, meta: T::Meta) -> *const T {
    transmute((ptr, meta));
}
```

## Size and alignment

The bounds of the `align_of` intrinsic is relaxed to

```rust ,ignore
pub fn align_of<T: Aligned + ?Sized>() -> usize;
//                 ^~~~~~~~~~~~~~~~ relaxed
```

| Type | Align |
|------|-------|
| `#[repr(align(n))]` | `n` |
| `#[repr(packed)]` | 1 |
| Sized type | (same as before) |
| Slices `[T]` | `align_of::<T>()` |
| `str` | 1 |
| Trait object `dyn Trait` | *not implemented* |
| `extern type` | *not implemented* |
| Custom DST `dyn type` | *see below* |

Also ensure `size_of::<&T>()` returns the size of the tuple `(usize, T::Meta)`.

Modify the `align_of_val` and `size_of_val` functions to simply forward to the `Object` methods (or
the other way round, whichever is easier to implement).

```rust ,ignore
pub fn align_of_val<#[rustc_assume_dyn_sized] T: ?Sized>(val: &T) -> usize {
    <T as Object>::align_of_meta(meta(val))
}
pub fn size_of_val<#[rustc_assume_dyn_sized] T: ?Sized>(val: &T) -> usize {
    <T as Object>::size_of_val(val)
}
```

## Drop

Allow implementing `Drop` for DSTs. Relax bounds for the `needs_drop` intrinsic to check DSTs.

```rust
fn needs_drop<T: ?Sized>() -> bool;
//               ^~~~~~ relaxed
```

If `T` does not implement `Drop`, depending on the DST family, this function’s return value is:

| Family         | Result                      |
|----------------|-----------------------------|
| Slices (`[T]`) | Same as `needs_drop::<T>()` |
| `str`          | false                       |
| Trait object   | true                        |
| Extern type    | false                       |
| Custom DST     | Same as `needs_drop::<T::Reduced>` |

The `drop_in_place` for custom DST will work by dropping its reduction in place.

## Unsize

Modify `core::marker::Unsize` trait to:

```rust ,ignore
#[unstable(feature = "unsize", issue = "27732")]
#[lang = "unsize"]
pub unsafe trait Unsize<T: Object + ?Sized>: Object {
    fn unsize(meta: Self::Meta) -> T::Meta; // <-- new
}
```

Error [E0328] should be removed. Implementing `Unsize` is now allowed.

Unsize-coercion from `*Src` to `*Dest` would perform the following:

```rust ,ignore
let src_meta = mem::meta(src);
let dest_meta = <Src as Unsize<Dest>>::unsize(src_meta);
unsafe { from_dst_raw_parts(src as *const u8, dest_meta) }
```

Ensure the compiler can handle unsize-coercion between two DSTs, not just from sized to unsized.

To avoid infinite reduction, unsize-coercion should never be applied more than once in the whole
coercion chain.

## Sized types

If a built-in type `X` is sized, the `Sized` trait and its super-traits will be automatically
implemented for that type.

```rust ,ignore
impl Object for X {
    type Meta = ();
    fn size_of_val(_: *const Self) -> usize { size_of::<Self>() }
    fn align_of_meta(_: Self::Meta) -> usize { align_of::<Self>() }
}
impl DynSized for X {}
impl Aligned for X {}
impl Sized for X {}
```

This section applies to the following types:

* Primitives `iN`, `uN`, `fN`, `bool`, `char`
* Pointers `*const T`, `*mut T`
* References `&'a T`, `&'a mut T`
* Function pointers `fn(T, U) -> V`
* Arrays `[T; n]`
* Never type `!`
* Unit tuple `()`
* Closures and generators
* Definitely-sized structs, enums and unions

## Slices

Implement `Object`, `DynSized`, `Aligned`, and `Unsize` for slices as shown below.

```rust ,ignore
impl<T> Object for [T] {
    type Meta = usize;
    fn size_of_val(val: *const Self) -> usize { meta(val) * size_of::<Self>() }
    fn align_of_meta(_: Self::Meta) -> usize { align_of::<Self>() }
}
impl<T> DynSized for [T] {}
impl<T> Aligned for [T] {}

unsafe impl<T, const n: usize> Unsize<[T]> for [T; n] {
    fn unsize(_: ()) -> usize { n }
}
```

The same as implemented for `str` as if it is a `[u8]`.

## Trait objects

Introduce a structure to represent the indirect metadata for every trait object.

```rust ,ignore
#[repr(C)]
pub struct TraitMeta<V> {
    destructor: fn(*mut ()),
    size: usize,
    align: usize,
    vtable: V,
}
```

Implement `PartialEq`, `Eq`, `PartialOrd`, `Ord`, and `Hash` on it using the *pointer value*.

```rust ,ignore
impl<V> PartialEq for TraitMeta<V> {
    fn eq(&self, other: &Self) -> bool {
        self as *const Self == other as *const Self
    }
}
// etc.
```

Whenever a `trait Trait` item is spotted, generate the corresponding vtable structure.

```rust ,ignore
#[compiler_generated]
#[repr(C)]
struct Trait_Vtable {
    read: fn(*mut (), &mut [u8]) -> Result<usize>,
    initializer: fn(*const ()) -> Initializer,
    // etc.
}
```

and then automatically implement `Object` and `DynSized` for trait objects as shown below.

```rust ,ignore
impl Object for dyn Trait {
    type Meta = &'static dst::TraitMeta<Trait_Vtable>;
    fn size_of_val(val: *const Self) -> usize { meta(val).size }
    fn align_of_meta(meta: Self::Meta) -> usize { meta.align }
}
impl DynSized for dyn Trait {}
```

Whenever an `impl Trait for Type<…>` is spotted (provided `Type<…>` is sized), automatically
implement `Unsize` as shown below.

```rust ,ignore
unsafe impl<…> Unsize<dyn Trait> for Type<…> {
    fn unsize(_: ()) -> &'static dst::TraitMeta<Trait_Vtable> {
        &dst::TraitMeta {
            destructor: drop_in_place::<Self> as _,
            size: size_of::<Self>(),
            align: align_of::<Self>(),
            vtable: Trait_Vtable {
                read: <Self as Trait>::read as _,
                initializer: <Self as Trait>::initializer as _,
                // etc.
            },
        }
    }
}
```

## Tuples

Forward implementation of `Object`, `DynSized`, `Aligned`, and `Unsize` for tuples as shown below.

```rust ,ignore
impl<T, U, V, W: ?Sized> Object for (T, U, V, W) {
    type Meta = W::Meta;

    fn align_of_meta(meta: Self::Meta) -> usize {
        max(align_of::<(T, U, V)>(), W::align_of_meta(meta))
    }
    fn size_of_val(val: *const Self) -> usize {
        let m = meta(val);

        let offset = size_of::<T>() + size_of::<U>() + size_of::<V>();
        let dst_align_1 = W::align_of_meta(m) - 1;
        let offset = (offset + dst_align_1) & !dst_align_1;
        //^ `(x + y) & !y` rounds `x` up to the next multiple of `y + 1`.

        let dst: *const W = unsafe {
            let ptr = (val as *const u8).add(offset);
            from_dst_raw_parts(ptr, m)
        };
        //^ this is equivalent to `let dst = &val.3`.
        let dst_size = W::size_of_val(dst);

        let align_1 = align_of::<(T, U, V)>() - 1;
        (offset + dst_size + align_1) & !align_1
    }
}
impl<T, U, V, W: ?Sized + DynSized> DynSized for (T, U, V, W) {}
impl<T, U, V, W: ?Sized + Aligned> Aligned for (T, U, V, W) {}
impl<T, U, V, W> Sized for (T, U, V, W) {}

#[unstable(feature = "unsized_tuple_coercion", issue = "42877")]
unsafe impl<T, U, V, WT: ?Sized, WF: Unsize<WT>> Unsize<(T, U, V, WT)> for (T, U, V, WF) {
    fn unsize(meta: Self::Meta) -> WT::Meta {
        WF::unsize(meta)
    }
}
```

Note that due to [issue #42877], the last element of a tuple is always considered potentially
unsized and thus will not be rearranged to the middle of its memory layout. Thus, the above
implementation of `size_of_val` is correct even when `W` is `Sized`.

## Structs

Structs are similar to tuples in general, but with minor tweaks that ensure the outcome is
consistent.

If the struct is definitely sized, implement the traits as specified in the
[Sized types](#sized-types) section. Otherwise, implement the traits similar to the tuple as
specified above.

Forwarding `Unsize` has the same condition as currently, i.e. `Foo<…, T, …>: Unsize<Foo<…, U, …>>`
if

* The last field has type `X::Bar<T>` (the `T` can only appear attached to the last path component,
    e.g. `Bar<T>::X` will cause `Foo` not `Unsize`).
* `T: Unsize<U>`
* `Bar<T>: Unsize<Bar<U>>`
* `T` does not appear in any other fields (not even as `PhantomData<T>`)

We need to consider the effect of `#[repr]` attributes.

* With `#[repr(packed)]`, the alignment is always 1. The `Aligned` trait will be always implemented.

    <details><summary>The <code>Object</code> implementation is changed.</summary>

    ```rust ,ignore
    #[repr(packed)]
    struct DstStruct {
        t: T,
        u: U,
        v: V,
        w: W,
    }

    impl Object for DstStruct {
        type Meta = W::Meta;
        fn align_of_meta(_: Self::Meta) -> usize {
            1   // <-- changed
        }
        fn size_of_val(val: &Self) -> usize {
            let m = meta(val);

            let offset = size_of::<T>() + size_of::<U>() + size_of::<V>();
            // no need to align the offset.

            let dst: *const W = unsafe {
                let ptr = (val as *const u8).add(offset);
                from_dst_raw_parts(ptr, m)
            };
            let dst_size = W::size_of_val(dst);

            offset + dst_size
            // no need to align the size.
        }
    }
    ```

    </details>


* With `#[repr(align(n))]`, the alignment is always `n`. The `Aligned` trait will be always
    implemented.

    <details><summary>The <code>Object</code> implementation is changed.</summary>

    ```rust ,ignore
    #[repr(align(n))]
    struct DstStruct {
        t: T,
        u: U,
        v: V,
        w: W,
    }

    impl Object for DstStruct {
        type Meta = W::Meta;
        fn align_of_meta(_: Self::Meta) -> usize {
            n   // <-- changed
        }
        fn size_of_val(val: &Self) -> usize {
            let m = meta(val);

            let offset = size_of::<T>() + size_of::<U>() + size_of::<V>();
            let dst_align_1 = W::align_of_meta(m) - 1;
            let offset = (offset + dst_align_1) & !dst_align_1;
            //^ offset alignment is still needed

            let dst: *const W = unsafe {
                let ptr = (val as *const u8).add(offset);
                from_dst_raw_parts(ptr, m)
            };
            let dst_size = W::size_of_val(dst);

            let align_1 = n - 1;    // <-- total alignment is set to `n`.
            (offset + dst_size + align_1) & !align_1
        }
    }
    ```

    </details>

* With `#[repr(C)]`, the `offset` in `size_of_val()` calculation will use the FFI offset, but is
    otherwise unchanged.

* `#[repr(transparent)]` has no effect on size calculation.
* `#[repr(simd)]` is prohibited on unsized structs.

## Foreign types

Whenever an `extern { type Opaque; }` item is spotted, automatically implement `Object` as shown
below.

```rust ,ignore
impl Object for Opaque {
    type Meta = ();
    fn align_of_meta(_: ()) -> usize {
        // Exact message is unspecified.
        panic!("Alignment of {} is unknown", intrinsics::type_name::<Self>())
    }
    fn size_of_val(_: *const Self) -> usize {
        // Exact message is unspecified.
        panic!("Size of {} is unknown", intrinsics::type_name::<Self>())
    }
}
```

## Custom DST

Introduce a new syntax to declare a custom DST.

```rust ,ignore
dyn type RDst<T>(M) where T: Bounds = C;     // regular DST
dyn type IDst<T>(..) where T: Bounds = C;    // inline DST
```

The type `C` must implement `DynSized` and should not be `Sized`.

The variance of `T` will be the same as the tuple `(C, *mut M)`.

If `C` implements an auto-trait, `RDst`/`IDst` will also implement it (`M` is not considered).

The `#[repr]` attributes can be applied on custom DSTs.

* With `#[repr(align(n))]`, the `align_of_meta` method will always return `n`, and `Aligned` is
    always implemented regardless of `C`.
* With `#[repr(C)]` on an inline DST, the type is FFI-safe. `#[repr(C)]` on regular DST will cause
    [E0517] error.
* Everything else (packed, simd, transparent) causes [E0517] error.

### Custom regular DST

When a regular `dyn type` item is spotted, automatically implement `Object`, `DynSized`, `Aligned`
and `CustomDst` as shown below.

```rust ,ignore
impl<T> Object for RDst<T> where T: Bounds {
    type Meta = M;
    fn align_of_meta(meta: Self::Meta) -> usize {
        let meta = <Self as RegularDst>::reduce_with_meta(meta);
        <Self as CustomDst>::Reduced::align_of_meta(meta)
    }
    fn size_of_val(val: *const Self) -> usize {
        <Self as CustomDst>::Reduced::size_of_val(reduce_raw(val))
    }
}
impl<T> CustomDst for RDst<T> where T: Bounds {
    type Reduced = C;
    fn reduced_meta(val: *const Self) -> Self::Reduced::Meta {
        <Self as RegularDst>::reduce_with_meta(meta(val))
    }
}
impl<T> DynSized for RDst<T> where T: Bounds {}
impl<T> Aligned for RDst<T> where T: Bounds, C: Aligned {}
```

The user is required to implement `RegularDst` for `RDst<T>` themselves.

### Custom inline DST

When an inline `dyn type` item is spotted, automatically implement `Object`, `DynSized`, `Aligned`
and `CustomDst` as shown below.

```rust ,ignore
impl<T> Object for IDst<T> where T: Bounds {
    type Meta = ();
    fn align_of_meta(_: Self::Meta) -> usize {
        align_of::<C>()
    }
    fn size_of_val(val: *const Self) -> usize {
        <Self as CustomDst>::Reduced::size_of_val(reduce_raw(val))
    }
}
impl<T> CustomDst for RDst<T> where T: Bounds {
    type Reduced = C;
    fn reduced_meta(val: *const Self) -> Self::Reduced::Meta {
        <Self as InlineDst>::reduce_with_ptr(val as *const u8)
    }
}
impl<T> DynSized for IDst<T> where T: Bounds {}
impl<T> Aligned for IDst<T> where T: Bounds {}
```

The user is required to implement `InlineDst` for `IDst<T>` themselves.

## Placement protocol

Modify all 5 traits involved in the placement protocol:

Modify `core::ops::Placer` to

```rust ,ignore
pub unsafe trait Place {
//                    ^ type erased
    fn pointer(&mut self) -> *mut u8;
//                                ^~ type erased
}

pub trait InPlace<Data: ?Sized>: Place {
    type Owner;
    unsafe fn finalize(self, meta: Data::Meta) -> Self::Owner;
//                           ^~~~~~~~~~~~~~~~ added
}

pub trait Placer<Data: ?Sized>: Sized {
    type Place: InPlace<Data>;
    fn make_place(self, size: usize, align: usize) -> Self::Place;
//                      ^~~~~~~~~~~~~~~~~~~~~~~~~ added

    #[deprecated]   // <-- function retained to compensate for lack of `typeof`
    fn make_sized_place(self) -> Self::Place where Data: Sized {
        self.make_place(mem::size_of::<Data>(), mem::align_of::<Data>())
    }
}

pub trait BoxPlace<Data: ?Sized>: Place + Sized {
    fn make_place(size: usize, align: usize) -> Self;
//                ^~~~~~~~~~~~~~~~~~~~~~~~~ added

    #[deprecated]   // <-- function added to compensate for lack of `typeof`
    fn make_sized_place(meta: Data::Meta) -> Self where Data: Sized {
        Self::make_place(mem::size_of::<Data>(), mem::align_of::<Data>())
    }
}

pub trait Boxed {
    type Data: ?Sized;
//             ^~~~~~ relaxed
    type Place: BoxPlace<Self::Data>;
    unsafe fn finalize(filled: Self::Place, meta: Self::Data::Meta) -> Self;
//                                          ^~~~~~~~~~~~~~~~~~~~~~ added
}
```

(The `make_sized_place` methods are added to compensate for the lack of `typeof` operator.)

The lowering of `$placer <- $expr` will be changed to:

```rust ,ignore
let placer = $placer;
let mut place = placer.make_sized_place();
let ptr = place.pointer();
unsafe {
    intrinsics::move_val_init(ptr as *mut _, #[safe] { $expr });
    place.finalize(())
}
```

and the lowering of `box $expr` (if implemented) will be changed to:

```rust ,ignore
let mut place = BoxPlace::make_sized_place();
let ptr = place.pointer();
unsafe {
    intrinsics::move_val_init(ptr as *mut _, #[safe] { $expr });
    Boxed::finalize(place, ())
}
```

Supporting general unsized expression is out-of-scope for this RFC (but see
[Extensions](0000-dyn-type/52-Extensions.md#unsized-expressions)).

As a demonstration of future compatibility, the implementation of the `std::boxed::IntermediateBox`
type will be updated.

<details>

```rust
pub struct IntermediateBox<T: ?Sized> {
    ptr: *mut u8,
    layout: Layout,
    marker: PhantomData<*mut T>,
}
impl<T: ?Sized> Place for IntermediateBox<T> {
//      ^~~~~~
    fn pointer(&mut self) -> *mut u8 {
        self.ptr
    }
}
unsafe fn finalize<T: ?Sized>(b: IntermediateBox<T>, meta: T::Meta) -> Box<T> {
//                    ^~~~~~
    let p = mem::from_dst_raw_parts(b.ptr, meta);
    mem::forget(b);
    mem::transmute(p)
}
fn make_place<T: ?Sized>(size: usize, align: usize) -> IntermediateBox<T> {
//               ^~~~~~  ^~~~~~~~~~~~~~~~~~~~~~~~~
    let layout = Layout::from_size_align(size, align).expect("Invalid size/align");
    let ptr = if size == 0 {
        align as *mut u8
    } else {
        unsafe { Heap.alloc(layout.clone()).unwrap_or_else(|e| Heap.oom(e)) }
    };
    IntermediateBox {
        ptr,
        layout,
        marker: PhantomData,
    }
}
// the rest are trivial.
```

</details>

## Lints

It is an error to use to non-`DynSized` types as a struct field or in `size_of_val`/`align_of_val`.
To avoid introducing breaking changes, we are going to close this gap across 3 milestones (one
milestone is one epoch or smaller time units).

### Milestone 0: Warning period

* Move into this milestone after `DynSized` is implemented (but is unstable). Do not stabilize
    `extern type` before this milestone is complete.

If a type cannot prove that it implements `DynSized`, but is used in places where `size_of_val`
etc are needed, a lint (`size_of_unaligned_type`, warn-by-default) will be issued. The places which
triggers the lint check are:

1. Use in a struct/tuple field, `x: T`, except the following conditions:

    * The field is the first and only field in the struct, or
    * The struct is `#[repr(packed)]`

2. A type `T` substituted into a generic parameter which is annotated `#[rustc_assume_dyn_sized]`.

The type `T` passes the check when:

1. It can be proved to implement `DynSized`, or
2. It originates from a generic parameter annotated `#[rustc_assume_dyn_sized]`.

Roughly speaking, `#[rustc_assume_dyn_sized]` can be consider the same as `DynSized` bound, except
violating it causes a type-check lint instead of hard error.

This lint should *never* be emitted in stable/beta channels in this milestone.

<details><summary>Examples</summary>

Check 1:

```rust
struct Foo<T: ?Sized> {
    a: u8,
    b: T,
}
```

```
warning: type `T` is not guaranteed to have a known alignment, and may cause panic at runtime
 --> src/foo.rs:3:7
  |
1 | struct Foo<T: ?Sized> {
  |               ------ hint: change to `DynSized + ?Sized`
2 |     a: u8,
3 |     b: T,
  |        ^ alignment maybe undefined
  |
  = note: #[warn(size_of_unaligned_type)] on by default
  = note: this was previously accepted by the compiler but is being phased out; it will become a hard error in a future release!
```

Check 2:

```rust
struct Bar<#[rustc_assume_dyn_sized] T: ?Sized> {
    a: Foo<T>, // no lint here!
}
extern { type Opaque; }
let _: Bar<Opaque>;
```

```
warning: type `Opaque` has no known alignment, and will cause panic at runtime
 --> src/bar.rs:5:11
  |
5 | let _: Bar<Opaque>
  |            ^^^^^^ alignment is undefined
  |
  = note: #[warn(size_of_unaligned_type)] on by default
  = note: this was previously accepted by the compiler but is being phased out; it will become a hard error in a future release!
```

</details>

The `#[rustc_assume_dyn_sized]` attribute should be applied on the following standard types and
functions:

* `align_of_val`, `size_of_val`
* `RefCell`
* `Rc`, `Weak`
* `Arc`, `Weak`
* `Box`
* `Mutex`
* `RwLock`

The `#[rustc_assume_dyn_sized]` attribute is considered an implementation detail and should not be
stabilized.

In rustdoc, render this attribute `#[rustc_assume_dyn_sized] T: X` as `T: DynSized + X`.

### Milestone 1: Denial period

* Move into this milestone after the `DynSized` trait is stabilized.

Make `size_of_unaligned_type` deny-by-default, and enable the lint on stable/beta channel.

### Milestone 2: A new epoch

* Move into this milestone after a new epoch.

Turn the `size_of_unaligned_type` lint to a hard-error when the new epoch is selected.

### Milestone 3: Proper trait bounds

Replace all `#[rustc_assume_dyn_sized]` by proper `T: DynSized` bounds.

Since “breaking changes to the standard library are not possible” using epochs ([RFC #2052]), it may
be impossible to reach this milestone.

[E0322]: https://doc.rust-lang.org/error-index.html#E0322
[E0328]: https://doc.rust-lang.org/error-index.html#E0328
[E0517]: https://doc.rust-lang.org/error-index.html#E0517
[RFC #1909]: https://github.com/rust-lang/rfcs/pull/1909
[RFC #2000]: http://rust-lang.github.io/rfcs/2000-const-generics.html
[RFC #2052]: http://rust-lang.github.io/rfcs/2052-epochs.html
[PR #46156]: https://github.com/rust-lang/rust/pull/46156