# Tutorial

> Even if this is a “guide-level” explanation, reader is still expected to understand what is a
> dynamic-sized type and why slices `&[T]` and trait objects `&dyn Trait` are implemented as
> [fat pointers].
>
> These can be referred in TRPL 2/e [§4.3], [§17.2], and also Rustonomicon [§2.2].

[§4.3]: https://doc.rust-lang.org/book/second-edition/ch04-03-slices.html
[§17.2]: https://doc.rust-lang.org/book/second-edition/ch17-02-trait-objects.html
[§2.2]: https://doc.rust-lang.org/nomicon/exotic-sizes.html
[fat pointers]: https://www.google.com/search?tbm=isch&q=fat+pointer

<!-- TOC depthFrom:2 -->

- [Dynamic sized types](#dynamic-sized-types)
- [The case for custom DSTs](#the-case-for-custom-dsts)
- [Creating custom DSTs](#creating-custom-dsts)
- [Using the DST](#using-the-dst)
- [Destructor](#destructor)
- [Unsizing](#unsizing)

<!-- /TOC -->

## Dynamic sized types

Dynamic-sized types (DSTs) are types where the memory structure cannot be sufficiently determined at
compile time. Memory structure means the allocation size, data alignment, destructor, etc. In order
to know these, pointers to DSTs will need to carry additional *metadata* to supplement the
calculation at runtime. In Rust there are two built-in DSTs:

* Slices `[T]` and string slice `str` — you need to know how long the slice is, so the metadata is
    the slice length.
* Trait objects `dyn Trait` — you need to know the concrete type, so the metadata is information
    about the type itself (size, alignment, destructor function pointer, and trait vtable).

Introducing DSTs in Rust allows us to separate the concern of “where to place these memory as a
whole” vs “how to use the content in this memory region”. This allows, e.g. slices be easily
supported by any resource management schemes, be it a raw pointer `*[T]`, shared reference `&[T]`,
owned box `Box<[T]>`, ref-counted container `Rc<[T]>`, even third-party smart pointers like
`Gc<[T]>`.

## The case for custom DSTs

Slices and trait objects are not flexible enough for every use case. Sometimes you need to define
your own *custom DST*. An example is a 2D matrix. If we do not have custom DSTs, we would represent
a rectangular sub-matrix as

```rust ,ignore
struct MatrixRef<'a, T> {
    elements: &'a [T],
    width: usize,
    height: usize,
    stride: usize,
}
```

This structure is not scalable to additional smart pointers — you’ll need a `BoxMatrix<T>` to
support elements stored in a `Box<[T]>`, a `RcMatrix<T>` for elements in `Rc<[T]>`, etc. One may
attempt to turn this type into a DST itself by storing elements as a flexible array member at the
end of the structure:

```rust ,ignore
struct MatrixData<T> {
    width: usize,
    height: usize,
    stride: usize,
    elements: [T],
}
```

This, however, has a problem that cannot be sub-sliced, because `Index` requires you to return a
reference without allocation!

```rust ,ignore
impl<T> Index<Range<usize>, Range<usize>> for MatrixData<T> {
    type Output = Self;
    fn index(&self, index: (Range<usize>, Range<usize>)) -> &Self {
        // Ok, how could you obtain a sub-matrix of `self`
        // while placing the `width`, `height`, `stride` members
        // in the correct position?
        //
        // Try it. No, it is impossible without allocation.
        panic!()
    }
}
```

The correct way is to make the width, height and stride metadata themselves, placed outside of the
elements array

```rust ,ignore
#[derive(Copy, Clone)]
struct MatMeta {
    width: usize,
    height: usize,
    stride: usize,
}
magic!{"
    declare a custom DST `Mat<T>`,
    then somehow convince the compiler to treat every `*Mat<T>` as `(*T, MatMeta)`
"}
```

## Creating custom DSTs

Starting from Rust 1.XX, we are allowed to define custom DSTs with arbitrary metadata:

```rust ,ignore
dyn type Mat<T>(T; MatMeta);
```

This tells the compiler that:

* A pointer to a matrix `*Mat<T>` can be safely cast to a simple pointer `*T`. This also sets the
    alignment of `Mat<T>` to be the same as `T`.
* The pointer itself will carry a metadata represented by the type `MatMeta`.

In memory it looks like this:

```
          ┏━━━┳━━━┯━━━┯━━━┓
&Mat<T> = ┃ ● ┃ w │ h │ s ┃
          ┗━│━┻━━━┷━━━┷━━━┛
            │   ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            ╰─▶︎ ┃ (size determined by width, height, stride) ...
                ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

We can calculate the actual size of the matrix using the width, height and stride alone:

```rust ,ignore
impl MatMeta {
    fn len(&self) -> usize {
        if self.height == 0 {
            0
        } else {
            (self.height - 1) * self.stride + self.width
        }
    }
}
```

We call this kind of DSTs a *regular-sized DST*. We provide the size by implementing the
`RegularSized` trait:

```rust ,ignore
use std::marker::RegularSized;
use std::mem::size_of;

impl<T> RegularSized for Mat<T> {
    fn size_of_meta(meta: Self::Meta) -> usize {
        size_of::<T>() * meta.len()
    }
}
```

## Using the DST

The metadata of our DST contains essential information how to retrieve the elements. It should be
easily retrievable from a `&Mat<T>`. Some convenient functions can be found in `std::mem` module,
e.g. we could extract the metadata via `std::mem::into_raw_parts` and its mutable variant:

```rust ,ignore
use std::mem;
use std::slice;

impl<T> Mat<T> {
    fn iter_mut<'a>(&'a mut self) -> impl Iterator<Item=&'a mut T> {
        let (ptr, meta) = mem::into_raw_parts_mut(self);
        // The type `ptr` is `*mut u8`, we need to cast it to `*mut T`.
        let slice = unsafe { slice::from_raw_parts_mut(ptr as *mut T, meta.len() };
        slice.chunks_mut(meta.stride).flat_map(|c| &mut c[..meta.width])
    }
}
```

We could similarly assemble a DST using `std::mem::from_raw_parts`:

```rust ,ignore
impl<T> Index<(RangeFull, RangeTo<usize>)> for Mat<T> {
    type Output = Self;
    fn index(&self, index: (RangeFull, RangeTo<usize>)) -> &Self {
        let (ptr, mut meta) = mem::into_raw_parts(self);
        meta.height = index.1.end;
        unsafe { &*mem::from_raw_parts(ptr, meta) }
    }
}
```

## Destructor

A custom DST may contain any content the implementor designs to have. The compiler does not know
what “fields” the DST contains, and thus will not automatically register a destructor for it. This
means if we have a `Box<Mat<String>>`, the content will simply be leaked. While this is safe, it is
a very bad outcome.

We could fix this by implementing `Drop` as usual, but we do need to manually drop the fields.

```rust ,ignore
impl<T> Drop for Mat<T> {
    fn drop(&mut self) {
        if mem::needs_drop::<T>() {
            unsafe {
                for elem in self.iter_mut() {
                    drop_in_place(elem);
                }
            }
        }
    }
}
```

## Unsizing

Built-in Rust DSTs like slice and trait objects support “unsize coercion”, which allows you to turn
a sized pointer into an unsized pointer:

```rust ,ignore
let array: &[u32; 4] = &[1, 2, 3, 4];
let slice: &[u32] = array;  // <-- coercion: `&[u32; 4]` becomes `&[u32]`!
```

This makes constructing a new DST much easier! Unsize coercion works by transforming the metadata
value (here, from `()` to `4`), and reinterpret the pointed memory as the target type.

We could write these rules for our custom DSTs as well, through the `std::marker::Unsize` trait:

```rust ,ignore
unsafe impl<T, const width: usize, const height: usize> Unsize<Mat<T>> for [[T; width]; height] {
    fn unsize(_: ()) -> MatMeta {
        MatMeta {
            width,
            height,
            stride: width,
        }
    }
}
```

Unsizing works not just between sized and unsized type, it can be done between two DSTs too!

```rust ,ignore
unsafe impl<T: const width: usize> Unsize<Mat<T>> for [[T; width]] {
    fn unsize(height: usize) -> MatMeta {
        MatMeta {
            width,
            height,
            stride: width,
        }
    }
}
```

These allows us to e.g. create a boxed matrix through unsizing:

```rust ,ignore
let matrix: Box<Mat<u32>> = Box::new([
    [1, 0, 0, 0],
    [0, 1, 0, 0],
    [0, 0, 1, 0],
    [0, 0, 0, 1],
]);
```
