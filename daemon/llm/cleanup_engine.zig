//! Pure, source-anchored transcript cleanup.  This module deliberately has no
//! provider or configuration dependencies.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_tokens = 2048;
pub const max_operations = 128;
pub const max_list_items = 128;

pub const Error = error{ OutOfMemory, InvalidPlan, TranscriptTooLarge };
pub const Token = struct { text: []const u8, start: usize, end: usize, protected: bool };
pub const DeleteKind = enum { filler, repetition, backtrack };
pub const ScalarCategory = enum { number, weekday, quantity };
pub const Deletion = struct {
    start_token: usize,
    end_token: usize,
    source: []const u8,
    kind: DeleteKind,
    // repetition: the retained, immediately preceding phrase. backtrack: cue
    // and surviving replacement. filler ignores these fields.
    proof_start_token: usize,
    proof_end_token: usize,
    cue: []const u8,
    category: ?ScalarCategory,
};
pub const CorrectionKind = enum { case, glossary, orthographic };
pub const Correction = struct { start_token: usize, end_token: usize, source: []const u8, replacement: []const u8, kind: CorrectionKind };
pub const PunctuationMark = enum { period, comma, question, exclamation, colon, semicolon };
pub const Punctuation = struct { after_token: usize, mark: PunctuationMark };
pub const ListKind = enum { bullet, numbered };
pub const ListAnchor = struct { start_token: usize };
pub const List = struct { start_token: usize, end_token: usize, items: []const ListAnchor, kind: ListKind };
pub const PolishedPlan = struct {
    version: u32,
    deletions: []const Deletion,
    corrections: []const Correction,
    punctuation: []const Punctuation,
    paragraph_breaks: []const usize,
    lists: []const List,
};

pub const PolishedBaseline = struct {
    text: []u8,
    sufficient: bool,
};

/// A provider-free, conservative Polished pass. Clean is deliberately run
/// first and every subsequent byte is produced by the normal validated plan
/// renderer, keeping this fallback subject to exactly the same safety rules as
/// provider plans.
pub fn polishedBaseline(gpa: Allocator, transcript: []const u8, glossary: []const []const u8) Error!PolishedBaseline {
    const cleaned = try clean(gpa, transcript, glossary);
    defer gpa.free(cleaned);
    const tokens = try tokenize(gpa, cleaned);
    defer gpa.free(tokens);
    if (tokens.len == 0) return .{ .text = try gpa.dupe(u8, cleaned), .sufficient = false };

    var corrections: std.ArrayList(Correction) = .empty;
    defer corrections.deinit(gpa);
    var punctuation_ops: std.ArrayList(Punctuation) = .empty;
    defer punctuation_ops.deinit(gpa);
    var anchors: std.ArrayList(ListAnchor) = .empty;
    defer anchors.deinit(gpa);
    var lists: std.ArrayList(List) = .empty;
    defer lists.deinit(gpa);
    var capitalization: ?[]u8 = null;
    defer if (capitalization) |replacement| gpa.free(replacement);

    var decorated = hasDecorationOnlyChunk(cleaned, tokens);
    for (tokens) |token| decorated = decorated or token.protected or technical(token.text) or hasLocalListMarker(cleaned, token);
    if (!decorated and safeOrdinary(cleaned, tokens[0]) and std.ascii.isLower(tokens[0].text[0])) {
        const replacement = try gpa.dupe(u8, tokens[0].text);
        capitalization = replacement;
        replacement[0] = std.ascii.toUpper(replacement[0]);
        try corrections.append(gpa, .{ .start_token = 0, .end_token = 1, .source = tokens[0].text, .replacement = replacement, .kind = .case });
    }

    var sufficient = false;
    var list_start: ?usize = null;
    if (!decorated and ordinalAnchors(gpa, tokens, &anchors)) {
        list_start = 0;
        sufficient = true;
    } else if (!decorated) {
        var i: usize = 0;
        while (i + 2 < tokens.len) : (i += 1) if (numberWord(tokens[i].text)) |count| {
            if (!countedListNoun(tokens[i + 1].text)) continue;
            const start = i + 2;
            const remaining = tokens.len - start;
            const has_and = remaining >= 3 and asciiEq(tokens[tokens.len - 2].text, "and");
            const item_count = remaining - @intFromBool(has_and);
            if (item_count != count) continue;
            var item: usize = start;
            while (item < tokens.len) : (item += 1) {
                if (has_and and item == tokens.len - 1) continue;
                try anchors.append(gpa, .{ .start_token = item });
            }
            list_start = start;
            try punctuation_ops.append(gpa, .{ .after_token = i + 1, .mark = .colon });
            sufficient = true;
            break;
        };
    }
    if (list_start) |start| try lists.append(gpa, .{ .start_token = start, .end_token = tokens.len, .items = anchors.items, .kind = .bullet });
    if (!decorated and try reportedOrdinalPunctuation(gpa, cleaned, tokens, &punctuation_ops)) sufficient = true;

    // Deepgram can preserve the capital at an inferred sentence boundary
    // without supplying punctuation. Recover only the narrow, unambiguous
    // pronoun boundary; proper names and acronyms remain untouched.
    if (!decorated) for (tokens[1..], 1..) |token, i| {
        if (!sentenceStarterPronoun(token.text) or hasFixedTrailingPunctuation(cleaned, tokens[i - 1])) continue;
        try punctuation_ops.append(gpa, .{ .after_token = i - 1, .mark = .period });
    };

    const question = directQuestion(tokens[0].text);
    if (question) sufficient = true;
    if (!decorated and !hasTerminalPunctuation(cleaned, tokens[tokens.len - 1]) and safeOrdinary(cleaned, tokens[tokens.len - 1])) {
        try punctuation_ops.append(gpa, .{ .after_token = tokens.len - 1, .mark = if (question) .question else .period });
    }
    std.mem.sort(Punctuation, punctuation_ops.items, {}, struct {
        fn lessThan(_: void, a: Punctuation, b: Punctuation) bool {
            return a.after_token < b.after_token;
        }
    }.lessThan);
    const text = try polished(gpa, cleaned, glossary, .{ .version = 2, .deletions = &.{}, .corrections = corrections.items, .punctuation = punctuation_ops.items, .paragraph_breaks = &.{}, .lists = lists.items });
    return .{ .text = text, .sufficient = sufficient };
}

fn safeOrdinary(source: []const u8, token: Token) bool {
    if (token.protected or token.text.len == 0 or !std.ascii.isAlphabetic(token.text[0]) or technical(token.text)) return false;
    for (token.text) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return !hasUnsafeDecoration(source, &.{token}, 0);
}

fn hasTerminalPunctuation(source: []const u8, token: Token) bool {
    for (source[token.end..tokenChunkEnd(source, token)]) |c| if (std.mem.indexOfScalar(u8, ".?!", c) != null) return true;
    return false;
}

fn directQuestion(word: []const u8) bool {
    for ([_][]const u8{ "can", "could", "would", "should", "will", "do", "does", "did", "is", "are", "was", "were", "have", "has", "had", "who", "what", "where", "when", "why", "how" }) |candidate| if (asciiEq(word, candidate)) return true;
    return false;
}

fn sentenceStarterPronoun(word: []const u8) bool {
    for ([_][]const u8{ "I", "It", "This", "That", "These", "Those", "We", "You", "He", "She", "They", "There" }) |candidate| if (std.mem.eql(u8, word, candidate)) return true;
    return false;
}

fn ordinal(word: []const u8) ?usize {
    for ([_][]const u8{ "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth" }, 1..) |candidate, value| if (asciiEq(word, candidate)) return value;
    return null;
}

fn ordinalAnchors(gpa: Allocator, tokens: []const Token, anchors: *std.ArrayList(ListAnchor)) bool {
    if (ordinal(tokens[0].text) != 1) return false;
    var expected: usize = 1;
    for (tokens, 0..) |token, i| if (ordinal(token.text)) |value| {
        if (value != expected) return false;
        anchors.append(gpa, .{ .start_token = i }) catch return false;
        expected += 1;
    };
    return expected >= 3;
}

