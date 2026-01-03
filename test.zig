const std = @import("std");
const net = @import("net");
const expect = @import("expect").expect;

test "echo server" {
    const server = try net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{});
    defer server.close();
    var t = try std.Thread.spawn(.{}, threadEcho, .{server.address});
    defer t.join();
    const conn = try server.accept();
    defer conn.close();
    const allocator = std.testing.allocator;
    const recvd = try conn.stream.readAllAlloc(allocator, 1024);
    defer allocator.free(recvd);
    try expect(recvd).toEqualString("hello world!\n");
}
fn threadEcho(adr: net.Address) !void {
    const conn = try adr.tcpConnect();
    defer conn.close();
    try conn.writeAll("hello world!\n");
}
