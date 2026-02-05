const std = @import("std");
const builtin = @import("builtin");
const nio = @import("nio");
const sys_linux = @import("sys-linux");

const os = builtin.target.os.tag;

const sys = switch (os) {
    .linux => sys_linux,
    else => @compileError("TODO"),
};

pub const Address = extern union {
    any: sys.struct_sockaddr,
    in: Ip4Address,
    in6: Ip6Address,

    pub fn initIp4(addr: [4]u8, hport: u16) Address {
        return .{ .in = Ip4Address.init(addr, hport) };
    }

    pub fn initIp6(addr: [8]u16, hport: u16) Address {
        return .{ .in6 = Ip6Address.init(addr, hport) };
    }

    pub fn size(adr: Address) sys.socklen_t {
        return switch (adr.any.family) {
            .INET => @sizeOf(sys.struct_sockaddr_in),
            .INET6 => @sizeOf(sys.struct_sockaddr_in6),
            sys.AF.UNIX => @sizeOf(sys.struct_sockaddr_un),
            else => unreachable,
        };
    }

    pub fn port(adr: Address) u16 {
        return std.mem.bigToNative(u16, switch (adr.any.family) {
            .INET => adr.in.sa.port,
            .INET6 => adr.in6.sa.port,
            else => unreachable,
        });
    }

    pub fn listen(adr: Address, options: ListenOptions) !Server {
        const sockfd = try sys.socket(
            adr.any.family,
            sys.SOCK.STREAM | sys.SOCK.CLOEXEC,
            if (adr.any.family == sys.AF.UNIX) 0 else sys.IPPROTO.TCP,
        );
        var s: Server = .{
            .address = undefined,
            .stream = .{ .socket = @enumFromInt(sockfd) },
        };
        errdefer s.stream.close();

        if (options.reuse_address) {
            try sys.setsockopt(sockfd, sys.SOL.SOCKET, sys.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

            if (adr.any.family != sys.AF.UNIX) {
                try sys.setsockopt(sockfd, sys.SOL.SOCKET, sys.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            }
        }

        var socklen = adr.size();
        try sys.bind(sockfd, &adr.any, socklen);
        try sys.listen(sockfd, options.kernel_backlog);
        try sys.getsockname(sockfd, &s.address.any, &socklen);
        return s;
    }

    pub const ListenOptions = struct {
        /// How many connections the kernel will accept on the application's behalf.
        /// If more than this many connections pool in the kernel, clients will start seeing "Connection refused".
        kernel_backlog: u31 = 511,
        /// Sets SO_REUSEADDR and SO_REUSEPORT.
        reuse_address: bool = false,
    };

    pub fn tcpConnect(adr: Address) !Stream {
        const fd = try sys.socket(adr.any.family, sys.SOCK.STREAM | sys.SOCK.CLOEXEC, sys.IPPROTO.TCP);
        const stream: Stream = .{ .socket = @enumFromInt(fd) };
        errdefer stream.close();
        try sys.connect(fd, &adr.any, adr.size());
        return stream;
    }
};

pub const Ip4Address = extern struct {
    sa: sys.struct_sockaddr_in,

    pub const SockAddr = sys.struct_sockaddr_in;

    pub fn init(addr: [4]u8, port: u16) Ip4Address {
        return Ip4Address{
            .sa = .{
                .port = std.mem.nativeToBig(u16, port),
                .addr = .{ .addr = @bitCast(addr) },
            },
        };
    }
};

pub const Ip6Address = extern struct {
    sa: sys.struct_sockaddr_in6,

    pub const SockAddr = sys.struct_sockaddr_in6;

    pub fn init(addr: [8]u16, port: u16) Ip6Address {
        return Ip6Address{
            .sa = .{
                .port = std.mem.nativeToBig(u16, port),
                .addr = .{ .addr = @bitCast(addr) },
                .flowinfo = 0,
                .scope_id = 0,
            },
        };
    }
};

pub const Socket = switch (os) {
    .linux => enum(c_uint) { _ },
    else => @compileError("TODO"),
};

pub const Stream = struct {
    socket: Socket,

    // Resource allocation may fail; resource deallocation must succeed.
    pub fn close(s: Stream) void {
        sys.close(@intCast(@intFromEnum(s.socket))) catch {};
    }

    pub const ReadError = switch (builtin.target.os.tag) {
        .linux => sys.errno.Error,
        else => @compileError("TODO"),
    };
    pub usingnamespace nio.Readable(@This(), ._bare);
    pub fn read(s: Stream, buffer: []u8) ReadError!usize {
        return sys.recv(@intFromEnum(s.socket), buffer, 0);
    }
    pub fn anyReadable(s: Stream) nio.AnyReadable {
        const S = struct {
            fn read(state: *allowzero anyopaque, buffer: []u8) anyerror!usize {
                const reified: Stream = .{ .socket = @enumFromInt(@intFromPtr(state)) };
                return reified.read(buffer);
            }
        };
        return .{
            .vtable = &.{ .read = S.read },
            .state = @ptrFromInt(@intFromEnum(s.socket)),
        };
    }

    pub const WriteError = switch (builtin.target.os.tag) {
        .linux => sys.errno.Error,
        else => @compileError("TODO"),
    };
    pub usingnamespace nio.Writable(@This(), ._bare);
    pub fn write(s: Stream, bytes: []const u8) WriteError!usize {
        return sys.send(@intFromEnum(s.socket), bytes, 0);
    }

    pub fn anyWritable(s: Stream) nio.AnyWritable {
        const S = struct {
            fn write(state: *allowzero anyopaque, buffer: []u8) anyerror!usize {
                const reified: Stream = .{ .socket = @enumFromInt(@intFromPtr(state)) };
                return reified.write(buffer);
            }
        };
        return .{
            .vtable = &.{ .write = S.write },
            .state = @ptrFromInt(@intFromEnum(s.socket)),
        };
    }
};

pub const Server = struct {
    address: Address,
    stream: Stream,

    pub fn close(s: *const Server) void {
        s.stream.close();
    }

    /// Blocks until a client connects to the server. The returned `Connection` has an open stream.
    pub fn accept(s: *const Server) !Connection {
        var accepted_addr: Address = undefined;
        var addr_len: sys.socklen_t = @sizeOf(Address);
        const fd = try sys.accept4(@intFromEnum(s.stream.socket), &accepted_addr.any, &addr_len, sys.SOCK.CLOEXEC);
        return .{
            .address = accepted_addr,
            .stream = .{ .socket = @enumFromInt(fd) },
        };
    }

    pub const Connection = struct {
        address: Address,
        stream: Stream,

        pub fn close(c: *const Connection) void {
            c.stream.close();
        }
    };
};

pub const getaddrinfo = sys.getaddrinfo;

pub const freeaddrinfo = sys.freeaddrinfo;
