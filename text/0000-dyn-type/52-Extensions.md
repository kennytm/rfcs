# Extensions

This section lists some proposals useful for custom DSTs, but are not essential, or makes this RFC
too complicated when included in the main text.

<!-- TOC depthFrom:2 -->

- [`#[repr]` as a constraint](#repr-as-a-constraint)
    - [Aligned foreign type](#aligned-foreign-type)
- [Copy initialization](#copy-initialization)
- [Customizing `needs_drop`](#customizing-needs_drop)
- [Unsized expressions](#unsized-expressions)
    - [Sized expressions](#sized-expressions)
    - [VLA expression](#vla-expression)
    - [Custom DST literal](#custom-dst-literal)
    - [Dereference expression](#dereference-expression)
    - [Move expression](#move-expression)
    - [Tuple expression](#tuple-expression)
    - [Control flow expressions](#control-flow-expressions)
    - [HIR-HAIR lowering](#hir-hair-lowering)

<!-- /TOC -->
<!-- spell-checker:ignore nonoverlapping -->

## `#[repr]` as a constraint

We may define *aligned trait objects*, in the form

```rust
#[repr(align(n))]
trait AlignedTrait { ... }
```

This will make `dyn Trait` implement `Aligned`, where `align_of_meta()` will return `n` instead of
`meta.align`.

When `#[repr(align(n))]` is defined on a trait, it is an error to implement such trait on types
which alignment is not exactly `n`.

```rust ,ignore
#[repr(align(2))]
trait X {}

impl X for u8 {} // error
impl X for u16 {} // ok
impl X for u32 {} // error
```

In fact, we could extend this behavior to anywhere a generic bound is expected:

* Super-traits
* Generic parameters
* Associated types

```rust ,ignore
#[repr(align(2))]
trait T<#[repr(align(2))] U> {
    #[repr(align(2))]
    type V: PartialEq<U>,
}
```

An alternative design is specify this through a const generic condition

```rust ,ignore
trait X: Aligned
where
    const(align_of::<Self>() == 2)
{}
```

but the compiler will need to reverse engineer the expression to know that the alignment is a
constant, in order to implement `Aligned` for `dyn X`.

### Aligned foreign type

Similar to above, we could apply `#[repr(align(n))]` to an `extern type`:

```rust
extern {
    #[repr(align(n))]
    type Opaque;
}
```

This will make `align_of_meta` return `n` instead of panicking. However, it still cannot implement
`Aligned` because `Opaque` still is not `DynSized`, and it is not worth it to break the assumption
that `Aligned: DynSized`.

## Copy initialization

We are able to clone the content of a `[String]`, provided we have got a sufficiently large buffer.
Similarly, we can `memcpy` a `str` to an uninitialized buffer. But we cannot implement `Clone` or
`Copy` to them since they expect `Sized` types.

[RFC #1909] suggests to remove the `Sized` bound on `Clone`, but this is a breaking change. Instead,
we suggest providing a new pair of traits:

```rust ,ignore
trait CloneInit {
    /// Clones the content of `self` into an uninitialized buffer of sufficient size.
    unsafe fn clone_init(&self, buf: *mut u8);
}
unsafe trait CopyInit: CloneInit {}
```

with the following implementations:

```rust ,ignore
impl<T: Clone> CloneInit for T {
    unsafe fn clone_init(&self, buf: *mut u8) {
        ptr::write(buf, self.clone());
    }
}
impl<T: Clone> CloneInit for [T] {
    unsafe fn clone_init(&self, buf: *mut u8) {
        let buf = buf as *mut T;
        for (i, elem) in self.iter().enumerate() {
            ptr::write(buf.add(i), elem.clone());
        }
    }
}
impl<T: Clone> CloneInit for str {
    unsafe fn clone_init(&self, buf: *mut u8) {
        ptr::copy(self.as_ptr(), buf, self.len());
    }
}

unsafe impl<T: Copy> CopyInit for T {}
unsafe impl<T: Copy> CopyInit for [T] {}
unsafe impl CopyInit for str {}
```

In the sized world, one could not simultaneously implement `Copy` and `Drop` due to [issue #20126],
and it will be further enforced after [RFC #1897]. However, we may not be able to apply the same
rule to `CopyInit` vs `Drop`. Because a custom DST has no fields,

However, unless we support negative trait bounds,
the matrix type `Mat<T>` will need to implement both `CopyInit` and `Drop`.

## Customizing `needs_drop`

While we implement `Drop` for `Mat<T>`, if the `T` does not need drop, the entire matrix itself can
skip the drop glue as well. For instance, `Mat<u32>` does not need a destructor.

We want a way to make `needs_drop::<Mat<u32>>()` return `false`. Currently `needs_drop` is defined
as:

> Returns true if the actual type given as `T` requires drop glue; returns `false` if the actual
> type provided for `T` implements `Copy`.

One natural extension is to change the “implements `Copy`” condition to “implements `CopyInit`”. But
as shown above, a type can implement both `CopyInit` and `Drop`, causing conflict. We need to
prioritize one condition. Nevertheless, no matter which decision is chosen the result should still
be safe (biasing towards `true` means extra unnecessary work, biasing towards `false` means memory
leak).

An alternative is allow user to customize `needs_drop`:

```rust ,ignore
#[lang = "drop"]
pub trait Drop {
    const NEEDS_DROP: bool = true;  // <-- new
    fn drop(&mut self);
}
```

and modify the signature of `needs_drop` to return `T::NEEDS_DROP` if `T` implements `Drop`. Also
ensure if `T::NEEDS_DROP` is false, the type and its fields will simply be leaked away. The `Mat<T>`
type could implement `Drop` as:

```rust ,ignore
impl<T> Drop for Mat<T> {
    const NEEDS_DROP: bool = needs_drop::<T>();

    fn drop(&mut self) {
        unsafe {
            // no need to check `needs_drop::<T>()` --
            //   if it is false, the `drop()` method will never be called.
            for element in self {
                drop_in_place(element);
            }
        }
    }
}
```

Allowing user to redefine `needs_drop` also let us to implement `ManuallyDrop<T>` ([RFC #1860]) with
an unsized struct, enabling it to hold DST and thus fixing [issue #47034] without introducing DST
unions.

```rust
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
#[repr(transparent)]
pub struct ManuallyDrop<T: ?Sized>(T);
unsafe impl<#[may_dangle] T: ?Sized> Drop for ManuallyDrop<T> {
    fn drop(&mut self) { unreachable!() }
    const NEEDS_DROP: bool = false;
}
```

## Unsized expressions

The main RFC does not specify what to do when we try to `box` or `<-` an unsized expression. The
following shows a potential implementation.

We could try to implement it using HIR lowering. The placement protocol can be generalized like
this:

```rust
let placer = $placer;
let (size, align, meta, alloc_info) = partial_evaluate!($expr);
let mut place = placer.make_place(size, align);
let ptr = place.pointer();
unsafe {
    fill_in!($expr);
    place.finalize(meta)
}
```

(We intentionally ignore variable scoping and hygiene in the following examples. Hygiene is
irrelevant at HIR level anyway.)

### Sized expressions

If we allocate with a sized expression `$placer <- $expr`, the placement protocol is expanded as

```rust ,ignore
let placer = $placer;
let mut place = placer.make_regular_place(());
let ptr = place.pointer();
unsafe {
    intrinsics::move_val_init(ptr as *mut _, #[safe] { $expr });
    place.finalize(())
}
```

or, in terms of the general template,

```rust ,ignore
macro partial_evaluate($expr:expr) {
    type T = typeof($expr);
    (mem::size_of::<T>(), mem::align_of::<T>(), (), ())
}
macro fill_in($expr:expr) {
    intrinsics::move_val_init(ptr as *mut T, #[safe] { $expr });
}
```

“Sized expressions” apply to the following:

* ExprBox (`box x`)
* ExprArray (`[x, y, z]`)
* ExprCall (`f(x)`)
* ExprMethodCall (`a.f(x)`)
* ExprTup (`(x, y, z)`)
* ExprBinary (`x + y`, `x - y`, …)
* ExprUnary(UnNot) (`!x`)
* ExprUnary(UnNeg) (`-x`)
* ExprLit (`1`, `2.3`, `'a'`, `true`, …)
* ExprCast (`x as T`)
* ExprType (`x: T`)
* ExprWhile (`while x { ... }`)
* ExprClosure (`|x| { ... }`)
* ExprAssign (`x = y`)
* ExprAssignOp (`x += y`, …)
* ExprAddrOf (`&x`, `&mut x`)
* ExprBreak (`break`)
* ExprAgain (`continue`)
* ExprRet (`return`)
* ExprInlineAsm (`asm!(...)`)
* ExprStruct (`Foo { x, y, ..z }`)
* ExprRepeat (`[x; n]`)
* ExprYield (`yield x`)

(Note: in the future we may support unsized output from ExprTup, ExprStruct and ExprCast/ExprType.)

### VLA expression

If we allocate with a repeating variable-length array (VLA) `$placer <- vla![$val; $len]`:

```rust ,ignore
let placer = $placer;
let len: usize = $len;
let mut place = placer.make_regular_place(len);
unsafe {
    if len > 0 {
        let ptr = place.pointer() as *mut _;
        intrinsics::move_val_init(ptr, #[safe] { $val });
        for i in 1..len {
            intrinsics::move_val_init(ptr.add(i), *ptr);
        }
    }
    placer.finalize(len)
}
```

or, in terms of the general template,

```rust ,ignore
macro partial_evaluate(vla![$val:expr; $len:expr]) {
    type T = typeof($val);
    let len: usize = $len;
    (<[T]>::size_of_meta(len), mem::align_of::<T>(), len, ())
}
macro fill_in(vla![$val:expr; $len:expr]) {
    if len > 0 {
        let ptr = ptr as *mut T;
        intrinsics::move_val_init(ptr, #[safe] { $val });
        for i in 1..len {
            intrinsics::move_val_init(ptr.add(i), *ptr);
        }
    }
}
```

Note that this necessarily violates Rust’s left-to-right evaluation order: the length will be
evaluated before the value.

### Custom DST literal


### Dereference expression

Allocate from a dereference `$placer <- *$ptr` may mean three things

1. `*$ptr` is `CopyInit`. The content will be `memcpy`ed and `$ptr` should not be moved.
2. `$ptr` is a box. The content will be `memcpy`ed and `$ptr` *will be consumed*.
3. None of the above, which should cause a compile-time error.

The problem is the first two conditions are in direct conflict with each other. After the
`$placer <- *$ptr` expression, the `$ptr` must be accessible in case 1, but must not be accessible
in case 2. We need to generate different consumption pattern according to the type of `$ptr` which
is not available at HIR level.

```rust ,ignore
let p1 = Box::new(1);
let q1 = HEAP <- *p1;   // ok
let r1 = p1;            // ok

let p2 = Box::new("2".to_owned());
let q2 = HEAP <- *p2;   // ok
let r2 = p2;            // error

let p3 = Rc::new(3);
let q3 = HEAP <- *p3;   // ok
let r3 = p3;            // ok

let p4 = Rc::new("4".to_owned());
let q4 = HEAP <- *p4;   // error
```

If `$ptr` is a smart pointer to some copyable type,

```rust ,ignore
macro partial_evaluate(*$ptr:expr) {
    let r = &*$ptr;
    let size = mem::size_of_val(&*r);
    let align = mem::align_of_val(&*r);
    let (src, meta) = mem::into_raw_parts(&*r);
    (size, align, meta, r)
}
macro fill_in(*$ptr:expr) {
    ptr::copy_nonoverlapping(src, ptr, size);
}
```

Otherwise, if `$ptr` is a box,

```rust ,ignore
macro partial_evaluate(*$ptr:expr) {
    let r = $ptr;
    let size = mem::size_of_val(&*r);
    let align = mem::align_of_val(&*r);
    let (src, meta) = mem::into_raw_parts(&*r);
    (size, align, meta, r)
}
macro fill_in(*$ptr:expr) {
    ptr::copy_nonoverlapping(src, ptr, size);
    box_free(alloc_info.into_raw());    // free the box without dropping content.
}
```

“Dereference expression” applies to the following:

* ExprUnary(UnDeref) (`*x`)
* ExprIndex (`x[i]`) — `$ptr` is defined to be `&x[i]`.

Note that `$ptr` is evaluated completely before we even make a place. This is fine because the
pointer itself is not something we want to place into the buffer, it is the content of the pointer,
and the content already exists somewhere else.

This expansion uses `copy_nonoverlapping` to move bytes. If `*$ptr` is always sized, we could
generate a `move_val_init` instead. We may create a new intrinsic for this to help optimization.

### Move expression

If we allocate from an existing variable `$placer <- $var`:

```rust ,ignore
macro partial_evaluate($var:expr) {
    let r = &$var;
    let size = mem::size_of_val(r);
    let align = mem::align_of_val(r);
    let (src, meta) = mem::into_raw_parts(r);
    drop(r);
    (size, align, meta, ())
}
macro fill_in($var:expr) {
    ptr::copy_nonoverlapping(src, ptr, size);
    mem::forget($var);
}
```

“Move expression” applies to the following:

* ExprField (`x.field`)
* ExprTupField (`x.3`)
* ExprPath (`x`)

### Tuple expression

Allocating from a tuple expression `$placer <- ($a, $b, $c, $dst)` is like

```rust ,ignore
macro partial_evaluate(($a:expr, $b:expr, $c:expr, $dst:expr)) {
    type H = typeof(($a, $b, $c));
    let (dst_size, dst_align, dst_meta, dst_alloc_info) = partial_evaluate!($dst);
    let header_size = mem::compact_size_of::<H>();
    let dst_offset = (header_size + dst_align - 1) & !(dst_align - 1);
    let total_align = cmp::max(mem::align_of::<H>(), dst_align);
    let total_size = (header_size + dst_size + total_align - 1) & !(total_align - 1);
    (total_size, total_align, dst_meta, dst_alloc_info)
}
macro fill_in(($a:expr, $b:expr, $c:expr, $dst:expr)) {
    type T = typeof(($a, $b, $c, $dst));
    let header = ptr as *mut H;
    intrinsics::move_val_init(header, ($a, $b, $c));
    let ptr = ptr.add(dst_offset);
    fill_in!($dst);
}
```

Allocating from a struct expression `$placer <- Foo { x, y, ..z }` is similar, but one first needs
to identify which field is the DST field, which information might not be available at HIR level.

### Control flow expressions

Placer expression is commutative with control flow expressions, e.g. `if`:

```rust ,ignore
let x = $placer <- if condition() {
    a()
} else {
    b()
};

let placer = $placer;
let x = if condition() {
    placer <- a()
} else {
    placer <- b()
};
```

`match`:

```rust ,ignore
let x = $placer <- match key() {
    pat1 => a(),
    pat2 => b(),
    _ => c(),
};

let placer = $placer;
let x = match key() {
    pat1 => placer <- a(),
    pat2 => placer <- b(),
    _ => placer <- c(),
};
```

and `loop`:

```rust ,ignore
let x = $placer <- 'a: loop {
    statements();
    break 'a expr();
    more_statements();
};

let placer = $placer;
let x = 'a: loop {
    statements();
    break 'a placer <- expr();
    more_statements();
};
```

### HIR-HAIR lowering

We noted that `$placer <- *$ptr` and `$placer <- Foo { $a, $b }` would require complete type
information to make sense. This suggests doing the lowering at during the AST→HIR step may be too
early. Instead, we may perform the lowering at HIR→HAIR level where all types are already resolved
and ready to be transformed into MIR.

For this to work, we need to keep `<-` as a binary operator. We also need to ensure the type-checker
recognize `<-` and `box`. To the type-checker, the following should prove equivalent results:

```rust ,ignore
owner = placer <- expr;

fn placement_in<P: Placer<D>, D: ?Sized>(placer: P, expr: D) -> <P::Place as InPlace<D>>::Owner;
owner = placement_in(placer, expr);
```

and the following should prove equivalent results:

```rust ,ignore
boxed = box expr;

fn box_new<B: Boxed>(expr: B::Data) -> B;
boxed = box_new(expr);
```
