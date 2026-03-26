const std = @import("std");
const Allocator = std.mem.Allocator;

/// Metadata extracted from an FB2 file.
pub const Metadata = struct {
    title: ?[]const u8 = null,
    author_first: ?[]const u8 = null,
    author_middle: ?[]const u8 = null,
    author_last: ?[]const u8 = null,
    series_name: ?[]const u8 = null,
    series_number: ?[]const u8 = null,
    annotation: ?[]const u8 = null,
    cover_id: ?[]const u8 = null,
    cover_data: []const u8 = &.{},

    pub fn deinit(self: *const Metadata, allocator: Allocator) void {
        if (self.title) |v| allocator.free(v);
        if (self.author_first) |v| allocator.free(v);
        if (self.author_middle) |v| allocator.free(v);
        if (self.author_last) |v| allocator.free(v);
        if (self.series_name) |v| allocator.free(v);
        if (self.series_number) |v| allocator.free(v);
        if (self.annotation) |v| allocator.free(v);
        if (self.cover_id) |v| allocator.free(v);
        if (self.cover_data.len > 0) allocator.free(self.cover_data);
    }
};

// Tag names we care about (without namespace prefix).
const Tag = enum {
    title_info,
    author,
    first_name,
    middle_name,
    last_name,
    book_title,
    annotation,
    sequence,
    coverpage,
    image,
    binary,
    description,
    other,
};

fn classifyTag(name: []const u8) Tag {
    // Strip namespace prefix if present (e.g. "l:href" won't appear here, but just in case).
    const local = if (std.mem.indexOfScalar(u8, name, ':')) |i| name[i + 1 ..] else name;

    const map = .{
        .{ "title-info", Tag.title_info },
        .{ "author", Tag.author },
        .{ "first-name", Tag.first_name },
        .{ "middle-name", Tag.middle_name },
        .{ "last-name", Tag.last_name },
        .{ "book-title", Tag.book_title },
        .{ "annotation", Tag.annotation },
        .{ "sequence", Tag.sequence },
        .{ "coverpage", Tag.coverpage },
        .{ "image", Tag.image },
        .{ "binary", Tag.binary },
        .{ "description", Tag.description },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, local, entry[0])) return entry[1];
    }
    return .other;
}

const ParseState = enum {
    /// Scanning for <description>
    seeking_description,
    /// Inside <description> but outside fields we care about
    in_description,
    /// Inside <title-info>
    in_title_info,
    /// Inside <author> within <title-info>
    in_author,
    /// Capturing text content of a leaf element
    capturing,
    /// Inside <annotation>, collecting all text
    in_annotation,
    /// Description is done; optionally scanning for a <binary> matching cover
    seeking_binary,
    /// Inside the target <binary>, capturing base64
    in_binary,
    /// All done
    done,
};

/// Which leaf field we are currently capturing text for.
const CaptureTarget = enum {
    first_name,
    middle_name,
    last_name,
    book_title,
};

pub fn parse(allocator: Allocator, path: []const u8) !Metadata {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;
    if (file_size == 0) return Metadata{};

    const mapped = try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(mapped);

    return parseBytes(allocator, mapped);
}