fn reportedOrdinalPunctuation(gpa: Allocator, source: []const u8, tokens: []const Token, punctuation_ops: *std.ArrayList(Punctuation)) !bool {
    var indexes: [10]usize = undefined;
    var count: usize = 0;
    var expected: usize = 1;
    for (tokens, 0..) |token, i| if (ordinal(token.text)) |value| {
        if (value != expected) return false;
        indexes[count] = i;
        count += 1;
        expected += 1;
    };
    if (count < 3 or !reportingListContext(source, tokens, indexes[0])) return false;
    for (indexes[1..count]) |next| {
        const previous = next - 1;
        if (!hasFixedTrailingPunctuation(source, tokens[previous])) try punctuation_ops.append(gpa, .{ .after_token = previous, .mark = .comma });
    }
    return true;
}

fn numberWord(word: []const u8) ?usize {
    for ([_][]const u8{ "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten" }, 2..) |candidate, value| if (asciiEq(word, candidate)) return value;
    return null;
}

fn countedListNoun(word: []const u8) bool {
    for ([_][]const u8{ "items", "things", "fruits", "projects", "tasks", "points", "options", "steps", "reasons", "examples", "files", "changes", "questions", "ideas" }) |candidate| if (asciiEq(word, candidate)) return true;
    return false;
}

/// Deterministic conservative cleanup. The returned slice is allocator-owned.
pub fn clean(gpa: Allocator, transcript: []const u8, glossary: []const []const u8) Error![]u8 {
    const tokens = tokenize(gpa, transcript) catch |err| switch (err) {
        error.TranscriptTooLarge => return gpa.dupe(u8, transcript),
        else => return err,
    };
    defer gpa.free(tokens);
    if (tokens.len == 0) return gpa.dupe(u8, transcript);
    if (hasDecorationOnlyChunk(transcript, tokens)) return gpa.dupe(u8, transcript);
    var deleted = try gpa.alloc(bool, tokens.len);
    defer gpa.free(deleted);
    @memset(deleted, false);
    const protected = try protectionMap(gpa, transcript, tokens, glossary);
    defer gpa.free(protected);
    for (tokens, 0..) |t, i| {
        if (!protected[i] and filler(t.text)) deleted[i] = true;
    }
    // Exact adjacent phrase repetition. Never remove a one-word repetition.
    // Each run is compared to its retained first phrase so three or more
    // copies collapse fully rather than leaving the final copy behind.
    var n: usize = 8;
    while (n >= 2) : (n -= 1) {
        var base: usize = 0;
        while (base + n * 2 <= tokens.len) {
            var candidate = base + n;
            if (!cleanRangesEqual(transcript, tokens, deleted, protected, base, candidate, n)) {
                base += 1;
                continue;
            }
            while (candidate + n <= tokens.len and cleanRangesEqual(transcript, tokens, deleted, protected, base, candidate, n)) : (candidate += n) {
                for (candidate..candidate + n) |j| deleted[j] = true;
            }
            base = candidate;
        }
    }
    // "Actually" is accepted only between locally provable same-category
    // scalars; semantic discourse uses remain untouched.
    const cues = [_][]const []const u8{ &.{"actually"}, &.{"correction"}, &.{ "scratch", "that" }, &.{ "make", "that" } };
    for (cues) |cue| {
        var i: usize = 1;
        while (i + cue.len < tokens.len) : (i += 1) {
            const category = scalarCategory(tokens[i - 1].text);
            var match = !protected[i - 1] and category != null and !backtrackNegated(tokens, i - 1);
            for (cue, 0..) |word, j| match = match and !protected[i + j] and asciiEq(tokens[i + j].text, word);
            const replacement = i + cue.len;
            match = match and !protected[replacement] and sameScalar(tokens[i - 1].text, tokens[replacement].text, category);
            if (match) {
                for (i - 1..replacement) |j| deleted[j] = true;
            }
        }
    }
    var survivors: usize = 0;
    for (deleted) |is_deleted| survivors += @intFromBool(!is_deleted);
    if (survivors == 0) return gpa.dupe(u8, transcript);
    return renderClean(gpa, transcript, tokens, deleted);
}

/// Parse, validate and render v2. Malformed or unsafe plans are rejected so
/// the pipeline owner can apply raw fallback and record a transformation failure.
pub fn polishedFromJson(gpa: Allocator, transcript: []const u8, glossary: []const []const u8, json: []const u8) Error![]u8 {
    const parsed = std.json.parseFromSlice(PolishedPlan, gpa, json, .{ .ignore_unknown_fields = false }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPlan,
    };
    defer parsed.deinit();
    return polished(gpa, transcript, glossary, parsed.value);
}

