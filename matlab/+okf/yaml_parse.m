function m = yaml_parse(txt)
%YAML_PARSE Minimal YAML-subset parser for OKF frontmatter.
%   M = OKF.YAML_PARSE(TXT) parses the frontmatter subset OKF uses into a
%   containers.Map (char keys; values are char, cell array, containers.Map,
%   or []).
%
%   Supported (everything kept VERBATIM as text -- no date/number/bool
%   coercion, the cross-binding parity rule):
%     key: scalar                 (unquoted; may contain ':' as in URIs)
%     key: "quoted" / 'quoted'
%     key: [a, b, "c"]            (flow sequence)
%     key: { k: v, k2: v2 }       (flow map -> containers.Map; OKF v0.2
%                                  `generated` / `usage_window`)
%     key:                        (null)
%       - item                    (block sequence of scalars)
%       - k: v                    (block sequence of one-level maps; OKF
%         k2: v2                   v0.2 `sources` / `verified`)
%     key:                        (one-level block map)
%       k: v
%     # full-line comments; " #" starts a trailing comment after an
%     unquoted scalar
%   Out-of-subset constructs (nesting deeper than one level, multi-line
%   scalars, anchors) raise an error -- the caller records the
%   spec-sanctioned yaml_parse_error finding.

lines = okf.internal.split_lines(txt);
m = containers.Map('KeyType', 'char', 'ValueType', 'any');
n = numel(lines);
i = 1;
while i <= n
    line = lines{i};
    stripped = strtrim(line);
    if isempty(stripped) || stripped(1) == '#'
        i = i + 1;
        continue;
    end
    if ~isempty(regexp(line, '^\s', 'once'))
        error('okf:yaml', 'unexpected indented line (out of subset): %s', line);
    end
    tok = regexp(line, '^([A-Za-z0-9_][A-Za-z0-9_.-]*):(.*)$', 'tokens', 'once');
    if isempty(tok)
        error('okf:yaml', 'not a key: value line (out of subset): %s', line);
    end
    key = tok{1};
    rest = strtrim(tok{2});
    if isempty(rest) || rest(1) == '#'
        % null value -- unless a block sequence or one-level block map follows
        [items, i2] = block_seq(lines, i + 1);
        if ~isempty(items)
            m(key) = items;
            i = i2;
            continue;
        end
        [bm, i3] = block_map(lines, i + 1);
        if ~isempty(bm)
            m(key) = bm;
            i = i3;
            continue;
        end
        m(key) = [];
        i = i + 1;
        continue;
    end
    m(key) = parse_value(rest, line);
    i = i + 1;
end
end

function v = parse_value(rest, line)
%PARSE_VALUE Inline value: flow seq, flow map, or verbatim scalar.
if rest(1) == '['
    v = flow_seq(rest, line);
elseif rest(1) == '{'
    v = flow_map(rest, line);
else
    v = scalar_value(rest);
end
end

function [items, next_i] = block_seq(lines, i)
%BLOCK_SEQ '- item' lines; items are scalars or one-level maps
%   ('- k: v' followed by deeper-indented 'k2: v2' continuation lines).
items = {};
next_i = i;
while next_i <= numel(lines)
    line = lines{next_i};
    s = strtrim(line);
    if isempty(s)
        next_i = next_i + 1;
        continue;
    end
    tok = regexp(line, '^(\s+)-\s+(.*)$', 'tokens', 'once');
    if isempty(tok)
        break;
    end
    dash_indent = numel(tok{1});
    item_text = strtrim(tok{2});
    % A sequence item that is itself a FLOW map -- '- { name: day, type: string }'.
    % This is the shape OKF SPEC 10.2 uses for `parameters:` and the one
    % upstream's own acme_retail bundle writes, so it is not an edge case.
    if ~isempty(item_text) && item_text(1) == '{'
        items{end + 1} = flow_map(item_text, line); %#ok<AGROW>
        next_i = next_i + 1;
        continue;
    end
    kv = regexp(item_text, '^([A-Za-z0-9_][A-Za-z0-9_.-]*):\s(.*)$|^([A-Za-z0-9_][A-Za-z0-9_.-]*):$', ...
                'tokens', 'once');
    if isempty(kv)
        items{end + 1} = scalar_value(item_text); %#ok<AGROW>
        next_i = next_i + 1;
        continue;
    end
    % map item: first entry from the dash line, then continuation lines
    % indented deeper than the dash
    im = containers.Map('KeyType', 'char', 'ValueType', 'any');
    [k1, v1] = split_entry(item_text, line);
    im(k1) = v1;
    next_i = next_i + 1;
    while next_i <= numel(lines)
        cline = lines{next_i};
        cs = strtrim(cline);
        if isempty(cs)
            next_i = next_i + 1;
            continue;
        end
        cind = regexp(cline, '^\s*', 'match', 'once');
        if numel(cind) <= dash_indent || ~isempty(regexp(cs, '^-', 'once'))
            break;
        end
        [ck, cv] = split_entry(cs, cline);
        im(ck) = cv;
        next_i = next_i + 1;
    end
    items{end + 1} = im; %#ok<AGROW>