pub fn parseBytes(allocator: Allocator, data: []const u8) !Metadata {
    var meta = Metadata{};
    errdefer meta.deinit(allocator);

    var state: ParseState = .seeking_description;
    var capture_target: CaptureTarget = .book_title;
    var text_buf: std.ArrayList(u8) = .{};
    defer text_buf.deinit(allocator);
    var annot_buf: std.ArrayList(u8) = .{};
    defer annot_buf.deinit(allocator);

    var pos: usize = 0;

    while (pos < data.len and state != .done) {
        switch (state) {
            .seeking_binary => {
                // Fast path: if no cover id, we're done.
                if (meta.cover_id == null) {
                    state = .done;
                    continue;
                }
                // Scan for <binary
                if (data[pos] == '<') {
                    const tag_end = std.mem.indexOfScalarPos(u8, data, pos + 1, '>') orelse break;
                    const tag_content = data[pos + 1 .. tag_end];
                    if (tag_content.len > 0 and tag_content[0] == '?') {
                        pos = tag_end + 1;
                        continue;
                    }
                    const tag_name = getTagName(tag_content);
                    if (classifyTag(tag_name) == .binary) {
                        // Check id attribute
                        if (getAttr(tag_content, "id")) |id| {
                            if (std.mem.eql(u8, id, meta.cover_id.?)) {
                                state = .in_binary;
                                text_buf.clearRetainingCapacity();
                                pos = tag_end + 1;
                                continue;
                            }
                        }
                    }
                    pos = tag_end + 1;
                } else {
                    pos += 1;
                }
            },
            .in_binary => {
                if (data[pos] == '<') {
                    // End of binary content
                    meta.cover_data = try allocator.dupe(u8, text_buf.items);
                    state = .done;
                } else {
                    // Skip whitespace in base64
                    if (data[pos] != '\n' and data[pos] != '\r' and data[pos] != ' ' and data[pos] != '\t') {
                        try text_buf.append(allocator, data[pos]);
                    }
                    pos += 1;
                }
            },
            .seeking_description => {
                if (data[pos] == '<') {
                    const tag_end = std.mem.indexOfScalarPos(u8, data, pos + 1, '>') orelse break;
                    const tag_content = data[pos + 1 .. tag_end];
                    const tag_name = getTagName(tag_content);
                    if (classifyTag(tag_name) == .description and !isClosingTag(tag_content)) {
                        state = .in_description;
                    }
                    pos = tag_end + 1;
                } else {
                    pos += 1;
                }
            },
            .in_description => {
                if (data[pos] == '<') {
                    const tag_end = std.mem.indexOfScalarPos(u8, data, pos + 1, '>') orelse break;
                    const tag_content = data[pos + 1 .. tag_end];
                    const tag_name = getTagName(tag_content);
                    const tag = classifyTag(tag_name);

                    if (tag == .description and isClosingTag(tag_content)) {
                        state = .seeking_binary;
                    } else if (tag == .title_info and !isClosingTag(tag_content)) {
                        state = .in_title_info;
                    }
                    pos = tag_end + 1;
                } else {
                    pos += 1;
                }
            },
            .in_title_info => {
                if (data[pos] == '<') {
                    const tag_end = std.mem.indexOfScalarPos(u8, data, pos + 1, '>') orelse break;
                    const tag_content = data[pos + 1 .. tag_end];
                    const tag_name = getTagName(tag_content);
                    const closing = isClosingTag(tag_content);
                    const tag = classifyTag(tag_name);

                    if (tag == .title_info and closing) {
                        state = .in_description;
                    } else if (!closing) {
                        switch (tag) {
                            .author => {
                                state = .in_author;
                            },
                            .book_title => {
                                capture_target = .book_title;
                                text_buf.clearRetainingCapacity();
                                state = .capturing;
                            },
                            .annotation => {
                                annot_buf.clearRetainingCapacity();
                                state = .in_annotation;
                            },
                            .sequence => {
                                if (meta.series_name == null) {
                                    if (getAttr(tag_content, "name")) |name| {
                                        meta.series_name = try allocator.dupe(u8, name);
                                    }
                                    if (getAttr(tag_content, "number")) |num| {
                                        meta.series_number = try allocator.dupe(u8, num);
                                    }
                                }
                            },
                            .image => {
                                // Extract cover image reference
                                if (meta.cover_id == null) {
                                    if (getHref(tag_content)) |href| {
                                        // href is like "#cover.jpg", strip the #
                                        const id = if (href.len > 0 and href[0] == '#') href[1..] else href;
                                        meta.cover_id = try allocator.dupe(u8, id);
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    pos = tag_end + 1;
                } else {
                    pos += 1;
                }
            },
            .in_author => {
                if (data[pos] == '<') {
                    const tag_end = std.mem.indexOfScalarPos(u8, data, pos + 1, '>') orelse break;
                    const tag_content = data[pos + 1 .. tag_end];
                    const tag_name = getTagName(tag_content);
                    const closing = isClosingTag(tag_content);
                    const tag = classifyTag(tag_name);

                    if (tag == .author and closing) {
                        state = .in_title_info;
                    } else if (!closing) {
                        switch (tag) {
                            .first_name => {
                                capture_target = .first_name;
                                text_buf.clearRetainingCapacity();
                                state = .capturing;
                            },
                            .middle_name => {
                                capture_target = .middle_name;
                                text_buf.clearRetainingCapacity();
                                state = .capturing;
                            },
                            .last_name => {
                                capture_target = .last_name;
                                text_buf.clearRetainingCapacity();
                                state = .capturing;
                            },
                            else => {},
                        }
                    }
                    pos = tag_end + 1;
                } else {
                    pos += 1;
                }
            },
            .capturing => {
                if (data[pos] == '<') {
                    // End of text — store result
                    const value = try allocator.dupe(u8, text_buf.items);
                    switch (capture_target) {
                        .book_title => {
                            if (meta.title) |old| allocator.free(old);
                            meta.title = value;
                        },
                        .first_name => {
                            if (meta.author_first) |old| allocator.free(old);
                            meta.author_first = value;
                        },
                        .middle_name => {
                            if (meta.author_middle) |old| allocator.free(old);
                            meta.author_middle = value;
                        },
                        .last_name => {
                            if (meta.author_last) |old| allocator.free(old);
                            meta.author_last = value;
                        },
                    }
                    // Skip the closing tag
                    const tag_end = std.mem.indexOfScalarPos(u8, data, pos + 1, '>') orelse break;
                    pos = tag_end + 1;
                    // Return to parent state
                    state = if (capture_target == .book_title) .in_title_info else .in_author;
                } else {
                    try text_buf.append(allocator, data[pos]);
                    pos += 1;
                }
            },
            .in_annotation => {
                if (data[pos] == '<') {
                    const tag_end = std.mem.indexOfScalarPos(u8, data, pos + 1, '>') orelse break;
                    const tag_content = data[pos + 1 .. tag_end];
                    const tag_name = getTagName(tag_content);

                    if (classifyTag(tag_name) == .annotation and isClosingTag(tag_content)) {
                        const trimmed = std.mem.trim(u8, annot_buf.items, " \n\r\t");
                        meta.annotation = try allocator.dupe(u8, trimmed);
                        state = .in_title_info;
                    } else {
                        // For <p> tags inside annotation, add a space separator
                        if (isClosingTag(tag_content) and std.mem.eql(u8, tag_name, "p")) {
                            if (annot_buf.items.len > 0) {
                                try annot_buf.append(allocator, ' ');
                            }
                        }
                    }
                    pos = tag_end + 1;
                } else {
                    // Collapse whitespace: skip leading ws, collapse runs to single space
                    const c = data[pos];
                    if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
                        if (annot_buf.items.len > 0 and annot_buf.items[annot_buf.items.len - 1] != ' ') {
                            try annot_buf.append(allocator, ' ');
                        }
                    } else {
                        try annot_buf.append(allocator, c);
                    }
                    pos += 1;
                }
            },
            .done => {},
        }
    }

    return meta;
}

fn getTagName(tag_content: []const u8) []const u8 {
    var start: usize = 0;
    // Skip / for closing tags
    if (tag_content.len > 0 and tag_content[0] == '/') start = 1;
    var end = start;
    while (end < tag_content.len) : (end += 1) {
        const c = tag_content[end];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '/' or c == '>') break;
    }
    return tag_content[start..end];
}

fn isClosingTag(tag_content: []const u8) bool {
    return tag_content.len > 0 and tag_content[0] == '/';
}

fn getAttr(tag_content: []const u8, name: []const u8) ?[]const u8 {
    // Simple attribute parser: find name="value" or name='value'
    var i: usize = 0;
    while (i < tag_content.len) {
        // Find attribute name
        if (i + name.len + 1 < tag_content.len) {
            if (std.mem.eql(u8, tag_content[i .. i + name.len], name) and tag_content[i + name.len] == '=') {
                var vi = i + name.len + 1;
                if (vi < tag_content.len and (tag_content[vi] == '"' or tag_content[vi] == '\'')) {
                    const quote = tag_content[vi];
                    vi += 1;
                    const val_start = vi;
                    while (vi < tag_content.len and tag_content[vi] != quote) : (vi += 1) {}
                    return tag_content[val_start..vi];
                }
            }
        }
        i += 1;
    }
    return null;
}

fn getHref(tag_content: []const u8) ?[]const u8 {
    // Look for href="..." (with optional namespace prefix like l:href or xlink:href)
    if (getAttr(tag_content, "href")) |v| return v;
    if (getAttr(tag_content, "l:href")) |v| return v;
    if (getAttr(tag_content, "xlink:href")) |v| return v;
    // Brute-force: find href= anywhere
    if (std.mem.indexOf(u8, tag_content, "href=")) |idx| {
        return getAttr(tag_content[idx..], "href");
    }
    return null;
}

test "parse sample fb2" {
    const sample =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
        \\  <description>
        \\    <title-info>
        \\      <author>
        \\        <first-name>Lewis</first-name>
        \\        <last-name>Carroll</last-name>
        \\      </author>
        \\      <book-title>Alice in Wonderland</book-title>
        \\      <annotation><p>A classic tale.</p></annotation>
        \\      <sequence name="Wonderland" number="1"/>
        \\      <coverpage><image l:href="#cover.jpg"/></coverpage>
        \\    </title-info>
        \\  </description>
        \\  <body><section><p>Text</p></section></body>
        \\  <binary id="cover.jpg" content-type="image/jpeg">AQID</binary>
        \\</FictionBook>
    ;

    const meta = try parseBytes(std.testing.allocator, sample);
    defer meta.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Alice in Wonderland", meta.title.?);
    try std.testing.expectEqualStrings("Lewis", meta.author_first.?);
    try std.testing.expectEqualStrings("Carroll", meta.author_last.?);
    try std.testing.expect(meta.author_middle == null);
    try std.testing.expectEqualStrings("Wonderland", meta.series_name.?);
    try std.testing.expectEqualStrings("1", meta.series_number.?);
    try std.testing.expectEqualStrings("A classic tale.", meta.annotation.?);
    try std.testing.expectEqualStrings("cover.jpg", meta.cover_id.?);
    try std.testing.expectEqualStrings("AQID", meta.cover_data);
}