pub fn polished(gpa: Allocator, transcript: []const u8, glossary: []const []const u8, plan: PolishedPlan) Error![]u8 {
    const tokens = try tokenize(gpa, transcript);
    defer gpa.free(tokens);
    if (tokens.len == 0 or tokens.len > max_tokens) return error.InvalidPlan;
    const operation_count = plan.deletions.len + plan.corrections.len + plan.punctuation.len + plan.paragraph_breaks.len + plan.lists.len;
    if (plan.version != 2 or plan.deletions.len != 0 or operation_count > max_operations or (operation_count > 0 and hasDecorationOnlyChunk(transcript, tokens))) return error.InvalidPlan;
    const protected = try protectionMap(gpa, transcript, tokens, glossary);
    defer gpa.free(protected);
    var deleted = try gpa.alloc(bool, tokens.len);
    defer gpa.free(deleted);
    @memset(deleted, false);
    var previous_end: usize = 0;
    for (plan.deletions) |d| {
        if (d.start_token >= d.end_token or d.end_token > tokens.len or d.start_token < previous_end or !sourceEq(tokens[d.start_token..d.end_token], d.source)) return error.InvalidPlan;
        for (d.start_token..d.end_token) |i| if (protected[i] or hasDecorationInside(transcript, tokens, i)) return error.InvalidPlan;
        switch (d.kind) {
            .filler => if (d.end_token != d.start_token + 1 or d.proof_start_token != d.start_token or d.proof_end_token != d.end_token or d.category != null or !asciiEq(d.cue, tokens[d.start_token].text) or !filler(tokens[d.start_token].text)) return error.InvalidPlan,
            .repetition => {
                const len = d.end_token - d.start_token;
                if (len < 2 or len > 8 or d.category != null or !asciiEq(d.cue, "adjacent") or d.proof_end_token != d.start_token or d.proof_end_token > tokens.len or d.proof_start_token > d.proof_end_token or d.proof_end_token - d.proof_start_token != len or !rangesEqual(tokens[d.proof_start_token..d.proof_end_token], tokens[d.start_token..d.end_token])) return error.InvalidPlan;
                for (d.proof_start_token..d.proof_end_token) |i| if (deleted[i]) return error.InvalidPlan;
            },
            .backtrack => {
                if (d.end_token <= d.start_token + 1 or d.proof_start_token != d.end_token or d.proof_end_token != d.proof_start_token + 1 or d.proof_end_token > tokens.len or d.category == null or scalarCategory(tokens[d.start_token].text) != d.category or !sameScalar(tokens[d.start_token].text, tokens[d.proof_start_token].text, d.category) or !validCue(tokens, d.start_token + 1, d.end_token, d.cue) or protected[d.proof_start_token] or backtrackNegated(tokens, d.start_token)) return error.InvalidPlan;
            },
        }
        for (d.start_token..d.end_token) |i| deleted[i] = true;
        previous_end = d.end_token;
    }
    for (plan.deletions) |d| switch (d.kind) {
        .filler => {},
        .repetition, .backtrack => for (d.proof_start_token..d.proof_end_token) |i| if (deleted[i]) return error.InvalidPlan,
    };
    var survivors: usize = 0;
    for (deleted) |x| survivors += @intFromBool(!x);
    if (survivors == 0) return error.InvalidPlan;
    // Corrections remain intentionally narrow. Rendering support is compiled
    // separately below; overlap with deletion is forbidden.
    previous_end = 0;
    for (plan.corrections) |c| {
        if (c.start_token >= c.end_token or c.end_token > tokens.len or c.start_token < previous_end or !sourceEq(tokens[c.start_token..c.end_token], c.source) or !validReplacement(c.replacement)) return error.InvalidPlan;
        for (c.start_token..c.end_token) |i| if (deleted[i] or tokens[i].protected or technical(tokens[i].text) or hasUnsafeDecoration(transcript, tokens, i) or (protected[i] and c.kind != .glossary) or (i + 1 < c.end_token and hasInternalDecoration(transcript, tokens[i], tokens[i + 1]))) return error.InvalidPlan;
        const ok = switch (c.kind) {
            .case => c.end_token == c.start_token + 1 and !allUppercaseAscii(tokens[c.start_token].text) and oneWord(c.replacement) and asciiEq(c.source, c.replacement),
            .glossary => c.end_token - c.start_token <= 4 and glossaryCorrection(c.source, c.replacement, glossary),
            .orthographic => c.end_token == c.start_token + 1 and oneWord(c.replacement) and orthographic(c.source, c.replacement),
        };
        if (!ok) return error.InvalidPlan;
        previous_end = c.end_token;
    }
    // Pairwise correction/deletion overlap was checked above. Every other anchor
    // must be sorted, in range, and point at a surviving source token.
    var last: ?usize = null;
    for (plan.punctuation) |p| {
        if (p.after_token >= tokens.len or deleted[p.after_token] or tokens[p.after_token].protected or hasUnsafeDecoration(transcript, tokens, p.after_token) or (technical(tokens[p.after_token].text) and hasFixedTrailingPunctuation(transcript, tokens[p.after_token])) or (last != null and p.after_token <= last.?)) return error.InvalidPlan;
        for (plan.corrections) |c| if (p.after_token >= c.start_token and p.after_token + 1 < c.end_token) return error.InvalidPlan;
        last = p.after_token;
    }
    if (!strictAnchors(plan.paragraph_breaks, tokens.len, deleted, protected)) return error.InvalidPlan;
    var list_end: usize = 0;
    var item_total: usize = 0;
    for (plan.lists) |list| {
        item_total += list.items.len;
        if (list.start_token >= list.end_token or list.end_token > tokens.len or list.start_token < list_end or list.items.len < 2 or item_total > max_list_items or list.items[0].start_token != list.start_token or !strictListItems(list.items, list.start_token, list.end_token, deleted, protected) or !validListEvidence(tokens, list) or protectedLayoutBoundary(list.start_token, deleted, protected) or reportingListContext(transcript, tokens, list.start_token) or (list.end_token < tokens.len and protectedLayoutBoundary(list.end_token, deleted, protected))) return error.InvalidPlan;
        for (list.items) |item| if (hasLocalListMarker(transcript, tokens[item.start_token])) return error.InvalidPlan;
        list_end = list.end_token;
    }
    for (plan.paragraph_breaks) |a| for (plan.corrections) |c| if (a > c.start_token and a < c.end_token) return error.InvalidPlan;
    for (plan.lists) |list| {
        for (list.items) |item| for (plan.corrections) |c| if (item.start_token > c.start_token and item.start_token < c.end_token) return error.InvalidPlan;
        for (plan.corrections) |c| if (list.end_token > c.start_token and list.end_token < c.end_token) return error.InvalidPlan;
    }

    // A provider may correctly identify a sentence boundary by capitalizing a
    // pronoun but omit its paired punctuation. Complete that narrow operation
    // locally so formatting quality does not depend on provider consistency.
    var punctuation_ops: std.ArrayList(Punctuation) = .empty;
    defer punctuation_ops.deinit(gpa);
    try punctuation_ops.appendSlice(gpa, plan.punctuation);
    for (plan.corrections) |c| {
        if (c.kind != .case or c.start_token == 0 or !sentenceStarterPronoun(c.replacement) or layoutAt(plan, c.start_token) != 0) continue;
        const previous = c.start_token - 1;
        if (deleted[previous] or protected[previous] or tokens[previous].protected or technical(tokens[previous].text) or hasUnsafeDecoration(transcript, tokens, previous) or hasFixedTrailingPunctuation(transcript, tokens[previous]) or punctuationAfter(plan.punctuation, previous)) continue;
        try punctuation_ops.append(gpa, .{ .after_token = previous, .mark = .period });
    }
    if (punctuation_ops.items.len + operation_count - plan.punctuation.len > max_operations) return error.InvalidPlan;
    std.mem.sort(Punctuation, punctuation_ops.items, {}, struct {
        fn lessThan(_: void, a: Punctuation, b: Punctuation) bool {
            return a.after_token < b.after_token;
        }
    }.lessThan);
    const normalized_plan = PolishedPlan{
        .version = plan.version,
        .deletions = plan.deletions,
        .corrections = plan.corrections,
        .punctuation = punctuation_ops.items,
        .paragraph_breaks = plan.paragraph_breaks,
        .lists = plan.lists,
    };
    return renderPolished(gpa, transcript, tokens, deleted, normalized_plan);
}

fn punctuationAfter(punctuation_ops: []const Punctuation, token: usize) bool {
    for (punctuation_ops) |operation| if (operation.after_token == token) return true;
    return false;
}

pub fn tokenize(gpa: Allocator, text: []const u8) Error![]Token {
    var out: std.ArrayList(Token) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    var quote: u8 = 0;
    var curly_quote: u8 = 0;
    while (i < text.len) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i == text.len) break;
        const raw_start = i;
        while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
        var s = raw_start;
        var e = i;
        var protected = quote != 0 or curly_quote != 0;
        var q = s;
        while (q < e) : (q += 1) {
            const c = text[q];
            if (c == '`' or c == '"' or (c == '\'' and !(q > 0 and q + 1 < text.len and std.ascii.isAlphanumeric(text[q - 1]) and std.ascii.isAlphanumeric(text[q + 1])))) {
                protected = true;
                quote = if (quote == c) 0 else if (quote == 0) c else quote;
            } else if (q + 2 < e and c == 0xe2 and text[q + 1] == 0x80 and text[q + 2] >= 0x98 and text[q + 2] <= 0x9d) {
                protected = true;
                curly_quote = switch (text[q + 2]) {
                    0x98 => 0x99,
                    0x9c => 0x9d,
                    0x99, 0x9d => 0,
                    else => curly_quote,
                };
                q += 2;
            }
        }
        while (s < e and edgeWidth(text[s..e], true) > 0) s += edgeWidth(text[s..e], true);
        while (e > s and edgeWidth(text[s..e], false) > 0) e -= edgeWidth(text[s..e], false);
        if (s < e) try out.append(gpa, .{ .text = text[s..e], .start = s, .end = e, .protected = protected });
        if (out.items.len > max_tokens) return error.TranscriptTooLarge;
    }
    return out.toOwnedSlice(gpa);
}

