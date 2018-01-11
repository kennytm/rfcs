# Alternatives

This section lists some alternatives of to the current proposed RFC.

<!-- TOC depthFrom:2 -->

- [Generalizing indexing](#generalizing-indexing)
- [Pointer family](#pointer-family)
- [Generalized metadata](#generalized-metadata)

<!-- /TOC -->

## Generalizing indexing

Instead of introducing custom DSTs, we may solve the “`Index` requires `&T`” problem by introducing
the `IndexMove` trait ([RFC issue #997]):

```rust ,ignore
trait IndexMove<Idx> {
    type Output;
    fn index_move(self, idx: Idx) -> Self::Output;
}
```

With this, we can define slicing on a matrix reference as

```rust ,ignore
struct MatrixRef<'a, T: 'a> {
    elements: &'a [T],
    width: usize,
    height: usize,
    stride: usize,
}
impl<'a, T: 'a> Clone for MatrixRef<'a, T> { ... }
impl<'a, T: 'a> Copy for MatrixRef<'a, T> {}

impl<'a, T: 'a> IndexMove<(RangeFull, RangeFull)> for MatrixRef<'a, T> {
    type Output = Self;
    fn index_move(self, _: (RangeFull, RangeFull)) -> Self {
        self
    }
}
```

We can also implement it on an owned matrix:

```rust ,ignore
impl<'a, T: 'a> IndexMove<(RangeFull, RangeFull)> for &'a Matrix<T> {
    type Output = MatrixRef<'a, T>;
    fn index_move(self, _: (RangeFull, RangeFull)) -> MatrixRef<'a, T> {
        MatrixRef {
            elements: &self.elements,
            width: self.width,
            height: self.height,
            stride: self.width,
        }
    }
}
```

but the slice will need to be access through the strange syntax `let mr = (&m)[(.., ..)]` instead of
the more natural `let mr = &m[(.., ..)]`. Furthermore, the latter syntax cannot be used to produce
`mr: MatrixRef<T>` since we expect the `&` operator to produce a reference, not a struct.

## Pointer family

One advantage of custom DST is usable to multitude of smart pointers. We could reproduce the same
benefit using GATs.

First, introduce the *pointer family* trait:

```rust ,ignore
trait PointerFamily {
    type Pointer<T: ?Sized>;
    // note: not bounding with Deref since we want to support `*const T` as well.
}

struct ConstPtrFamily;
impl PointerFamily for ConstPtrFamily {
    type Pointer<T: ?Sized> = *const T;
}

struct RefFamily<'a>(PhantomData<&'a ()>);
impl<'a> PointerFamily for RefFamily<'a> {
    type Pointer<T: ?Sized> = &'a T;
}

struct RcFamily;
impl PointerFamily for RcFamily {
    type Pointer<T: ?Sized> = Rc<T>;
}

...
```

We could then define `Matrix<P>` as:

```rust ,ignore
struct Matrix<P: PointerFamily, T> {
    elements: P::Pointer<[T]>,
    width: usize,
    height: usize,
    stride: usize,
}
```

An advantage of GATs is ability to represent multiple pointers, e.g.

```rust ,ignore
struct Tensor<P: PointerFamily, T> {
    elements: P::Pointer<[T]>,
    ranges: P::Pointer<[(/*len*/usize, /*stride*/usize)]>,
}
```

and then we get `Tensor<RefFamily<'a>, T>`, `Tensor<BoxFamily, T>`, `Tensor<GcFamily, T>` etc, all
of which cannot be represented using custom DST (`&Tensor<T>`, `Box<Tensor<T>>`, `Gc<Tensor<T>>`)
since the metadata type needs `Copy`.

(Note that such trick does not really depend on GATs. For instance, `ndarray` is already using this
approach in the [`ArrayBase` type][ndarray::ArrayBase], though the implementation is not pretty
without GATs.)

[ndarray::ArrayBase]: https://docs.rs/ndarray/0.11.0/ndarray/struct.ArrayBase.html

## Generalized metadata

The bounds for metadata type is currently too strict and too relaxed. It is too strict since
pointers like `*mut T` does not need `Send + Sync`, and references like `&'a T` only needs `'a`
lifetime instead of `'static`. It is too relaxed since bounds like `UnwindSafe` is missing due to
libstd/libcore separation.

Furthermore, as shown above, custom DST is useless for `ndarray` as we cannot store the
arbitrarily-long stride as a `Vec` is not `Copy`.

These can be solved if we make `Meta` a GAT which takes a pointer family, and allow the pointer
family to specify what traits `Meta` should bound for using associated trait bounds
([RFC issue #2190]).

```rust ,ignore
trait PointerFamily {
    trait MetaBounds;
    type Pointer<T: ?Sized>;
}

struct ConstPtrFamily;
impl PointerFamily for ConstPtrFamily {
    trait MetaBounds = Copy + Ord + Hash + UnwindSafe + 'static;
    type Pointer<T: ?Sized> = *const T;
}

struct RefFamily<'a>(PhantomData<&'a ()>);
impl<'a> PointerFamily for RefFamily<'a> {
    trait MetaBounds = Copy + Send + Sync + UnwindSafe + 'a;
    type Pointer<T: ?Sized> = &'a T;
}

struct RcFamily;
impl PointerFamily for RcFamily {
    trait MetaBounds = Clone + UnwindSafe + 'static;
    type Pointer<T: ?Sized> = Rc<T>;
}
```

```rust ,ignore
trait Object {
    type Meta<P: PointerFamily>: Sized + P::MetaBounds;
}
```

and a `Box<Dst>` will be represented as `(Box<()>, Dst::Meta<BoxFamily>)` in memory. This allows us
to write the high-dimensional tensor slice as

```rust ,ignore
impl Object for Tensor<T> {
    type Meta<P: PointerFamily> = P::Pointer<[(usize, usize)]>;
}
```

Since we can’t implement `Object` directly, we need to introduce a third kind of DST syntax e.g.

```rust ,ignore
dyn type Tensor<T>(T; ** <P: PointerFamily> P<[(usize, usize)]>);
```

The problem of generalizing `Meta` is that it will plague every API it touches, e.g.

```rust
fn align_of_meta<P: PointerFamily>(meta: Self::Meta<P>) -> usize;
//              ^~~~~~~~~~~~~~~~~~                 ^~~
fn meta_from_skeleton<P: PointerFamily>(skeleton: Self::Skeleton) -> Self::Meta<P>;
//                   ^~~~~~~~~~~~~~~~~~                                        ^~~
pub fn meta<T: Object + ?Sized, P: PointerFamily>(dst: P::Pointer<T>) -> T::Meta<P>;
//                              ^~~~~~~~~~~~~~~~       ^~~~~~~~~~               ^~~
fn unsize<P: PointerFamily>(meta: Self::Meta<P>) -> T::Meta<P>;
//       ^~~~~~~~~~~~~~~~~~                 ^~~            ^~~
// etc.
```

and thus makes custom DST very complicated to use. Also, generalizing `Meta` may be a breaking
change, that means if we have stabilized one solution, we have to stick with it.

Should we generalize `Meta`? We believe the answer is *no*. `ndarray` is a pretty special case where
the metadata itself is unsized, and even for tensors, we could support it using a non-GAT `Meta` by
limiting the number of dimensions (6 dimensions is enough for everyone). In fact, the requirement of
`ndarray` of supporting “parallel pointers” where a single `&T` type points to multiple, separate
objects (the tensor data and the strides) may worth a separate feature, instead of shoehorning it on
top of custom DST metadata.
