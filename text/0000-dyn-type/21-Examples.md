# Examples

Some DST examples.

<!-- TOC depthFrom:2 -->

- [Matrix](#matrix)
    - [Implementation](#implementation)
    - [Destructor](#destructor)
    - [Unsize](#unsize)
    - [Indexing](#indexing)
- [CStr](#cstr)
- [Length-prefixed array](#length-prefixed-array)
- [Bit-array slice](#bit-array-slice)
- [WTF-8 slice](#wtf-8-slice)
- [Multi-encoding string](#multi-encoding-string)
- [Pointer thinning](#pointer-thinning)
- [Custom smart pointer](#custom-smart-pointer)

<!-- /TOC -->

## Matrix

We have gone through the implementation of matrix in the tutorial. We are reproducing it here again.

### Implementation

The metadata type is required to be `Copy + Sized + Send + Sync + Ord + Hash`. Usually `#[derive]`
is enough.

```rust ,ignore
#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MatMeta {
    width: usize,
    height: usize,
    stride: usize,
}
impl MatMeta {
    fn len(&self) -> usize {
        if self.height == 0 {
            0
        } else {
            self.stride * (self.height - 1) + self.width
        }
    }
    fn to_linear_index(&self, x: usize, y: usize) -> usize {
        x * self.stride + y
    }
}
```

Declare our DST.

We define the size and “compact size” of the type. The compact size is the size excluding trailing
padding.

```rust ,ignore
pub dyn type Mat<T>(T; MatMeta);

impl<T> RegularSized for Mat<T> {
    fn size_of_meta(meta: MatMeta) -> usize {
        meta.len() * mem::size_of::<T>()
    }
    fn compact_size_of_meta(meta: MatMeta) -> usize {
        let len = meta.len();
        if len == 0 {
            0
        } else {
            mem::size_of::<T>() * (len - 1) + mem::compact_size_of::<T>()
        }
    }
}
```

Expose the metadata data

```rust ,ignore
impl<T> Mat<T> {
    pub fn width(&self) -> usize { mem::meta(self).width }
    pub fn height(&self) -> usize { mem::meta(self).height }
    pub fn stride(&self) -> usize { mem::meta(self).stride }
}
```

Internally we treat the matrix as a slice, to simplify implementation of other methods. This method
is unsafe due to unused elements between rows.

```rust ,ignore
impl<T> Mat<T> {
    unsafe fn as_slice(&self) -> &[T] {
        let (ptr, meta) = mem::into_raw_parts(self);
        slice::from_raw_parts(ptr as *const T, meta.len())
    }
    unsafe fn as_slice_mut(&mut self) -> &mut [T] {
        let (ptr, meta) = mem::into_raw_parts_mut(self);
        slice::from_raw_parts_mut(ptr as *mut T, meta.len())
    }
}
```

### Destructor

We could overload `needs_drop::<Mat<T>>()`. If `T` has no destructors, we shouldn’t need to call the
destructor.

```rust ,ignore
impl<T> Drop for Mat<T> {
    fn drop(&mut self) {
        if mem::needs_drop::<T>() {
            unsafe {
                for elem in self.iter_mut() {
                    ptr::drop_in_place(elem);
                }
            }
        }
    }
}
```

### Unsize

Construct a matrix from 2D array or slice of array.

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

### Indexing

The whole reason why matrix needs to be a DST in the first place. First let’s see how we implement
normal indexing for a single element.

```rust ,ignore
impl<T> Index<(usize, usize)> for Mat<T> {
    type Output = T;
    fn index(&self, index: (usize, usize)) -> &T {
        let meta = mem::meta(self);
        assert!(index.0 < meta.width, "column index out of bounds");
        assert!(index.1 < meta.height, "row index out of bounds");
        let index = meta.to_linear_index(index.0, index.1);
        unsafe { &self.as_slice()[index] }
    }
}
```

Now try to fetch a rectangular sub-matrix:

```rust ,ignore
impl<T> Index<(Range<usize>, Range<usize>)> for Mat<T> {
    type Output = Self;
    fn index(&self, index: (Range<usize>, Range<usize>)) -> &Self {
        let (ptr, meta) = mem::into_raw_parts(self);
        assert!(index.0.start <= index.0.end, "invalid column range");
        assert!(index.0.end <= meta.width, "column index out of bounds");
        assert!(index.1.start <= index.1.end, "invalid row range");
        assert!(index.1.end <= meta.height, "row index out of bounds");

        let start_index = meta.to_linear_index(index.0.start, index.1.start);
        unsafe {
            let ptr = (ptr as *const T).add(start_index);
            &*mem::from_raw_parts(ptr as *const u8, MatMeta {
                width: index.0.len(),
                height: index.1.len(),
                stride: meta.stride,
            })
        }
    }
}
```

## CStr

## Length-prefixed array

## Bit-array slice

## WTF-8 slice

## Multi-encoding string

## Pointer thinning

## Custom smart pointer