fn renderClean(gpa: Allocator, source: []const u8, tokens: []const Token, deleted: []const bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var first: usize = 0;
    while (deleted[first]) first += 1;
    const first_start = tokenChunkStart(source, tokens[first]);
    if (first == 0) try out.appendSlice(gpa, source[0..first_start]);
    try out.appendSlice(gpa, source[first_start..tokenChunkEnd(source, tokens[first])]);
    var previous = first;
    var i = first + 1;
    while (i < tokens.len) : (i += 1) {
        if (deleted[i]) continue;
        var crossed_deletion = false;
        for (previous + 1..i) |between| crossed_deletion = crossed_deletion or deleted[between];
        const gap = source[tokenChunkEnd(source, tokens[previous])..tokenChunkStart(source, tokens[i])];
        if (crossed_deletion) {
            var newlines: usize = 0;
            for (gap) |c| newlines += @intFromBool(c == '\n');
            try out.appendSlice(gpa, if (newlines >= 2) "\n\n" else if (newlines == 1) "\n" else " ");
        } else {
            try out.appendSlice(gpa, gap);
        }
        const start = tokenChunkStart(source, tokens[i]);
        try out.appendSlice(gpa, source[start..tokenChunkEnd(source, tokens[i])]);
        previous = i;
    }
    var deleted_after = false;
    for (previous + 1..tokens.len) |after| deleted_after = deleted_after or deleted[after];
    if (!deleted_after) try out.appendSlice(gpa, source[tokenChunkEnd(source, tokens[previous])..]);
    return out.toOwnedSlice(gpa);
}
fn renderPolished(gpa: Allocator, source: []const u8, tokens: []const Token, deleted: []const bool, plan: PolishedPlan) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var ci: usize = 0;
    var pi: usize = 0;
    var previous: ?usize = null;
    var i: usize = 0;
    while (i < tokens.len) {
        if (deleted[i]) {
            i += 1;
            continue;
        }

        const gap_start = if (previous) |token| tokenChunkEnd(source, tokens[token]) else 0;
        const gap_end = tokenChunkStart(source, tokens[i]);
        const search_start = if (previous) |token| token + 1 else 0;
        var first_deleted: ?usize = null;
        for (search_start..i) |between| if (deleted[between]) {
            first_deleted = between;
            break;
        };
        const breaks = layoutAt(plan, i);
        if (breaks > 0) {
            if (previous != null) try out.appendSlice(gpa, if (breaks == 2) "\n\n" else "\n");
        } else if (first_deleted) |deleted_token| {
            if (previous != null) try out.appendSlice(gpa, source[gap_start..tokenChunkStart(source, tokens[deleted_token])]);
        } else {
            try out.appendSlice(gpa, source[gap_start..gap_end]);
        }
        if (listItem(plan.lists, i)) |item| switch (item.kind) {
            .bullet => try out.appendSlice(gpa, "- "),
            .numbered => {
                var buffer: [24]u8 = undefined;
                const marker = std.fmt.bufPrint(&buffer, "{d}. ", .{item.number}) catch unreachable;
                try out.appendSlice(gpa, marker);
            },
        };
        var last = i;
        const leading_start = tokenChunkStart(source, tokens[i]);
        try out.appendSlice(gpa, source[leading_start..tokens[i].start]);
        if (ci < plan.corrections.len and plan.corrections[ci].start_token == i) {
            const c = plan.corrections[ci];
            try out.appendSlice(gpa, c.replacement);
            last = c.end_token - 1;
            i = c.end_token;
            ci += 1;
        } else {
            try out.appendSlice(gpa, tokens[i].text);
            i += 1;
        }
        var mark: ?PunctuationMark = null;
        if (pi < plan.punctuation.len and plan.punctuation[pi].after_token == last) {
            mark = plan.punctuation[pi].mark;
            pi += 1;
        }
        const end = tokenChunkEnd(source, tokens[last]);
        try appendPunctuation(&out, gpa, source[tokens[last].end..end], mark);
        previous = last;
    }
    if (ci != plan.corrections.len or pi != plan.punctuation.len) return error.InvalidPlan;
    if (previous) |token| {
        var deleted_after = false;
        for (token + 1..tokens.len) |after| deleted_after = deleted_after or deleted[after];
        if (!deleted_after) try out.appendSlice(gpa, source[tokenChunkEnd(source, tokens[token])..]);
    }
    return out.toOwnedSlice(gpa);
}
const ListItemInfo = struct { kind: ListKind, number: usize };
fn listItem(lists: []const List, token: usize) ?ListItemInfo {
    for (lists) |l| for (l.items, 0..) |item, i| if (item.start_token == token) return .{ .kind = l.kind, .number = i + 1 };
    return null;
}
fn layoutAt(plan: PolishedPlan, token: usize) u2 {
    for (plan.paragraph_breaks) |x| if (x == token) return 2;
    if (listItem(plan.lists, token) != null) return 1;
    for (plan.lists) |l| if (l.end_token == token) return 1;
    return 0;
}
fn appendPunctuation(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8, mark: ?PunctuationMark) !void {
    var put = false;
    for (s) |c| {
        if (mark != null and std.mem.indexOfScalar(u8, ".,?!:;", c) != null) {
            if (!put) try out.append(gpa, punctuation(mark.?));
            put = true;
        } else try out.append(gpa, c);
    }
    if (mark != null and !put) try out.append(gpa, punctuation(mark.?));
}
fn punctuation(m: PunctuationMark) u8 {
    return switch (m) {
        .period => '.',
        .comma => ',',
        .question => '?',
        .exclamation => '!',
        .colon => ':',
        .semicolon => ';',
    };
}
fn tokenChunkStart(source: []const u8, t: Token) usize {
    var s = t.start;
    while (s > 0 and !std.ascii.isWhitespace(source[s - 1])) s -= 1;
    return s;
}
fn tokenChunkEnd(source: []const u8, t: Token) usize {
    var e = t.end;
    while (e < source.len and !std.ascii.isWhitespace(source[e])) e += 1;
    return e;
}
fn hasDecorationInside(source: []const u8, tokens: []const Token, i: usize) bool {
    const s = tokenChunkStart(source, tokens[i]);
    const e = tokenChunkEnd(source, tokens[i]);
    for (source[s..tokens[i].start]) |c| if (!std.ascii.isWhitespace(c)) return true;
    for (source[tokens[i].end..e]) |c| if (!std.ascii.isWhitespace(c)) return true;
    return false;
}
fn hasUnsafeDecoration(source: []const u8, tokens: []const Token, i: usize) bool {
    const s = tokenChunkStart(source, tokens[i]);
    const e = tokenChunkEnd(source, tokens[i]);
    for (source[s..tokens[i].start]) |c| if (!std.ascii.isWhitespace(c) and std.mem.indexOfScalar(u8, ".,?!:;", c) == null) return true;
    for (source[tokens[i].end..e]) |c| if (!std.ascii.isWhitespace(c) and std.mem.indexOfScalar(u8, ".,?!:;", c) == null) return true;
    return false;
}
fn hasFixedTrailingPunctuation(source: []const u8, token: Token) bool {
    const end = tokenChunkEnd(source, token);
    for (source[token.end..end]) |c| if (std.mem.indexOfScalar(u8, ".,?!:;", c) != null) return true;
    return false;
}
fn hasDecorationOnlyChunk(source: []const u8, tokens: []const Token) bool {
    var token_index: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        while (i < source.len and std.ascii.isWhitespace(source[i])) i += 1;
        if (i == source.len) break;
        const start = i;
        while (i < source.len and !std.ascii.isWhitespace(source[i])) i += 1;
        while (token_index < tokens.len and tokens[token_index].end <= start) token_index += 1;
        if (token_index == tokens.len or tokens[token_index].start >= i) return true;
    }
    return false;
}
fn hasLocalListMarker(source: []const u8, token: Token) bool {
    const start = tokenChunkStart(source, token);
    const end = tokenChunkEnd(source, token);
    const chunk = source[start..end];
    if (std.mem.eql(u8, chunk, "-") or std.mem.eql(u8, chunk, "*")) return true;
    if (!scalarNumber(token.text)) return false;
    const suffix = source[token.end..end];
    return std.mem.eql(u8, suffix, ".") or std.mem.eql(u8, suffix, ")");
}
fn hasInternalDecoration(source: []const u8, a: Token, b: Token) bool {
    for (source[a.end..b.start]) |c| if (!std.ascii.isWhitespace(c)) return true;
    return false;
}
fn edgeWidth(s: []const u8, leading: bool) usize {
    const c = if (leading) s[0] else s[s.len - 1];
    if (std.mem.indexOfScalar(u8, ".,?!:;\"'()[]{}<>*`", c) != null) return 1;
    if (s.len >= 3) {
        const p = if (leading) 0 else s.len - 3;
        if (s[p] == 0xe2 and s[p + 1] == 0x80 and s[p + 2] >= 0x98 and s[p + 2] <= 0x9d) return 3;
    }
    return 0;
}
fn filler(s: []const u8) bool {
    if (allUppercaseAscii(s)) return false;
    return asciiEq(s, "um") or asciiEq(s, "uh") or asciiEq(s, "er") or asciiEq(s, "erm");
}
fn allUppercaseAscii(s: []const u8) bool {
    var letters: usize = 0;
    for (s) |c| {
        if (!std.ascii.isAlphabetic(c)) continue;
        letters += 1;
        if (!std.ascii.isUpper(c)) return false;
    }
    return letters > 0;
}
fn asciiEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}
fn scalarNumber(s: []const u8) bool {
    return validNumberCore(s);
}
fn scalarCategory(s: []const u8) ?ScalarCategory {
    if (weekday(s)) return .weekday;
    if (scalarNumber(s)) return .number;
    if (quantityParts(s) != null) return .quantity;
    return null;
}
fn weekday(s: []const u8) bool {
    for ([_][]const u8{ "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" }) |x| if (asciiEq(s, x)) return true;
    return false;
}
fn sameScalar(a: []const u8, b: []const u8, cat: ?ScalarCategory) bool {
    if (cat == null or scalarCategory(b) != cat) return false;
    return switch (cat.?) {
        .number, .weekday => true,
        .quantity => quantityShape(a, b),
    };
}
fn quantityShape(a: []const u8, b: []const u8) bool {
    const ap = quantityParts(a) orelse return false;
    const bp = quantityParts(b) orelse return false;
    return asciiEq(ap.prefix, bp.prefix) and asciiEq(ap.suffix, bp.suffix);
}
const QuantityParts = struct { prefix: []const u8, suffix: []const u8 };
fn quantityParts(s: []const u8) ?QuantityParts {
    const prefixes = [_][]const u8{ "$", "£", "€" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, s, prefix) and validNumberCore(s[prefix.len..])) return .{ .prefix = prefix, .suffix = "" };
    const suffixes = [_][]const u8{ "%", "g", "kg", "mg", "lb", "lbs", "oz", "mm", "cm", "m", "km", "ml", "l", "ms", "s", "h", "hz", "khz", "mb", "gb", "tb" };
    for (suffixes) |suffix| if (s.len > suffix.len and endsWithIgnoreCase(s, suffix) and validNumberCore(s[0 .. s.len - suffix.len])) return .{ .prefix = "", .suffix = s[s.len - suffix.len ..] };
    return null;
}
fn validNumberCore(s: []const u8) bool {
    if (s.len == 0) return false;
    const dot = std.mem.indexOfScalar(u8, s, '.');
    if (dot != null and std.mem.indexOfScalar(u8, s[dot.? + 1 ..], '.') != null) return false;
    const integer = if (dot) |at| s[0..at] else s;
    const fraction = if (dot) |at| s[at + 1 ..] else "";
    if (integer.len == 0 or (dot != null and fraction.len == 0)) return false;
    for (fraction) |c| if (!std.ascii.isDigit(c)) return false;
    if (std.mem.indexOfScalar(u8, integer, ',')) |first_comma| {
        if (first_comma == 0 or first_comma > 3) return false;
        for (integer[0..first_comma]) |c| if (!std.ascii.isDigit(c)) return false;
        var group = first_comma;
        while (group < integer.len) : (group += 4) {
            if (group + 4 > integer.len or integer[group] != ',') return false;
            for (integer[group + 1 .. group + 4]) |c| if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }
    for (integer) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and asciiEq(s[s.len - suffix.len ..], suffix);
}
fn cleanRangesEqual(source: []const u8, tokens: []const Token, deleted: []const bool, protected: []const bool, a: usize, b: usize, len: usize) bool {
    for (0..len) |j| {
        if (deleted[a + j] or deleted[b + j] or protected[a + j] or protected[b + j] or hasDecorationInside(source, tokens, a + j) or hasDecorationInside(source, tokens, b + j) or !asciiEq(tokens[a + j].text, tokens[b + j].text)) return false;
    }
    return true;
}
fn technical(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "://") != null or std.mem.indexOfScalar(u8, s, '@') != null or std.mem.indexOfScalar(u8, s, '/') != null or std.mem.indexOfScalar(u8, s, '\\') != null or std.mem.indexOfScalar(u8, s, '_') != null;
}
fn inGlossary(s: []const u8, g: []const []const u8) bool {
    for (g) |x| if (asciiEq(s, x)) return true;
    return false;
}
fn sourceEq(ts: []const Token, s: []const u8) bool {
    var p: usize = 0;
    for (ts, 0..) |t, i| {
        if (i > 0) {
            if (p >= s.len or s[p] != ' ') return false;
            p += 1;
        }
        if (p + t.text.len > s.len or !std.mem.eql(u8, s[p .. p + t.text.len], t.text)) return false;
        p += t.text.len;
    }
    return p == s.len;
}
fn rangesEqual(a: []const Token, b: []const Token) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!asciiEq(x.text, y.text)) return false;
    return true;
}
fn compactEq(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and (a[i] == ' ' or a[i] == '-' or a[i] == '_')) i += 1;
        while (j < b.len and (b[j] == ' ' or b[j] == '-' or b[j] == '_')) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}
