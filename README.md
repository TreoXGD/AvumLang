# Avum

A small reverse-polish, stack-based language with its own REPL, written in Zig from scratch with no parsing and VM.

## Building and running

Built against Zig 0.16, anything lower will not work. No arguments are accepted right now.

```
zig build run    # start the REPL
zig build test   # run the test suite
```

## How it works

It's stack-based: push numbers, then apply operators. Instead of `3 + 4` you write:

```
# 3 4 + debug
> 7
```

Operands first, operator last. Binary operators always pop the top two values, apply the operator, and push the result back.

## Numbers

Ints and floats both work. Floats need a digit before _and_ after the `.`. No `.5` or `5.`.

A negative number is a `-` glued directly to a digit, no space in between.
This means `-` immediately before a digit is read as part of a negative literal, not subtraction, so `5-3` actually lexes as two separate numbers (`5` and `-3`), not "5 minus 3".
Put spaces around `-` if you want subtraction: `5 - 3`.

## Arithmetic

```
+  - pops 2, pushes their sum
-  - pops 2, pushes second-from-top minus top
*  - pops 2, pushes their product
/  - pops 2, pushes second-from-top over top (errors if top is 0)
%  - pops 2, pushes the remainder of the same (errors if top is 0)
neg   - negates the top
abs   - absolute value of the top
min   - pops 2, pushes the smaller
max   - pops 2, pushes the bigger
```

Mixing an int and a float promotes the int to a float first, so `3 2.5 +` gives you `5.5` instead of an error.

## Comparisons and booleans

```
<   <=   >   >=   ==   !=
```

All of these pop 2 numbers and push a `bool`.
The only way to get a `bool` onto the stack is a comparison, or `!` on one that's already there.

## Bitwise and boolean logic

```
&    - pops 2 ints, pushes their bitwise and
|    - pops 2 ints, pushes their bitwise or
&&   - pops 2 bools, pushes their logical and
||   - pops 2 bools, pushes their logical or
```

These don't short-circuit the way `&&`/`||` do in most languages and structurally can't, since both sides are already sitting on the stack, fully evaluated, before the operator itself ever runs.

## Variables

```
5 $x     ; pops 5, stores it under x
@x       ; looks x up and pushes a copy
```

`$name` pops the top of the stack and stores it. `@name` pushes whatever's stored under that name. Names start with a letter, then any mix of letters and digits.

There's also `:name`, which is shorthand for `@name call`. Saves typing the same two things over and over for something you call a lot.

## Blocks, call, if / ifelse, while

`{ ... }` doesn't run what's inside it, and instead packages the tokens up into a value and pushes that. `call` is what actually runs a block:

```
{ 2 1 + } call debug
> 3
```

`if` and `ifelse` are basically `call` with a condition attached. Pop a bool first, then run whichever block(s) fit:

```
5 3 > { 100 } { -100 } ifelse debug
> 100
```

`while` is an `if` operation that continues to call its body for as long as the condition block pushes true boolean.

```
5 $i
{ @i 0 > }             ; condition
{ @i print nl @i 1 - $i}  ; body
while
```

Since a block is just a value like anything else, you can stash one in a variable and get functions out of it for free, including the recursive ones:

```
{ dup 0 == { drop 1 } { dup 1 - :fact * } ifelse } $fact
3 :fact debug
> 6
```

That's a recursive factorial. `fact` calls itself through `:fact` inside its own body.
It works because the lookup only happens when the block actually _runs_, and by then `$fact` has already finished storing it.
No special recursion syntax needed for that to work, but there is recursion depth limit.

## Stack manipulation

```
dup    - duplicates the top
swap   - swaps the top two
drop   - removes the top
over   - copies the second-from-top to the top
rot    - moves the third-from-top to the top
```

## Everything else

```
debug      - pops and prints the top on a separate line with new line character after
print      - pops and prints the top without any additional characters
peek       - prints the top without popping it
stack      - prints the whole stack, top to bottom
clear      - empties the stack
vars       - lists every defined variable
varclear   - forgets every defined variable
quit       - exits the REPL
help       - prints all of this from inside the REPL
```

`;` starts a comment, runs to the end of the line.

## Features to add

- [x] Array data type
- [x] String data type
- [x] Garbage collector
- [ ] Importing files
- [ ] File manipulation
- [ ] Better I/O operations
- [ ] Type check operations
- [ ] Taking command line arguments
- [ ] Better error reporting
