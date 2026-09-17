function out = links(b)
%LINKS The concept graph. Three edge sources, in this order: markdown links
%   (externals skipped), wikilinks, and the path-valued frontmatter fields of
%   SPEC 6.2. The last group carries the derivation and execution edges, which
%   appear nowhere in the body.
%   Rows: src_path, dst_raw, dst_path ('' unless it resolves to a concept),
%   resolved, kind (body|wikilink|resource|source|computation|executor|
%   attester), target (concept|file|scope|missing).
idx = wiki_index(b.concepts);
if isfield(b, 'files') && ~isempty(b.files)
    targets = b.files;
else
    targets = b.known;
end
out = struct('src_path', {}, 'dst_raw', {}, 'dst_path', {}, 'resolved', {}, ...
             'kind', {}, 'target', {});
for i = 1:numel(b.concepts)
    c = b.concepts(i);
    for j = 1:numel(c.links_raw)
        raw = c.links_raw{j};
        if is_external(raw)
            continue;
        end
        dst = resolve_link(raw, c.path, b.known);
        if ~isempty(dst)
            tgt = 'concept';
        else
            [rp, ~] = okf.resolve_path(raw, c.path, targets);
            if ~isempty(rp)
                tgt = 'file';
            else
                tgt = 'missing';
            end
        end
        out(end + 1) = struct('src_path', c.path, 'dst_raw', raw, ...
                              'dst_path', dst, 'resolved', ~isempty(dst), ...
                              'kind', 'body', 'target', tgt); %#ok<AGROW>
    end
    for j = 1:numel(c.wikilinks_raw)
        raw = c.wikilinks_raw{j};
        dst = resolve_wiki(raw, idx, b.known);
        if ~isempty(dst)
            tgt = 'concept';
        else
            tgt = 'missing';
        end
        out(end + 1) = struct('src_path', c.path, 'dst_raw', raw, ...
                              'dst_path', dst, 'resolved', ~isempty(dst), ...
                              'kind', 'wikilink', 'target', tgt); %#ok<AGROW>
    end
end
% Frontmatter edges are appended last, so body-link ordering is untouched.
for i = 1:numel(b.concepts)
    c = b.concepts(i);
    fps = okf.fm_paths(c.frontmatter);
    for j = 1:numel(fps)
        kind = fps{j}{1};
        raw = fps{j}{2};
        if is_external(raw)
            continue;
        end
        if strcmp(kind, 'source') && okf.is_scope(raw)
            out(end + 1) = struct('src_path', c.path, 'dst_raw', raw, ...
                                  'dst_path', '', 'resolved', false, ...
                                  'kind', kind, 'target', 'scope'); %#ok<AGROW>
            continue;
        end
        [rp, ~] = okf.resolve_path(raw, c.path, targets);
        if isempty(rp)
            out(end + 1) = struct('src_path', c.path, 'dst_raw', raw, ...
                                  'dst_path', '', 'resolved', false, ...
                                  'kind', kind, 'target', 'missing'); %#ok<AGROW>
            continue;
        end
        if any(strcmp(rp, b.known))
            out(end + 1) = struct('src_path', c.path, 'dst_raw', raw, ...
                                  'dst_path', rp, 'resolved', true, ...
                                  'kind', kind, 'target', 'concept'); %#ok<AGROW>
        else
            out(end + 1) = struct('src_path', c.path, 'dst_raw', raw, ...
                                  'dst_path', '', 'resolved', false, ...
                                  'kind', kind, 'target', 'file'); %#ok<AGROW>
        end
    end
end
end

function idx = wiki_index(concepts)
%WIKI_INDEX lowercased id/alias/title/stem -> path; ambiguous keys dropped.
kinds = {'id', 'alias', 'title', 'stem'};
idx = struct();
amb = struct();
for k = 1:4
    idx.(kinds{k}) = containers.Map('KeyType', 'char', 'ValueType', 'char');
    amb.(kinds{k}) = {};
end
    function add(kind, key, path)
        key = lower(strtrim(key));
        if isempty(key)
            return;
        end
        m = idx.(kind);
        if isKey(m, key) && ~strcmp(m(key), path)
            amb.(kind){end + 1} = key;
        end
        m(key) = path;  % containers.Map is a handle; mutation sticks
    end
for i = 1:numel(concepts)
    c = concepts(i);
    fm = c.frontmatter;
    if isa(fm, 'containers.Map')
        if isKey(fm, 'id') && ischar(fm('id'))
            add('id', fm('id'), c.path);
        end
        if isKey(fm, 'aliases') && iscell(fm('aliases'))
            al = fm('aliases');
            for j = 1:numel(al)
                if ischar(al{j})
                    add('alias', al{j}, c.path);
                end
            end
        end
    end
    if ~isempty(c.title)
        add('title', c.title, c.path);
    end
    slash = find(c.path == '/', 1, 'last');
    if isempty(slash)
        base = c.path;
    else
        base = c.path(slash + 1:end);
    end
    dot = find(base == '.', 1, 'last');
    if isempty(dot)
        stem = base;
    else
        stem = base(1:dot - 1);
    end
    add('stem', stem, c.path);
end
for k = 1:4
    m = idx.(kinds{k});
    dropped = amb.(kinds{k});
    for j = 1:numel(dropped)
        if isKey(m, dropped{j})
            remove(m, dropped{j});
        end
    end
end
end

function dst = resolve_wiki(raw, idx, known)
hash_i = find(raw == '#', 1);
if ~isempty(hash_i)
    raw = raw(1:hash_i - 1);
end
ref = strtrim(raw);
dst = '';
if isempty(ref)
    return;
end
if any(strcmp(ref, known))
    dst = ref;
    return;
end
if numel(ref) >= 3 && strcmp(ref(end - 2:end), '.md')
    cand = ref;
else
    cand = [ref '.md'];
end
if any(strcmp(cand, known))
    dst = cand;
    return;
end
lref = lower(ref);
kinds = {'id', 'alias', 'title', 'stem'};
for k = 1:4
    m = idx.(kinds{k});
    if isKey(m, lref)
        dst = m(lref);
        return;
    end
end
end

function dst = resolve_link(raw, src_rel, known)
hash_i = find(raw == '#', 1);
if ~isempty(hash_i)
    t = raw(1:hash_i - 1);
else
    t = raw;
end
if ~isempty(t) && t(1) == '/'
    cand = t(2:end);
else
    slash = find(src_rel == '/', 1, 'last');
    if isempty(slash)
        cand = t;
    else
        cand = [src_rel(1:slash) t];
    end
end
cand = okf.internal.norm_path(cand);
if any(strcmp(cand, known))
    dst = cand;
else
    dst = '';
end
end


function tf = is_external(raw)
hash_i = find(raw == '#', 1);
if ~isempty(hash_i)
    raw = raw(1:hash_i - 1);
end
tf = ~isempty(regexp(raw, '^[a-zA-Z][a-zA-Z0-9+.-]*:', 'once'));
end