fn validCue(t: []const Token, s: usize, e: usize, cue: []const u8) bool {
    if (s >= e or !sourceEq(t[s..e], cue)) return false;
    return asciiEq(cue, "actually") or asciiEq(cue, "correction") or asciiEq(cue, "scratch that") or asciiEq(cue, "make that");
}
fn backtrackNegated(tokens: []const Token, scalar: usize) bool {
    const start = scalar -| 4;
    for (tokens[start..scalar]) |token| if (isNegator(token.text)) return true;
    return false;
}
fn isNegator(text: []const u8) bool {
    for ([_][]const u8{ "no", "not", "never", "none", "without", "neither", "nor", "cannot" }) |word| if (asciiEq(text, word)) return true;
    if (text.len >= 3 and std.ascii.toLower(text[text.len - 3]) == 'n' and text[text.len - 2] == '\'' and std.ascii.toLower(text[text.len - 1]) == 't') return true;
    const curly_apostrophe = "’";
    return text.len >= curly_apostrophe.len + 2 and
        std.ascii.toLower(text[text.len - curly_apostrophe.len - 2]) == 'n' and
        std.mem.eql(u8, text[text.len - curly_apostrophe.len - 1 .. text.len - 1], curly_apostrophe) and
        std.ascii.toLower(text[text.len - 1]) == 't';
}
fn protectionMap(gpa: Allocator, source: []const u8, tokens: []const Token, glossary: []const []const u8) ![]bool {
    var p = try gpa.alloc(bool, tokens.len);
    @memset(p, false);
    for (tokens, 0..) |t, i| {
        // Fixed prose punctuation remains editable. Quotes, code marks,
        // brackets, emphasis, and other technical decorations do not.
        p[i] = t.protected or technical(t.text) or hasUnsafeDecoration(source, tokens, i);
    }
    for (glossary) |term| {
        var n: usize = 1;
        for (term) |c| n += @intFromBool(std.ascii.isWhitespace(c));
        if (n > 4) continue;
        var i: usize = 0;
        while (i + n <= tokens.len) : (i += 1) {
            if (sourceEqFold(tokens[i .. i + n], term)) for (i..i + n) |j| {
                p[j] = true;
            };
        }
    }
    return p;
}
fn sourceEqFold(ts: []const Token, s: []const u8) bool {
    var p: usize = 0;
    for (ts, 0..) |t, i| {
        if (i > 0) {
            while (p < s.len and std.ascii.isWhitespace(s[p])) p += 1;
        }
        if (p + t.text.len > s.len or !asciiEq(s[p .. p + t.text.len], t.text)) return false;
        p += t.text.len;
    }
    return p == s.len;
}
fn validReplacement(s: []const u8) bool {
    if (s.len == 0 or s.len > 256 or !std.unicode.utf8ValidateSlice(s) or std.ascii.isWhitespace(s[0]) or std.ascii.isWhitespace(s[s.len - 1])) return false;
    for (s) |c| if (std.ascii.isControl(c)) return false;
    return true;
}
fn oneWord(s: []const u8) bool {
    for (s) |c| if (std.ascii.isWhitespace(c)) return false;
    return true;
}
fn glossaryCorrection(a: []const u8, b: []const u8, g: []const []const u8) bool {
    var exact = false;
    for (g) |x| {
        if (std.mem.eql(u8, x, b)) exact = true;
    }
    return exact and compactEq(a, b);
}
fn orthographic(a: []const u8, b: []const u8) bool {
    const Pair = struct { source: []const u8, replacement: []const u8 };
    // Intentionally empty for the initial v2 contract. New pairs require an
    // explicit deterministic fixture; edit distance alone is never authority.
    const allowlist: []const Pair = &.{};
    for (allowlist) |pair| if (asciiEq(a, pair.source) and std.mem.eql(u8, b, pair.replacement)) return true;
    return false;
}
fn strictAnchors(v: []const usize, len: usize, deleted: []const bool, protected: []const bool) bool {
    var p: usize = 0;
    for (v) |x| {
        if (x == 0 or x >= len or x <= p or protectedLayoutBoundary(x, deleted, protected)) return false;
        p = x;
    }
    return true;
}
fn strictListItems(v: []const ListAnchor, start: usize, end: usize, deleted: []const bool, protected: []const bool) bool {
    var p: ?usize = null;
    for (v) |item| {
        const x = item.start_token;
        if (x < start or x >= end or protectedLayoutBoundary(x, deleted, protected) or (p != null and x <= p.?)) return false;
        p = x;
    }
    return true;
}

