# Norminative changes

This section provides instructions what needs to be added and changed in the standard library and
compiler to implement this RFC.

<!-- TOC depthFrom:2 -->

- [Core traits](#core-traits)
- [Core methods](#core-methods)
- [Drop](#drop)
- [Unsize](#unsize)
- [Sized types](#sized-types)
- [Slices](#slices)
- [Trait objects](#trait-objects)
- [Tuples and structs](#tuples-and-structs)
- [Foreign types](#foreign-types)
- [Custom DST](#custom-dst)
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
pub trait Object {
    type Meta: Sized + Copy + Send + Sync + Ord + Hash + 'static;

    fn align_of_meta(meta: Self::Meta) -> usize;
    fn size_of_val(&self) -> usize;
    fn compact_size_of_val(&self) -> usize;
}
```

Introduce the `core::marker::DynSized` marker trait:

```rust ,ignore
#[unstable(feature = "dyn_type", issue = "999999")]
#[lang = "dyn_sized"]
#[rustc_on_unimplemented = "`{Self}` does not have a size known at run-time"]
pub trait DynSized: Object {
    // Empty.
}
```

Introduce the `core::marker::RegularSized` trait:

```rust ,ignore
#[unstable(feature = "dyn_type", issue = "999999")]
#[lang = "regular_sized"]
pub trait RegularSized: DynSized {
    fn size_of_meta(meta: Self::Meta) -> usize;
    fn compact_size_of_meta(meta: Self::Meta) -> usize {
        Self::size_of_meta(meta)
    }
}
```

Introduce the `core::marker::InlineSized` trait:

```rust ,ignore
#[unstable(feature = "dyn_type", issue = "999999")]
#[lang = "inline_sized"]
pub unsafe trait InlineSized: DynSized<Meta = ()> + Aligned {
    fn size_of_ptr(ptr: *const u8) -> usize;
    fn compact_size_of_ptr(ptr: *const u8) -> usize {
        Self::size_of_ptr(ptr)
    }
}
```

The above traits should not appear inside `std::prelude::v1::*`.

Introduce the `core::marker::Aligned` marker trait:

```rust ,ignore
#[unstable(feature = "dyn_type", issue = "999999")]
#[lang = "aligned"]
#[rustc_on_unimplemented = "`{Self}` does not have a constant alignment known at compile-time"]
pub trait Aligned: DynSized {
    // Empty.
}
```

Modify the `core::marker::Sized` marker trait to:

```rust ,ignore
#[stable(feature = "rust1", since = "1.0.0")]
#[lang = "sized"]
#[rustc_on_unimplemented = "`{Self}` does not have a constant size known at compile-time"]
#[fundamental]
pub trait Sized: RegularSized + InlineSized {
    //           ^~~~~~~~~~~~~~~~~~~~~~~~~~ new
}
```

Trying to implement `Object`, `Aligned`, `DynSized` or `Sized` should emit error [E0322].

> The new trait hierarchy, visualized.
>
> ```
>              ┏━━━━━━━━━━┓
>              ┃  Object  ┃
>              ┗━━━━┯━━━━━┛
>            ┏━━━━━━┷━━━━━━━┓
>            ┃ DynamicSized ┃
>            ┗━━━━━━┯━━━━━━━┛
>         ╭─────────┴─────────╮
>         │              ┏━━━━┷━━━━┓
>         │              ┃ Aligned ┃
>         │              ┗━━━━┯━━━━┛
> ┏━━━━━━━┷━━━━━━┓     ┏━━━━━━┷━━━━━━┓
> ┃ RegularSized ┃     ┃ InlineSized ┃
> ┗━━━━━━━┯━━━━━━┛     ┗━━━━━━┯━━━━━━┛
>         ╰─────────┬─────────╯
>              ┏━━━━┷━━━━┓
>              ┃  Sized  ┃
>              ┗━━━━━━━━━┛
> ```

Pointers and references `&T` will be represented as `(&(), T::Meta)` in memory.

`Object` is a default bound which *cannot be opt-out* (similar to `std::any::Any`). Writing
`<T: ?Sized>` would still result in `T: Object`, except that the members of the traits are not
visible. As an example, the following should type-check:

```rust ,ignore
fn g<T: Object + ?Sized>();
fn f<T: ?Sized>() { g::<T>() }
```

## Core methods

Introduce the following convenient methods in `core::mem::*` to convert between a combined fat
pointer and decomposed thin pointer + metadata parts.

```rust ,ignore
pub fn meta<T: Object + ?Sized>(dst: *const T) -> T::Meta;
pub unsafe fn from_raw_parts<T: Object + ?Sized>(ptr: *const u8, meta: T::Meta) -> *const T;
pub unsafe fn from_raw_parts_mut<T: Object + ?Sized>(ptr: *mut u8, meta: T::Meta) -> *mut T;

#[inline]
pub fn into_raw_parts<T: Object + ?Sized>(fat: *const T) -> (*const u8, T::Meta) {
    (fat as *const u8, meta(fat))
}
#[inline]
pub fn into_raw_parts_mut<T: Object + ?Sized>(fat: *mut T) -> (*mut u8, T::Meta) {
    (fat as *mut u8, meta(fat))
}
```

The bounds of the `align_of` intrinsic is relaxed to

```rust ,ignore
pub fn align_of<T: Aligned + ?Sized>() -> usize;
//                 ^~~~~~~~~~~~~~~~ relaxed
```

Remove the intrinsics `size_of_val` and `align_of_val`. The corresponding stable methods in
`core::mem::*` are replaced as:

```rust ,ignore
pub fn align_of_val<#[rustc_assume_dyn_sized] T: ?Sized>(val: &T) -> usize {
    <T as Object>::align_of_meta(meta(val))
}
pub fn size_of_val<#[rustc_assume_dyn_sized] T: ?Sized>(val: &T) -> usize {
    <T as Object>::size_of_val(val)
}
pub fn compact_size_of_val<#[rustc_assume_dyn_sized] T: ?Sized>(val: &T) -> usize {
    <T as Object>::compact_size_of_val(val)
}
```

Introduce a new intrinsic, `compact_size_of`:

```rust ,ignore
pub fn compact_size_of<T>() -> usize;
```

<table>
<thead>
<tr><th>Type</th><th>Align</th><th>Size</th><th>Compact size</th></tr>
</thead>
<tbody>
<tr><td>i8, u8</td><td>1</td><td>1</td><td>1</td></tr>
<tr><td>i16, u16</td><td>≤2</td><td>2</td><td>2</td></tr>
<tr><td>i32, u32</td><td>≤4</td><td>4</td><td>4</td></tr>
<tr><td>i64, u64</td><td>≤8</td><td>8</td><td>8</td></tr>
<tr><td>i128, u128</td><td>≤16</td><td>16</td><td>16</td></tr>
<tr><td>isize, usize</td><td colspan="3">depends on pointer size</td></tr>
<tr><td>bool</td><td>≥1</td><td>≥1</td><td>1</td></tr>
<tr><td>char</td><td>≤4</td><td>4</td><td>4</td></tr>
<tr><td>*const T, *mut T, &T, &mut T</td><td colspan="3">same as the tuple <code>(usize, T::Meta)</code></td></tr>
<tr><td>fn(X) -> Y</td><td colspan="3">same as <code>usize</code></td></tr>
<tr><td>!</td><td>1</td><td>0</td><td>0</td></tr>
<tr><td>[T; n]</td>
    <td><code>align_of(T)</code></td>
    <td><code>size_of(T)×n</code></td>
    <td><code>size_of(T)×(n-1) + compact_size_of(T)</code></td></tr>
<tr><td>enum, union</td><td colspan="3">maximum of all members for all three sizes</td></tr>
</tbody>
</table>

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
| Custom DST     | false                       |

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
let (ptr, src_meta) = mem::into_raw_parts(src);
let dest_meta = <Src as Unsize<Dest>>::unsize(src_meta);
mem::from_raw_parts(ptr, dest_meta)
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
    fn align_of_meta(_: Self::Meta) -> usize { mem::align_of::<Self>() }
    delegate_object_impl_to_regular_sized!();
}
impl DynSized for X {}
impl RegularSized for X {
    fn size_of_meta(_: ()) -> usize { mem::size_of::<Self>() }
    fn compact_size_of_meta(_: ()) -> usize { mem::compact_size_of::<Self>() }
}
unsafe impl InlineSized for X {
    fn size_of_ptr(_: *const u8) -> usize { mem::size_of::<Self>() }
    fn compact_size_of_ptr(_: *const u8) -> usize { mem::compact_size_of::<Self>() }
}
impl Aligned for X {}
impl Sized for X {}
unsafe impl Unsize<X> for X {
    fn unsize(_: ()) {}
}
```

This section applies to the following types:

* Primitives `iN`, `uN`, `fN`, `bool`, `char`
* Pointers `*const T`, `*mut T`
* References `&'a T`, `&'a mut T`
* Function pointers `fn(T, U) -> V`
* Arrays `[T; n]`
* Never type `!`
* Unit tuple `()`
* Closures and generators.
* Enums
* Unions

## Slices

Implement `Object`, `DynSized`, `RegularSized`, `Aligned` and `Unsize` for slices as shown
below.

```rust ,ignore
impl<T> Object for [T] {
    type Meta = usize;
    fn align_of_meta(_: Self::Meta) -> usize { mem::align_of::<T>() }
    delegate_object_impl_to_regular_sized!();
}
impl<T> DynSized for [T] {}
unsafe impl<T> RegularSized for [T] {
    fn size_of_meta(len: usize) -> usize {
        mem::size_of::<T>() * len
    }
    fn compact_size_of_meta(len: usize) -> usize {
        if len == 0 {
            0
        } else {
            mem::size_of::<T>() * (len - 1) + mem::compact_size_of::<T>()
        }
    }
}
impl<T> Aligned for [T] {}

unsafe impl<T, const n: usize> Unsize<[T]> for [T; n] {
    fn unsize(_: ()) -> usize { n }
}
```

The same as implemented for `str` as if it is a `[u8]`.

## Trait objects

Introduce a structure to represent the indirect metadata for every trait object.

```rust ,ignore
#[doc(hidden)]
#[repr(C)]
pub struct TraitMeta<V> {
    destructor: fn(*mut ()),
    size: usize,
    align: usize,
    compact_size: usize,    // <-- new
    vtable: V,
}
```

Implement `PartialEq`, `Eq`, `PartialOrd`, `Ord` and `Hash` on it using the *pointer value*.

```rust
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

and then automatically implement `Object`, `DynSized` and `RegularSized` for trait objects as
shown below.

```rust ,ignore
impl Object for dyn Trait {
    type Meta = &'static dst::TraitMeta<Trait_Vtable>;
    fn align_of_meta(meta: Self::Meta) -> usize { meta.align }
    delegate_object_impl_to_regular_sized!();
}
impl DynSized for dyn Trait {}
impl RegularSized for dyn Trait {
    fn size_of_meta(meta: Self::Meta) -> usize { meta.size }
    fn compact_size_of_meta(meta: Self::Meta) -> usize { meta.compact_size }
}
```

Whenever an `impl Trait for Type` is spotted (provided `Type` is sized), automatically implement
`Unsize` as shown below.

```rust ,ignore
unsafe impl Unsize<dyn Trait> for Type {
    fn unsize(_: ()) -> &'static dst::TraitMeta<Trait_Vtable> {
        &dst::TraitMeta {
            destructor: drop_in_place::<Self> as _,
            size: size_of::<Self>(),
            align: align_of::<Self>(),
            compact_size: compact_size_of::<Self>(),
            vtable: Trait_Vtable {
                read: <Self as Trait>::read as _,
                initializer: <Self as Trait>::initializer as _,
                // etc.
            },
        }
    }
}
```

## Tuples and structs

Implement `Object` for tuples with ≥2 elements as shown below.

```rust ,ignore
#[doc(hidden)]
fn size_of_struct<P, W: ?Sized>(
    ptr: *const u8,
    meta: W::Meta,
    dst_align: usize,
    total_align: usize,
) -> usize {
    let header_size = mem::compact_size_of::<P>();
    let dst_align_1 = dst_align - 1;
    let dst_offset = (header_size + dst_align_1) & !dst_align_1;
    let dst = unsafe { &*mem::from_raw_parts(ptr.add(dst_offset), meta) };
    let dst_size = dst.size_of_val();
    let total_align_1 = total_align - 1;
    (dst_offset + dst_size + total_align_1) & !total_align_1
}

#[doc(hidden)]
fn compact_size_of_struct<P, W: ?Sized>(
    ptr: *const u8,
    meta: W::Meta,
    dst_align: usize,
) -> usize {
    let header_size = mem::compact_size_of::<P>();
    let dst_align_1 = dst_align - 1;
    let dst_offset = (header_size + dst_align_1) & !dst_align_1;
    let dst = unsafe { &*mem::from_raw_parts(ptr.add(dst_offset), meta) };
    let dst_compact_size = dst.compact_size_of_val();
    dst_offset + dst_compact_size
}

impl<T, U, V, W: ?Sized> Object for (T, U, V, W) {
    type Meta = W::Meta;
    fn align_of_meta(meta: Self::Meta) -> usize {
        cmp::max(mem::align_of::<(T, U, V)>(), W::align_of_meta(meta))
    }
    fn size_of_val(&self) -> usize {
        let (ptr, meta) = mem::into_raw_parts(self);
        let dst_align = W::align_of_meta(meta);
        let total_align = mem::align_of::<(T, U, V)>();
        size_of_struct::<(T, U, V), W>(ptr, meta, dst_align, total_align)
    }
    fn compact_size_of_val(&self) -> usize {
        let (ptr, meta) = mem::into_raw_parts(self);
        let dst_align = W::align_of_meta(meta);
        compact_size_of_struct::<(T, U, V), W>(ptr, meta, dst_align)
    }
}
```

Forward implementation of `DynSized`, `RegularSized`, `InlineSized`, `Aligned` and `Unsize`.

```rust
impl<T, U, V, W: ?Sized + DynSized> DynSized for (T, U, V, W) { ... }
impl<T, U, V, W: ?Sized + RegularSized> RegularSized for (T, U, V, W) { ... }
impl<T, U, V, W: ?Sized + InlineSized> InlineSized for (T, U, V, W) { ... }
impl<T, U, V, W: ?Sized + Aligned> Aligned for (T, U, V, W) {}
unsafe impl<T, U, V, WT: ?Sized, WF: Unsize<WT>> Unsize<(T, U, V, WT)> for (T, U, V, WF) {
    fn unsize(meta: Self::Meta) -> WT::Meta {
        WF::unsize(meta)
    }
}
```

Structures are similar. Forwarding `DynSized`, `RegularSized`, `InlineSized` and `Aligned`
involves determining the type of the last field. Forwarding `Unsize` has the same condition as
currently, i.e. `Foo<…, T, …>: Unsize<Foo<…, U, …>>` if

* The last field has type `X::Bar<T>` (the `T` can only appear attached to the last path component,
    i.e. `Bar<T>::X` will cause `Foo` not `Unsize`).
* `T: Unsize<U>`
* `Bar<T>: Unsize<Bar<U>>`
* `T` does not appear in any other fields (not even as `PhantomData<T>`)

We need to consider the effect of `#[repr]` attributes.

* If `#[repr(packed)]` is given, the alignment is always 1. The `Aligned` trait will be always
    implemented.

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
        fn size_of_val(&self) -> usize {
            let (ptr, meta) = mem::into_raw_parts(self);
            size_of_struct::<#[repr(packed)] (T, U, V), W>(ptr, meta, 1, 1)
        }
        fn compact_size_of_val(&self) -> usize {
            let (ptr, meta) = mem::into_raw_parts(self);
            compact_size_of_struct::<#[repr(packed)] (T, U, V), W>(ptr, meta, 1, 1)
        }
    }
    ```

    </details>

* If `#[repr(align(n))]` is given, the alignment is always `n`. The `Aligned` trait will be always
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
            n
        }
        fn size_of_val(&self) -> usize {
            let (ptr, meta) = mem::into_raw_parts(self);
            let dst_align = W::align_of_meta(meta);
            size_of_struct::<(T, U, V), W>(ptr, meta, dst_align, n)
        }
        fn compact_size_of_val(&self) -> usize {
            let (ptr, meta) = mem::into_raw_parts(self);
            let dst_align = W::align_of_meta(meta);
            compact_size_of_struct::<(T, U, V), W>(ptr, meta, dst_align)
        }
    }
    ```

    </details>

* If `#[repr(C)]` is given, `header_size` calculated in `size_of_struct` and
    `compact_size_of_struct` will use a `#[repr(C)]` tuple, and everything else are unchanged.

## Foreign types

Whenever an `extern { type Opaque; }` item is spotted, automatically implement `Object` as shown
below.

```rust ,ignore
impl Object for Opaque {
    type Meta = ();
    fn align_of_meta(_: ()) -> usize {
        panic!("Alignment of {} is unknown", intrinsics::type_name::<Self>())
    }
    fn size_of_val(&self) -> usize {
        panic!("Size of {} is unknown", intrinsics::type_name::<Self>())
    }
    fn compact_size_of_val(&self) -> usize {
        panic!("Compact size of {} is unknown", intrinsics::type_name::<Self>())
    }
}
```

## Custom DST

Introduce a new syntax to declare a custom DST.

```rust ,ignore
dyn type RDst<T>(C; M) where T: Bounds;     // regular DST
dyn type IDst<T>(C; ..) where T: Bounds;    // inline DST
```

The type `C` does not need to be `Sized`.

The variance of `T` will be the same as the tuple `(C, M)` or `C`.

If `C` implements an auto-trait, `RDst`/`IDst` will also implement it (`M`/`S` is not considered).

When a “regular” `dyn type` item is spotted, automatically implement `Object`, `DynSized` and
`Aligned` as shown below.

```rust ,ignore
impl<T> Object for RDst<T> where T: Bounds {
    type Meta = M;
    fn align_of_meta(_: M) -> usize { mem::align_of::<C>() }
    fn size_of_val(&self) -> usize { <Self as RegularSized>::size_of_meta(mem::meta(self)) }
    fn compact_size_of_val(&self) -> usize { <Self as RegularSized>::compact_size_of_meta(mem::meta(self)) }
}
impl<T> DynSized for RDst<T> where T: Bounds {}
impl<T> Aligned for RDst<T> where T: Bounds {}
```

The user is required to implement `RegularSized` for `RDst<T>` themselves.

When an “inline” `dyn type` item is spotted, automatically implement `Object`, `DynSized` and
`Aligned` as shown below.

```rust ,ignore
impl<T> Object for IDst<T> where T: Bounds {
    type Meta = ();
    fn align_of_meta(_: ()) -> usize { mem::align_of::<C>() }
    fn size_of_val(&self) -> usize { <Self as InlineSized>::size_of_ptr(self as *const Self as *const u8) }
    fn compact_size_of_val(&self) -> usize { <Self as InlineSized>::compact_size_of_ptr(self as *const Self as *const u8) }
}
impl<T> DynSized for IDst<T> where T: Bounds {}
impl<T> Aligned for IDst<T> where T: Bounds {}
```

The user is required to implement `InlineSized` for `IDst<T>` themselves.

Custom DSTs allow certain kinds of `#[repr]`:

* If `#[repr(align(n))]` is given, the alignment will be set to `n` instead of `align_of::<C>()`.
* If `#[repr(C)]` is given on an “inline” DST, the type is FFI-safe. Otherwise (“regular” DST), emit
    [E0517] error.
* Everything else (packed, simd, transparent) causes [E0517] error.

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

    #[deprecated]   // <-- function added to compensate for lack of `typeof`
    fn make_regular_place(self, meta: Data::Meta) -> Self::Place
    where
        Data: RegularSized,
    {
        self.make_place(Data::size_of_meta(meta), Data::align_of_meta(meta))
    }
}

pub trait BoxPlace<Data: ?Sized>: Place + Sized {
    fn make_place(size: usize, align: usize) -> Self;
//                ^~~~~~~~~~~~~~~~~~~~~~~~~ added

    #[deprecated]   // <-- function added to compensate for lack of `typeof`
    fn make_regular_place(meta: Data::Meta) -> Self
    where
        Data: RegularSized,
    {
        Self::make_place(Data::size_of_meta(meta), Data::align_of_meta(meta))
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

(The `make_regular_place` methods are added to compensate for the lack of `typeof` operator.)

The lowering of `$placer <- $expr` will be changed to:

```rust ,ignore
let placer = $placer;
let mut place = placer.make_regular_place(());
let ptr = place.pointer();
unsafe {
    intrinsics::move_val_init(ptr as *mut _, #[safe] { $expr });
    place.finalize(())
}
```

and the lowering of `box $expr` (if implemented) will be changed to:

```rust ,ignore
let mut place = BoxPlace::make_regular_place(());
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
unsafe fn finalize<T: Object + ?Sized>(b: IntermediateBox<T>, meta: T::Meta) -> Box<T> {
//                    ^~~~~~~~~~~~~~~
    let p = mem::from_raw_parts(b.ptr, meta);
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

* `align_of_val`, `size_of_val`, `compact_size_of_val`
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