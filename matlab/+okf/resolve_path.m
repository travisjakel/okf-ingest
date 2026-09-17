function [p, how] = resolve_path(raw, src_rel, targets)
%RESOLVE_PATH Resolve a path-valued frontmatter field (SPEC 6.2).
%   Applies the spec reading first (a leading '/' is bundle-relative, otherwise
%   relative to the concept's own directory); if that finds nothing, falls back
%   to the bundle root. The fallback exists because the reference bundles write
%   root-relative paths WITHOUT the leading slash -- all 12 frontmatter paths in
%   upstream's acme_retail resolve that way and none resolve the spec-literal
%   way -- and a consumer is required to be permissive (SPEC 11).
%   Returns p ('' when nothing resolves) and how ('spec' | 'root' | '').
hash_i = find(raw == '#', 1);
if ~isempty(hash_i)
    t = raw(1:hash_i - 1);
else
    t = raw;
end
if ~isempty(t) && t(1) == '/'
    spec = okf.internal.norm_path(t(2:end));
else
    slash = find(src_rel == '/', 1, 'last');
    if isempty(slash)
        spec = okf.internal.norm_path(t);
    else
        spec = okf.internal.norm_path([src_rel(1:slash) t]);
    end
end
if any(strcmp(spec, targets))
    p = spec;
    how = 'spec';
    return;
end
if ~isempty(t) && t(1) == '/'
    root = okf.internal.norm_path(t(2:end));
else
    root = okf.internal.norm_path(t);
end
if any(strcmp(root, targets))
    p = root;
    how = 'root';
    return;
end
p = '';
how = '';
end