fn validListEvidence(tokens: []const Token, list: List) bool {
    var ordinal_expected: usize = 1;
    var ordinal_proof = true;
    for (list.items) |item| {
        if (ordinal(tokens[item.start_token].text) != ordinal_expected) {
            ordinal_proof = false;
            break;
        }
        ordinal_expected += 1;
    }
    if (ordinal_proof) return true;

    if (list.start_token < 2 or list.end_token != tokens.len) return false;
    const count = numberWord(tokens[list.start_token - 2].text) orelse return false;
    if (!countedListNoun(tokens[list.start_token - 1].text) or list.items.len != count) return false;
    const remaining = list.end_token - list.start_token;
    const has_and = remaining >= 3 and asciiEq(tokens[list.end_token - 2].text, "and");
    const item_count = remaining - @intFromBool(has_and);
    if (item_count != count) return false;
    for (list.items, 0..) |item, i| {
        const expected = if (has_and and i == count - 1) list.end_token - 2 else list.start_token + i;
        if (item.start_token != expected) return false;
    }
    return true;
}
fn protectedLayoutBoundary(token: usize, deleted: []const bool, protected: []const bool) bool {
    if (deleted[token] or protected[token]) return true;
    var previous = token;
    while (previous > 0) {
        previous -= 1;
        if (!deleted[previous]) return protected[previous];
    }
    return false;
}

fn reportingListContext(source: []const u8, tokens: []const Token, start: usize) bool {
    if (start == 0) return false;
    var i = start;
    while (i > 0) {
        i -= 1;
        if (hasFixedTrailingPunctuation(source, tokens[i])) break;
        for ([_][]const u8{ "say", "says", "said", "read", "reads", "quote", "quoted", "quotation" }) |word| if (asciiEq(tokens[i].text, word)) return true;
    }
    return false;
}

test "polished baseline conservative formatting and coverage" {
    const a = std.testing.allocator;
    const Case = struct { input: []const u8, expected: []const u8, sufficient: bool };
    const cases = [_]Case{
        .{ .input = "can we ship tomorrow", .expected = "Can we ship tomorrow?", .sufficient = true },
        .{ .input = "ordinary sentence", .expected = "Ordinary sentence.", .sufficient = false },
        .{ .input = "This fixture is synthetic It contains no user data", .expected = "This fixture is synthetic. It contains no user data.", .sufficient = false },
        .{ .input = "um ordinary sentence", .expected = "Ordinary sentence.", .sufficient = false },
        .{ .input = "first validate corpus second run scorer third inspect report", .expected = "- First validate corpus\n- second run scorer\n- third inspect report.", .sufficient = true },
        .{ .input = "bring three items apples bananas and pears", .expected = "Bring three items:\n- apples\n- bananas\n- and pears.", .sufficient = true },
        .{ .input = "can you bring me three fruits apple bananas and pears", .expected = "Can you bring me three fruits:\n- apple\n- bananas\n- and pears?", .sufficient = true },
        .{ .input = "can you work on these three projects education finance and upholding", .expected = "Can you work on these three projects:\n- education\n- finance\n- and upholding?", .sufficient = true },
        .{ .input = "can you bring me these four items apple banana and pears", .expected = "Can you bring me these four items apple banana and pears?", .sufficient = true },
        .{ .input = "bring four items apple banana orange and pears", .expected = "Bring four items:\n- apple\n- banana\n- orange\n- and pears.", .sufficient = true },
        .{ .input = "can you bring me these items apple bananas and pears", .expected = "Can you bring me these items apple bananas and pears?", .sufficient = true },
        .{ .input = "The button says first second third", .expected = "The button says first, second, third.", .sufficient = true },
        .{ .input = "The button says quotation mark start first second third quotation mark end", .expected = "The button says quotation mark start first, second, third quotation mark end.", .sufficient = true },
        .{ .input = "say \"hello world\"", .expected = "say \"hello world\"", .sufficient = false },
        .{ .input = "visit https://example.com", .expected = "visit https://example.com", .sufficient = false },
        .{ .input = "email me@example.com", .expected = "email me@example.com", .sufficient = false },
        .{ .input = "open /tmp/file", .expected = "open /tmp/file", .sufficient = false },
        .{ .input = "- existing list", .expected = "- existing list", .sufficient = false },
    };
    for (cases) |case| {
        const result = try polishedBaseline(a, case.input, &.{});
        defer a.free(result.text);
        try std.testing.expectEqualStrings(case.expected, result.text);
        try std.testing.expectEqual(case.sufficient, result.sufficient);
        const again = try polishedBaseline(a, result.text, &.{});
        defer a.free(again.text);
        try std.testing.expectEqualStrings(result.text, again.text);
    }
}

test "clean filler repetition scalar correction and protections" {
    const a = std.testing.allocator;
    const x = try clean(a, "um go to go to work", &.{});
    defer a.free(x);
    try std.testing.expectEqualStrings("go to work", x);
    const y = try clean(a, "set 10 scratch that 12", &.{});
    defer a.free(y);
    try std.testing.expectEqualStrings("set 12", y);
    const z = try clean(a, "say `um` and \"uh\" not 4", &.{});
    defer a.free(z);
    try std.testing.expectEqualStrings("say `um` and \"uh\" not 4", z);
}
test "single repeats and ambiguous actually survive" {
    const a = std.testing.allocator;
    const x = try clean(a, "no no I actually agree", &.{});
    defer a.free(x);
    try std.testing.expectEqualStrings("no no I actually agree", x);
}
test "invalid polished JSON surfaces InvalidPlan" {
    try std.testing.expectError(error.InvalidPlan, polishedFromJson(std.testing.allocator, "do not go", &.{}, "{}"));
}