end
end

function [bm, next_i] = block_map(lines, i)
%BLOCK_MAP One-level indented 'k: v' lines under a null-valued key.
bm = [];
next_i = i;
entries = containers.Map('KeyType', 'char', 'ValueType', 'any');
while next_i <= numel(lines)
    line = lines{next_i};
    s = strtrim(line);
    if isempty(s)
        next_i = next_i + 1;
        continue;
    end
    ind = regexp(line, '^\s*', 'match', 'once');
    if isempty(ind) || ~isempty(regexp(s, '^-', 'once'))
        break;
    end
    tok = regexp(s, '^([A-Za-z0-9_][A-Za-z0-9_.-]*):(.*)$', 'tokens', 'once');
    if isempty(tok)
        break;
    end
    rest = strtrim(tok{2});
    if isempty(rest)
        error('okf:yaml', 'nested block value deeper than one level (out of subset): %s', line);
    end
    entries(tok{1}) = parse_value(rest, line);
    next_i = next_i + 1;
end
if entries.Count > 0
    bm = entries;
else
    next_i = i;
end
end

function [k, v] = split_entry(s, line)
%SPLIT_ENTRY 'k: v' (or 'k:') text -> key + parsed inline value.
tok = regexp(s, '^([A-Za-z0-9_][A-Za-z0-9_.-]*):\s*(.*)$', 'tokens', 'once');
if isempty(tok)
    error('okf:yaml', 'expected key: value entry (out of subset): %s', line);
end
k = tok{1};
rest = strtrim(tok{2});
if isempty(rest)
    error('okf:yaml', 'nested block value deeper than one level (out of subset): %s', line);
end
v = parse_value(rest, line);
end

function items = flow_seq(rest, line)
close_br = find(rest == ']', 1, 'last');
if isempty(close_br)
    error('okf:yaml', 'unterminated flow sequence (out of subset): %s', line);
end
inner = strtrim(rest(2:close_br - 1));
items = {};
if isempty(inner)
    return;
end
parts = split_flow(inner);
for k = 1:numel(parts)
    items{end + 1} = scalar_value(strtrim(parts{k})); %#ok<AGROW>
end
end

function fm = flow_map(rest, line)
%FLOW_MAP '{ k: v, k2: v2 }' -> containers.Map (values: scalars/flow seqs).
close_br = find(rest == '}', 1, 'last');
if isempty(close_br)
    error('okf:yaml', 'unterminated flow map (out of subset): %s', line);
end
inner = strtrim(rest(2:close_br - 1));
fm = containers.Map('KeyType', 'char', 'ValueType', 'any');
if isempty(inner)
    return;
end
parts = split_flow(inner);
for k = 1:numel(parts)
    entry = strtrim(parts{k});
    tok = regexp(entry, '^([A-Za-z0-9_][A-Za-z0-9_.-]*):\s*(.*)$', 'tokens', 'once');
    if isempty(tok)
        error('okf:yaml', 'flow map entry is not key: value (out of subset): %s', line);
    end
    rest_v = strtrim(tok{2});
    if ~isempty(rest_v) && rest_v(1) == '{'
        error('okf:yaml', 'flow map nested deeper than one level (out of subset): %s', line);
    end
    if isempty(rest_v)
        fm(tok{1}) = [];
    elseif rest_v(1) == '['
        fm(tok{1}) = flow_seq(rest_v, line);
    else
        fm(tok{1}) = scalar_value(rest_v);
    end
end
end

function parts = split_flow(inner)
%SPLIT_FLOW Split on commas outside quotes, braces, and brackets.
q = '';
depth = 0;
start = 1;
parts = {};
for k = 1:numel(inner)
    c = inner(k);
    if ~isempty(q)
        if c == q
            q = '';
        end
    elseif c == '"' || c == ''''
        q = c;
    elseif c == '{' || c == '['
        depth = depth + 1;
    elseif c == '}' || c == ']'
        depth = depth - 1;
    elseif c == ',' && depth == 0
        parts{end + 1} = inner(start:k - 1); %#ok<AGROW>
        start = k + 1;
    end
end
parts{end + 1} = inner(start:end);
end

function v = scalar_value(s)
if numel(s) >= 2 && s(1) == '"' && s(end) == '"'
    v = strrep(s(2:end - 1), '\"', '"');
    return;
end
if numel(s) >= 2 && s(1) == '''' && s(end) == ''''
    v = strrep(s(2:end - 1), '''''', '''');
    return;
end
% unquoted: strip a trailing comment (" #" with preceding whitespace)
cut = regexp(s, '\s#', 'once');
if ~isempty(cut)
    s = strtrim(s(1:cut - 1));
end
if strcmp(s, '~') || strcmpi(s, 'null')
    v = [];
else
    v = s;  % verbatim -- timestamps/numbers/bools stay text
end
end
