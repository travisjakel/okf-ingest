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
