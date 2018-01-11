# Drawbacks

This section lists drawbacks to the language if this RFC is accepted.

<!-- TOC depthFrom:2 -->

- [Size of fat pointer is changed](#size-of-fat-pointer-is-changed)
- [Complicated trait hierarchy](#complicated-trait-hierarchy)
- [More potential panicking sites](#more-potential-panicking-sites)

<!-- /TOC -->

## Size of fat pointer is changed

Currently an `&T` where `T: ?Sized` is always two-pointer long. While this assumption is already
broken by foreign types, it will be made worse by the introduction of custom DSTs, where the size of
`&T` can be anything.

If some code relies on `transmute` to do low-level manipulation of fat pointers, they will be
broken. This will be even more troublesome for standard types such as `CStr` and `OsStr`.

## Complicated trait hierarchy

The trait hierarchy becomes much more complex after this RFC. Trait bounds like `DynSized + ?Sized`
may feel repetitive and hard to read.

## More potential panicking sites

Allowing user to customize `align_of_val` and `unsize` is going to introduce places where a panic is
least expected. `align_of_val` will be used when finding the offset of a DST struct, meaning the
following expression may panic:

```rust
struct Dst<T: ?Sized>(u8, T);

fn g<T: ?Sized>(a: &Dst<T>) -> &T {
    &a.1    // <-- may panic!
}
```

Similarly, unsize coercion would also panic:

```rust
unsafe impl Unsize<MyDst> for MyType {
    fn unsize(_: ()) -> MyDst::Meta {
        panic!("oops!")
    }
}

let f = MyType;
let g: &MyDst = &f; // <-- panic!
```

