const std = @import("std");
const util = @import("Util.zig");
const Lexer = @import("Lexer.zig");
const ParseArguments = @import("ParseArgs.zig");
const codeGen = @import("CodeGen.zig").codeGen;

const usage = @import("General.zig").usage;
const message = @import("General.zig").message;

const Result = util.Result;

const getArguments = ParseArguments.getArguments;
const Arguments = ParseArguments.Arguments;
const lex = Lexer.lex;
const Parser = @import("Parser.zig");
const IR = @import("IR.zig").IR;

fn getName(alloc: std.mem.Allocator, absPath: []const u8, extName: []const u8) []u8 {
    const fileName = std.mem.lastIndexOf(u8, absPath, "/").?;
    const ext = std.mem.lastIndexOf(u8, absPath, ".").?;
    const name = std.fmt.allocPrint(alloc, "{s}.{s}", .{ absPath[fileName + 1 .. ext], extName }) catch {
        std.debug.print("{s} Name is to large\n", .{message.Error});
        return "";
    };

    return name;
}

fn writeAll(c: []const u8, arg: Arguments, name: []u8) std.fs.File.WriteError!void {
    var file: ?std.fs.File = null;
    defer {
        if (file) |f| f.close();
    }

    var writer: std.fs.File.Writer = undefined;

    if (arg.stdout) {
        writer = std.io.getStdOut().writer();
    } else {
        file = std.fs.cwd().createFile(name, .{}) catch |err| {
            std.debug.print("{s} Could not open file ({s}) becuase {}\n", .{ message.Error, arg.path, err });
            return;
        };

        writer = file.?.writer();
    }

    try writer.writeAll(c);
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const arguments = getArguments(alloc) orelse {
        usage();
        return 1;
    };

    _ = arena.reset(std.heap.ArenaAllocator.ResetMode.retain_capacity);

    var lexer = lex(alloc, arguments) orelse {
        usage();
        return 1;
    };

    if (arguments.lex) {
        const lexContent = lexer.toString(alloc) catch {
            std.debug.print("{s} Out of memory", .{message.Error});
            return 1;
        };

        const name = getName(alloc, lexer.absPath, "lex");
        try writeAll(lexContent.items, arguments, name);

        return 0;
    }

    var parser = Parser.Parser.init(alloc, &lexer);
    const unexpected = parser.parse() catch {
        std.debug.print("{s} Out of memory", .{message.Error});
        return 1;
    };

    if (unexpected) |err| {
        err.display();
        return 1;
    }

    if (arguments.parse) {
        const cont = parser.toString(alloc) catch {
            std.debug.print("{s} Out of memory", .{message.Error});
            return 1;
        };

        const name = getName(alloc, lexer.absPath, "parse");
        try writeAll(cont.items, arguments, name);

        return 0;
    }

    var ir = IR.init(&parser.program, alloc);

    ir.toIR() catch {
        std.debug.print("{s} Out of memory", .{message.Error});
        return 1;
    };

    if (arguments.ir) {
        const cont = ir.toString(alloc) catch {
            std.debug.print("{s} Out of memory", .{message.Error});
            return 1;
        };

        const name = getName(alloc, lexer.absPath, "ir");
        try writeAll(cont.items, arguments, name);

        return 0;
    }

    const cont = codeGen(alloc, ir.ssa) catch {
        std.debug.print("{s} Out of memory", .{message.Error});
        return 1;
    };

    if (arguments.build and arguments.stdout) {
        const name = getName(alloc, lexer.absPath, "asm");
        try writeAll(cont.items, arguments, name);
    }

    const name = getName(alloc, lexer.absPath, "asm");
    try writeAll(cont.items, arguments, name);

    var fasm = std.process.Child.init(&[_][]const u8{ "fasm", name }, alloc);

    fasm.stdout_behavior = .Pipe;
    fasm.stderr_behavior = .Pipe;

    // Spawn the process and capture stdout and stderr
    try fasm.spawn();
    fasm.stdout_behavior = .Pipe;
    fasm.stderr_behavior = .Pipe;

    const stdoutOutput: []u8 = try fasm.stdout.?.reader().readAllAlloc(alloc, std.math.maxInt(u64));
    const stderrOutput: []u8 = try fasm.stderr.?.reader().readAllAlloc(alloc, std.math.maxInt(u64));

    const fasmStatus = try fasm.wait();

    switch (fasmStatus) {
        .Exited => |x| {
            if (x != 0) {
                std.debug.print("Assembler got error {x}\nstdout:\n{s}stderr:\n{s}", .{ x, stdoutOutput, stderrOutput });

                var rm = std.process.Child.init(&[_][]const u8{ "rm", name }, alloc);

                _ = try rm.spawnAndWait();

                return 1;
            }
        },
        .Signal, .Stopped => |x| {
            std.debug.print("Assembler got error {x}\nstdout:\n{s}stderr:\n{s}", .{ x, stdoutOutput, stderrOutput });

            var rm = std.process.Child.init(&[_][]const u8{ "rm", name }, alloc);

            _ = try rm.spawnAndWait();

            return 1;
        },
        .Unknown => unreachable,
    }

    var exec = std.process.Child.init(&[_][]const u8{ "chmod", "+x", name[0..std.mem.lastIndexOf(u8, name, ".").?] }, alloc);

    _ = try exec.spawnAndWait();

    var rm = std.process.Child.init(&[_][]const u8{ "rm", name }, alloc);

    _ = try rm.spawnAndWait();

    if (arguments.run) {
        var run = std.process.Child.init(&[_][]const u8{}, alloc);

        _ = try run.spawnAndWait();
    }

    return 0;
}
