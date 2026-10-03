const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LexError = error{
    NotKeyword,
    UnsupportedCharacter,
    Overflow,
    DecimalPointWithoutNumber,
    GetVarWithoutValidVar,
    SetVarWithoutValidVar,
    CallVarWithoutValidVar,
    EqualWithoutSecondEqual,
    UnclosedString,
} || Allocator.Error;

pub const EvalError = error{
    StackUnderflow,
    DivisionByZero,
    WriteFailed,
    OverflowOnCommand,
    InvalidFloat,
    UndefinedVariable,
    UnmatchedRightBrace,
    UnmatchedRightBracket,
    NotANumber,
    NotAnInteger,
    NotAFloat,
    NotABlock,
    NotABoolean,
    NotAnArray,
    NotAString,
    AccessOutsideArrayBounds,
    CallStackOverflow,
    BlockLeftWrongElementCount,
    NegativeArraySize,
    Quit,
} || Allocator.Error;
