const std = @import("std");

pub const ActionKind = enum { cmd, install };

pub const Action = struct {
    kind: ActionKind,
    value: []const u8,
};

pub const Step = struct {
    number: u32,
    actions: []Action,
};

pub const RunBlock = struct {
    name: []const u8,
    needs: [][]const u8,
    steps: []Step,
};

pub const ExprKind = enum {
    string,
    call,
    eq,
    neq,
    and_,
    or_,
    not_,
    ternary,
};

pub const Expr = struct {
    kind: ExprKind,
    str: []const u8 = "",
    call_name: []const u8 = "",
    call_arg: []const u8 = "",
    left: ?*Expr = null,
    right: ?*Expr = null,
    cond: ?*Expr = null,
    then_expr: ?*Expr = null,
    else_expr: ?*Expr = null,
};

pub const WhenBlock = struct {
    condition: *Expr,
    actions: []Action,
};

pub const Program = struct {
    runs: []RunBlock,
    whens: []WhenBlock,
};