fn expectClean(source: []const u8, expected: []const u8, glossary: []const []const u8) !void {
    const out = try clean(std.testing.allocator, source, glossary);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

fn expectInvalidPlan(source: []const u8, glossary: []const []const u8, plan: PolishedPlan) !void {
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, plan, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectError(error.InvalidPlan, polishedFromJson(std.testing.allocator, source, glossary, json));
}

test "clean removes only the four unambiguous fillers" {
    try expectClean("Um, hello uh there er now erm done", "hello there now done", &.{});
    try expectClean("UM UH ER ERM are uppercase technical acronyms", "UM UH ER ERM are uppercase technical acronyms", &.{});
    try expectClean("go to ER now", "go to ER now", &.{});
    try expectClean("well like so you know actually hello", "well like so you know actually hello", &.{});
    try expectClean("keep  these\n\nparagraphs", "keep  these\n\nparagraphs", &.{});
    try expectClean("hello\num\nworld", "hello\n\nworld", &.{});
}

test "clean protects quoted literal technical and glossary text" {
    try expectClean("say 'um' “uh” `er` and don't erm", "say 'um' “uh” `er` and don't", &.{});
    try expectClean("visit /tmp/um email um@example.com then um leave", "visit /tmp/um email um@example.com then leave", &.{});
    try expectClean("say all say all um", "say all say all", &.{"say all"});
}

test "clean repetition is exact adjacent and at least two tokens" {
    try expectClean("we should go now go now please", "we should go now please", &.{});
    try expectClean("go now go now go now please", "go now please", &.{});
    try expectClean("very very good", "very very good", &.{});
    try expectClean("go to, go to work", "go to, go to work", &.{});
}

test "clean accepts only locally provable scalar backtracks" {
    try expectClean("meet Tuesday actually Wednesday", "meet Wednesday", &.{});
    try expectClean("meet Tuesday, actually Wednesday", "meet Wednesday", &.{});
    try expectClean("set $10 make that $12", "set $12", &.{});
    try expectClean("use 10kg correction 12lb", "use 10kg correction 12lb", &.{});
    try expectClean("version 1.2.3 actually 1.2.4", "version 1.2.3 actually 1.2.4", &.{});
    try expectClean("build AB12 actually AB13", "build AB12 actually AB13", &.{});
    try expectClean("use 1..2 actually 1..3", "use 1..2 actually 1..3", &.{});
    try expectClean("it is actually useful and no no", "it is actually useful and no no", &.{});
    try expectClean("do not use 10 actually words", "do not use 10 actually words", &.{});
    try expectClean("do not set 10 actually 12", "do not set 10 actually 12", &.{});
    try expectClean("never Tuesday actually Wednesday", "never Tuesday actually Wednesday", &.{});
    try expectClean("It is not 10, actually 12", "It is not 10, actually 12", &.{});
    try expectClean("It ISN’T 10 actually 12", "It ISN’T 10 actually 12", &.{});
    try expectClean("without 10 actually 12", "without 10 actually 12", &.{});
    try expectClean("You cannot pay 10 actually 12", "You cannot pay 10 actually 12", &.{});
}

test "polished compiles corrections punctuation paragraphs and numbered lists" {
    const source = "hello world first tea second coffee end";
    const corrections = [_]Correction{.{ .start_token = 0, .end_token = 1, .source = "hello", .replacement = "Hello", .kind = .case }};
    const punctuation_marks = [_]Punctuation{.{ .after_token = 1, .mark = .period }};
    const paragraphs = [_]usize{2};
    const items = [_]ListAnchor{ .{ .start_token = 2 }, .{ .start_token = 4 } };
    const lists = [_]List{.{ .start_token = 2, .end_token = 6, .items = &items, .kind = .numbered }};
    const out = try polished(std.testing.allocator, source, &.{}, .{
        .version = 2,
        .deletions = &.{},
        .corrections = &corrections,
        .punctuation = &punctuation_marks,
        .paragraph_breaks = &paragraphs,
        .lists = &lists,
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Hello world.\n\n1. first tea\n2. second coffee\nend", out);
}

test "polished pairs a provider sentence capitalization with punctuation" {
    const source = "This fixture is synthetic it contains no user data";
    const corrections = [_]Correction{.{ .start_token = 4, .end_token = 5, .source = "it", .replacement = "It", .kind = .case }};
    const punctuation_marks = [_]Punctuation{.{ .after_token = 8, .mark = .period }};
    const out = try polished(std.testing.allocator, source, &.{}, .{
        .version = 2,
        .deletions = &.{},
        .corrections = &corrections,
        .punctuation = &punctuation_marks,
        .paragraph_breaks = &.{},
        .lists = &.{},
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("This fixture is synthetic. It contains no user data.", out);
}

test "polished rejects lists introduced as reported or quoted content" {
    const source = "The button says quotation marks start first second third quotation mark end";
    const items = [_]ListAnchor{ .{ .start_token = 6 }, .{ .start_token = 7 }, .{ .start_token = 8 } };
    const lists = [_]List{.{ .start_token = 6, .end_token = 9, .items = &items, .kind = .bullet }};
    try expectInvalidPlan(source, &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &lists });
}

test "polished rejects a conjunction as a counted list item" {
    const source = "Can you bring me these four items apple banana and pears";
    const items = [_]ListAnchor{ .{ .start_token = 7 }, .{ .start_token = 8 }, .{ .start_token = 9 }, .{ .start_token = 10 } };
    const lists = [_]List{.{ .start_token = 7, .end_token = 11, .items = &items, .kind = .bullet }};
    try expectInvalidPlan(source, &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &lists });
}

test "polished rejects provider deletion plans" {
    const deletion = [_]Deletion{.{ .start_token = 0, .end_token = 1, .source = "um", .kind = .filler, .proof_start_token = 0, .proof_end_token = 1, .cue = "um", .category = null }};
    const items = [_]ListAnchor{ .{ .start_token = 1 }, .{ .start_token = 3 } };
    const lists = [_]List{.{ .start_token = 1, .end_token = 5, .items = &items, .kind = .bullet }};
    try expectInvalidPlan("um first tea second coffee end", &.{}, .{
        .version = 2,
        .deletions = &deletion,
        .corrections = &.{},
        .punctuation = &.{},
        .paragraph_breaks = &.{},
        .lists = &lists,
    });
}

test "polished rejects cleanup deletions and validates glossary proofs" {
    const repetition = [_]Deletion{.{ .start_token = 2, .end_token = 4, .source = "go now", .kind = .repetition, .proof_start_token = 0, .proof_end_token = 2, .cue = "adjacent", .category = null }};
    try expectInvalidPlan("go now go now please", &.{}, .{ .version = 2, .deletions = &repetition, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });

    const backtrack = [_]Deletion{.{ .start_token = 1, .end_token = 3, .source = "Tuesday actually", .kind = .backtrack, .proof_start_token = 3, .proof_end_token = 4, .cue = "actually", .category = .weekday }};
    try expectInvalidPlan("meet Tuesday actually Wednesday", &.{}, .{ .version = 2, .deletions = &backtrack, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });

    const correction = [_]Correction{.{ .start_token = 0, .end_token = 1, .source = "sayall", .replacement = "SayAll", .kind = .glossary }};
    const corrected = try polished(std.testing.allocator, "sayall works", &.{"SayAll"}, .{ .version = 2, .deletions = &.{}, .corrections = &correction, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
    defer std.testing.allocator.free(corrected);
    try std.testing.expectEqualStrings("SayAll works", corrected);
}

test "polished empty plan preserves source slices and protected anchors reject" {
    const empty: PolishedPlan = .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} };
    const exact_source = "He\tsaid  \" hello \"\n\nnext";
    const exact = try polished(std.testing.allocator, exact_source, &.{}, empty);
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualStrings(exact_source, exact);
    const decoration_source = "keep ()\t exact";
    const decorated = try polished(std.testing.allocator, decoration_source, &.{}, empty);
    defer std.testing.allocator.free(decorated);
    try std.testing.expectEqualStrings(decoration_source, decorated);
    const case = [_]Correction{.{ .start_token = 0, .end_token = 1, .source = "hello", .replacement = "Hello", .kind = .case }};
    const period = [_]Punctuation{.{ .after_token = 1, .mark = .period }};
    const sliced = try polished(std.testing.allocator, "hello\tworld  tail\n", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &case, .punctuation = &period, .paragraph_breaks = &.{}, .lists = &.{} });
    defer std.testing.allocator.free(sliced);
    try std.testing.expectEqualStrings("Hello\tworld.  tail\n", sliced);
    try expectClean("He said \" hello \"", "He said \" hello \"", &.{});

    const quoted_punctuation = [_]Punctuation{.{ .after_token = 1, .mark = .question }};
    try expectInvalidPlan("\"do not.\"", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &quoted_punctuation, .paragraph_breaks = &.{}, .lists = &.{} });

    const items = [_]ListAnchor{ .{ .start_token = 0 }, .{ .start_token = 2 } };
    const numbered = [_]List{.{ .start_token = 0, .end_token = 4, .items = &items, .kind = .numbered }};
    try expectInvalidPlan("1. tea 2. coffee", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &numbered });

    const technical_punctuation = [_]Punctuation{.{ .after_token = 1, .mark = .period }};
    const technical_output = try polished(std.testing.allocator, "visit https://example.com now", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &technical_punctuation, .paragraph_breaks = &.{}, .lists = &.{} });
    defer std.testing.allocator.free(technical_output);
    try std.testing.expectEqualStrings("visit https://example.com. now", technical_output);
    const technical_comma = [_]Punctuation{.{ .after_token = 1, .mark = .comma }};
    const comma_output = try polished(std.testing.allocator, "visit https://example.com then continue", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &technical_comma, .paragraph_breaks = &.{}, .lists = &.{} });
    defer std.testing.allocator.free(comma_output);
    try std.testing.expectEqualStrings("visit https://example.com, then continue", comma_output);
    const terminal_technical_punctuation = [_]Punctuation{.{ .after_token = 1, .mark = .period }};
    const terminal_output = try polished(std.testing.allocator, "email user@example.com", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &terminal_technical_punctuation, .paragraph_breaks = &.{}, .lists = &.{} });
    defer std.testing.allocator.free(terminal_output);
    try std.testing.expectEqualStrings("email user@example.com.", terminal_output);
    try expectInvalidPlan("visit https://example.com/search?", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &terminal_technical_punctuation, .paragraph_breaks = &.{}, .lists = &.{} });
    try expectInvalidPlan("open /tmp/file;", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &terminal_technical_punctuation, .paragraph_breaks = &.{}, .lists = &.{} });
    const technical_paragraph = [_]usize{1};
    try expectInvalidPlan("visit user@example.com now", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &technical_paragraph, .lists = &.{} });
    const after_technical_paragraph = [_]usize{2};
    try expectInvalidPlan("visit https://example.com now", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &after_technical_paragraph, .lists = &.{} });
    const protected_items = [_]ListAnchor{ .{ .start_token = 0 }, .{ .start_token = 2 } };
    const protected_list = [_]List{.{ .start_token = 0, .end_token = 4, .items = &protected_items, .kind = .bullet }};
    try expectInvalidPlan("/tmp/file item second item", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &protected_list });
    const emphasized_punctuation = [_]Punctuation{.{ .after_token = 0, .mark = .exclamation }};
    try expectInvalidPlan("*important* note", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &emphasized_punctuation, .paragraph_breaks = &.{}, .lists = &.{} });
    const decoration_layout = [_]usize{1};
    try expectInvalidPlan("keep () exact", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &decoration_layout, .lists = &.{} });
    const after_glossary_paragraph = [_]usize{2};
    try expectInvalidPlan("Say All next", &.{"Say All"}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &after_glossary_paragraph, .lists = &.{} });
}

