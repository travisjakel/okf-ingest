function b = read_bundle(root, source_kind)
%READ_BUNDLE Read an OKF bundle directory -- mirrors py read_bundle.
%   Hidden directories skipped; only *.md files not starting with '.';
%   concepts sorted by bundle-relative forward-slash path (byte order).
if nargin < 2
    source_kind = 'dir';
end
old = cd(root);
root_abs = pwd;
cd(old);
root_str = strrep(root_abs, '\', '/');

[files, all_paths] = walk_md(root_abs, {}, {});
rels = cell(1, numel(files));
for i = 1:numel(files)
    rel = files{i}(numel(root_abs) + 2:end);
    rels{i} = strrep(rel, '\', '/');
end
[rels, order] = sort(rels);
files = files(order);

% `.okfignore` drops files from the CONCEPT set only; they stay in b.files, so
% a reference to one still resolves -- as a non-concept file. See ignore_rules
% below, and r/okf/R/okf.R for the rationale and the full grammar.
irules = ignore_rules(root_abs);
ignored = {};
if ~isempty(irules)
    keep = false(1, numel(rels));
    for i = 1:numel(rels)
        if is_ignored(rels{i}, irules)
            ignored{end + 1} = rels{i}; %#ok<AGROW>
        else
            keep(i) = true;
        end
    end
    rels = rels(keep);
    files = files(keep);
end

reserved_names = {'index.md', 'log.md'};
concepts = struct('path', {}, 'reserved', {}, 'type', {}, 'title', {}, ...
                  'description', {}, 'resource', {}, 'tags', {}, 'timestamp', {}, ...
                  'body', {}, 'frontmatter', {}, 'parse_error', {}, ...
                  'links_raw', {}, 'wikilinks_raw', {}, 'content_hash', {});
for i = 1:numel(files)
    fid = fopen(files{i}, 'rb');
    bytes = fread(fid, Inf, '*uint8')';
    fclose(fid);
    txt = native2unicode(bytes, 'UTF-8');
    p = okf.parse_text(txt);

    c = struct();
    c.path = rels{i};
    slash = find(rels{i} == '/', 1, 'last');
    if isempty(slash)
        base = rels{i};
    else
        base = rels{i}(slash + 1:end);
    end
    c.reserved = any(strcmp(base, reserved_names));
    c.type = meta_scalar(p.meta, 'type');
    c.title = meta_scalar(p.meta, 'title');
    c.description = meta_scalar(p.meta, 'description');
    c.resource = meta_scalar(p.meta, 'resource');
    c.tags = meta_get(p.meta, 'tags');       % char, cellstr, or []
    c.timestamp = meta_scalar(p.meta, 'timestamp');
    % OKF v0.2: fall back to generated: {by, at} when the legacy
    % timestamp is absent (spec section 13).
    if isempty(c.timestamp)
        g = meta_get(p.meta, 'generated');
        if isa(g, 'containers.Map') && isKey(g, 'at') && ischar(g('at'))
            c.timestamp = g('at');
        end
    end
    c.body = p.body;
    c.frontmatter = p.meta;                  % Map or []
    c.parse_error = p.err;                   % '' when clean
    c.links_raw = okf.extract_links(p.body);
    c.wikilinks_raw = okf.extract_wikilinks(p.body);
    c.content_hash = okf.content_hash(p.body);
    concepts(end + 1) = c; %#ok<AGROW>
end

b = struct();
b.bundle_id = okf.content_hash(root_str);
b.root = root_str;
b.source_kind = source_kind;
b.concepts = concepts;
b.known = rels;
% Every file in the tree, not only concepts: SPEC 6.2 path-valued fields and
% SPEC 6.3 references/ point at non-markdown artifacts (an attester .py, a
% computation .sql). Those are real targets, not broken links.
b.files = cell(1, numel(all_paths));
for i = 1:numel(all_paths)
    rel = all_paths{i}(numel(root_abs) + 2:end);
    b.files{i} = strrep(rel, '\', '/');
end
% Bundle-relative .md paths excluded by .okfignore. Reported so an over-broad
% pattern cannot quietly shrink a bundle: an ignored file produces no findings
% at all, which is indistinguishable from a clean one unless something counts it.
b.ignored = ignored;
b.okf_version = '';
for i = 1:numel(concepts)
    if strcmp(concepts(i).path, 'index.md')
        v = meta_scalar(concepts(i).frontmatter, 'okf_version');
        if ~isempty(v)
            b.okf_version = v;
        end
        break;
    end
end
end

function [files, all_files] = walk_md(d, files, all_files)
entries = dir(d);
% deterministic order not required here (concepts re-sorted by rel path)
for i = 1:numel(entries)
    name = entries(i).name;
    if strcmp(name, '.') || strcmp(name, '..')
        continue;
    end
    full = fullfile(d, name);
    if entries(i).isdir
        if name(1) ~= '.'
            [files, all_files] = walk_md(full, files, all_files);
        end
    elseif name(1) ~= '.'
        all_files{end + 1} = full; %#ok<AGROW>
        if numel(name) > 3 && strcmp(name(end - 2:end), '.md')
            files{end + 1} = full; %#ok<AGROW>
        end
    end
end
end

function rules = ignore_rules(root)
%IGNORE_RULES Parse a bundle's .okfignore into match rules.
%   Empty when the file is absent, which is what makes this a pure addition:
%   a bundle without one reads exactly as it did before.
rules = struct('rx', {}, 'neg', {}, 'dir_only', {}, 'anchored', {});
f = fullfile(root, '.okfignore');
if exist(f, 'file') ~= 2
    return;
end
fid = fopen(f, 'rb');
bytes = fread(fid, Inf, '*uint8')';
fclose(fid);
txt = native2unicode(bytes, 'UTF-8');
txt = strrep(txt, char(13), '');
lines = strsplit(txt, char(10));
for i = 1:numel(lines)
    p = strtrim(lines{i});
    if isempty(p) || p(1) == '#'
        continue;
    end
    neg = p(1) == '!';
    if neg
        p = strtrim(p(2:end));
    end
    if isempty(p)
        continue;
    end
    dir_only = p(end) == '/';
    if dir_only
        p = p(1:end - 1);
    end
    if isempty(p)
        continue;
    end
    r = struct('rx', glob_rx(p), 'neg', neg, 'dir_only', dir_only, ...
               'anchored', any(p == '/'));
    rules(end + 1) = r; %#ok<AGROW>
end
end

function rx = glob_rx(g)
%GLOB_RX Translate one .okfignore pattern into a fully anchored regex.
%   A deliberately small, completely specified subset of gitignore: five
%   independent implementations have to agree on it exactly, and gitignore's
%   per-directory cascade and its negation corners are where independent
%   implementations drift. One .okfignore, at the bundle root, no cascade.
%
%   Characters in META are escaped to stay literal in every binding's regex
%   engine; everything else -- '/', '-', '_', alphanumerics, any non-ASCII --
%   passes through UNESCAPED, because Rust's regex crate rejects an
%   unrecognized escape where PCRE and std::regex accept it.
META = ['.' char(92) '+*?()[]{}^$|'];
parts = {};
i = 1;
n = numel(g);
while i <= n
    ch = g(i);
    if ch == '*' && i < n && g(i + 1) == '*'
        % `/**/` matches a single `/` as well as any run of directories, so
        % `a/**/b` matches `a/b`. Without this the pattern everyone writes
        % first silently matches nothing at the one depth they meant.
        if i > 1 && g(i - 1) == '/' && i + 2 <= n && g(i + 2) == '/'
            parts{end} = '(?:/.*)?/';
            i = i + 3;
        else
            parts{end + 1} = '.*'; %#ok<AGROW>
            i = i + 2;
        end
    elseif ch == '*'
        parts{end + 1} = '[^/]*'; %#ok<AGROW>
        i = i + 1;
    elseif ch == '?'
        parts{end + 1} = '[^/]'; %#ok<AGROW>
        i = i + 1;
    else
        if any(META == ch)
            parts{end + 1} = [char(92) ch]; %#ok<AGROW>
        else
            parts{end + 1} = ch; %#ok<AGROW>
        end
        i = i + 1;
    end
end
rx = ['^' strjoin(parts, '') '$'];
end

function tf = is_ignored(path, rules)
%IS_IGNORED True when `path` (bundle-relative, forward slashes) is ignored.
%   The LAST matching rule decides, so a `!` line can re-include a file an
%   earlier pattern swept up.
tf = false;
if isempty(rules)
    return;
end
slash = find(path == '/', 1, 'last');
if isempty(slash)
    base = path;
else
    base = path(slash + 1:end);
end
% SPEC 3.1 reserves these two. A bundle that could ignore its own index would
% lose its okf_version and its directory listing, so they are never ignorable:
% an ignore file cannot un-structure the bundle.
if any(strcmp(base, {'index.md', 'log.md'}))
    return;
end
comps = strsplit(path, '/');
dirs = comps(1:end - 1);
pref = cell(1, numel(dirs));
for k = 1:numel(dirs)
    pref{k} = strjoin(dirs(1:k), '/');
end
for i = 1:numel(rules)
    r = rules(i);
    hit = false;
    if r.dir_only
        if r.anchored
            subj = pref;
        else
            subj = dirs;
        end
        for k = 1:numel(subj)
            if ~isempty(regexp(subj{k}, r.rx, 'once'))
                hit = true;
                break;
            end
        end
    else
        if r.anchored
            s = path;
        else
            s = base;
        end
        hit = ~isempty(regexp(s, r.rx, 'once'));
    end
    if hit
        tf = ~r.neg;
    end
end
end

function v = meta_get(meta, key)
v = [];
if isa(meta, 'containers.Map') && isKey(meta, key)
    v = meta(key);
end
end

function s = meta_scalar(meta, key)
%META_SCALAR The _s() of the Python binding: '' for missing/sequence/null.
v = meta_get(meta, key);
if ischar(v)
    s = v;
else
    s = '';
end
end