test "polished rejects overlaps changed proofs injection and all deletion" {
    const overlap = [_]Deletion{
        .{ .start_token = 0, .end_token = 1, .source = "um", .kind = .filler, .proof_start_token = 0, .proof_end_token = 1, .cue = "um", .category = null },
        .{ .start_token = 0, .end_token = 1, .source = "um", .kind = .filler, .proof_start_token = 0, .proof_end_token = 1, .cue = "um", .category = null },
    };
    try expectInvalidPlan("um stay", &.{}, .{ .version = 2, .deletions = &overlap, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });

    const injection = [_]Correction{.{ .start_token = 4, .end_token = 5, .source = "two", .replacement = "four", .kind = .orthographic }};
    try expectInvalidPlan("what is two plus two", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &injection, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });

    const negation_change = [_]Correction{.{ .start_token = 0, .end_token = 1, .source = "not", .replacement = "now", .kind = .orthographic }};
    try expectInvalidPlan("not ready", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &negation_change, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
    const homophone_change = [_]Correction{.{ .start_token = 0, .end_token = 1, .source = "two", .replacement = "too", .kind = .orthographic }};
    try expectInvalidPlan("two items", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &homophone_change, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });

    const all = [_]Deletion{.{ .start_token = 0, .end_token = 1, .source = "um", .kind = .filler, .proof_start_token = 0, .proof_end_token = 1, .cue = "um", .category = null }};
    try expectInvalidPlan("um", &.{}, .{ .version = 2, .deletions = &all, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });

    const nested = [_]Deletion{
        .{ .start_token = 0, .end_token = 2, .source = "10 actually", .kind = .backtrack, .proof_start_token = 2, .proof_end_token = 3, .cue = "actually", .category = .number },
        .{ .start_token = 2, .end_token = 4, .source = "12 actually", .kind = .backtrack, .proof_start_token = 4, .proof_end_token = 5, .cue = "actually", .category = .number },
    };
    try expectInvalidPlan("10 actually 12 actually 13", &.{}, .{ .version = 2, .deletions = &nested, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });

    const uppercase_filler = [_]Deletion{.{ .start_token = 0, .end_token = 1, .source = "ER", .kind = .filler, .proof_start_token = 0, .proof_end_token = 1, .cue = "ER", .category = null }};
    try expectInvalidPlan("ER diagram", &.{}, .{ .version = 2, .deletions = &uppercase_filler, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
    const exact_uppercase_filler = [_]Deletion{.{ .start_token = 2, .end_token = 3, .source = "ER", .kind = .filler, .proof_start_token = 2, .proof_end_token = 3, .cue = "ER", .category = null }};
    try expectInvalidPlan("go to ER now", &.{}, .{ .version = 2, .deletions = &exact_uppercase_filler, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
    const negated_backtrack = [_]Deletion{.{ .start_token = 2, .end_token = 4, .source = "10 actually", .kind = .backtrack, .proof_start_token = 4, .proof_end_token = 5, .cue = "actually", .category = .number }};
    try expectInvalidPlan("do not 10 actually 12", &.{}, .{ .version = 2, .deletions = &negated_backtrack, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
    const exact_negated_backtrack = [_]Deletion{.{ .start_token = 3, .end_token = 5, .source = "10 actually", .kind = .backtrack, .proof_start_token = 5, .proof_end_token = 6, .cue = "actually", .category = .number }};
    try expectInvalidPlan("It is not 10, actually 12", &.{}, .{ .version = 2, .deletions = &exact_negated_backtrack, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
    const uppercase_contraction_backtrack = [_]Deletion{.{ .start_token = 2, .end_token = 4, .source = "10 actually", .kind = .backtrack, .proof_start_token = 4, .proof_end_token = 5, .cue = "actually", .category = .number }};
    try expectInvalidPlan("It ISN’T 10 actually 12", &.{}, .{ .version = 2, .deletions = &uppercase_contraction_backtrack, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
    const without_backtrack = [_]Deletion{.{ .start_token = 1, .end_token = 3, .source = "10 actually", .kind = .backtrack, .proof_start_token = 3, .proof_end_token = 4, .cue = "actually", .category = .number }};
    try expectInvalidPlan("without 10 actually 12", &.{}, .{ .version = 2, .deletions = &without_backtrack, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
    const cannot_backtrack = [_]Deletion{.{ .start_token = 3, .end_token = 5, .source = "10 actually", .kind = .backtrack, .proof_start_token = 5, .proof_end_token = 6, .cue = "actually", .category = .number }};
    try expectInvalidPlan("You cannot pay 10 actually 12", &.{}, .{ .version = 2, .deletions = &cannot_backtrack, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
    const exact_orthographic_change = [_]Correction{.{ .start_token = 0, .end_token = 1, .source = "never", .replacement = "newer", .kind = .orthographic }};
    try expectInvalidPlan("never change this", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &exact_orthographic_change, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });

    for ([_]struct { source: []const u8, replacement: []const u8 }{
        .{ .source = "US", .replacement = "us" },
        .{ .source = "HTTP", .replacement = "http" },
        .{ .source = "ER", .replacement = "er" },
    }) |case| {
        const uppercase_case = [_]Correction{.{ .start_token = 2, .end_token = 3, .source = case.source, .replacement = case.replacement, .kind = .case }};
        const source = try std.fmt.allocPrint(std.testing.allocator, "Ship to {s}", .{case.source});
        defer std.testing.allocator.free(source);
        try expectInvalidPlan(source, &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &uppercase_case, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
    }
}

test "clean and polished bounds fail back raw" {
    var large: std.ArrayList(u8) = .empty;
    defer large.deinit(std.testing.allocator);
    for (0..max_tokens + 1) |i| {
        if (i > 0) try large.append(std.testing.allocator, ' ');
        try large.appendSlice(std.testing.allocator, "um");
    }
    try expectClean(large.items, large.items, &.{});

    var punctuation_marks: [max_operations + 1]Punctuation = undefined;
    for (&punctuation_marks) |*mark| mark.* = .{ .after_token = 0, .mark = .period };
    try expectInvalidPlan("keep this", &.{}, .{ .version = 2, .deletions = &.{}, .corrections = &.{}, .punctuation = &punctuation_marks, .paragraph_breaks = &.{}, .lists = &.{} });

    const overflow = [_]Deletion{.{ .start_token = 2, .end_token = 4, .source = "go now", .kind = .repetition, .proof_start_token = std.math.maxInt(usize), .proof_end_token = 2, .cue = "adjacent", .category = null }};
    try expectInvalidPlan("go now go now", &.{}, .{ .version = 2, .deletions = &overflow, .corrections = &.{}, .punctuation = &.{}, .paragraph_breaks = &.{}, .lists = &.{} });
}
