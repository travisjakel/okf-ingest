function out = validate(b)
%VALIDATE OKF validation rules -- mirrors py validate() verbatim.
%   Permissive: recommended-field issues warn; only unparseable frontmatter
%   or a missing type are errors.
out = struct('path', {}, 'severity', {}, 'rule', {}, 'message', {});
    function add(path, sev, rule, msg)
        out(end + 1) = struct('path', path, 'severity', sev, ...
                              'rule', rule, 'message', msg);
    end
for i = 1:numel(b.concepts)
    c = b.concepts(i);
    if c.reserved
        continue;
    end
    if ~isempty(c.parse_error)
        add(c.path, 'error', 'frontmatter_unparseable', ...
            sprintf('no parseable frontmatter (%s)', c.parse_error));
        continue;
    end
    if isempty(c.type)
        add(c.path, 'error', 'missing_type', 'frontmatter has no non-empty type');
    end
    if isempty(c.title)
        add(c.path, 'warn', 'missing_title', 'recommended field title absent');
    end
    if isempty(c.description)
        add(c.path, 'warn', 'missing_description', 'recommended field description absent');
    end
    if isempty(c.timestamp)
        add(c.path, 'warn', 'missing_timestamp', 'recommended field timestamp absent');
    % SPEC 5: every timestamp-valued key is an ISO 8601 datetime with an
    % explicit UTC offset. Upstream made this literal on 2026-08-21 and the
    % reference bundles now emit '+00:00', so a trailing-Z-only pattern
    % rejected 44 of 44 conformant concepts. A bare local datetime still
    % fails: the offset is the point of the rule.
    elseif isempty(regexp(c.timestamp, '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$', 'once'))
        add(c.path, 'warn', 'timestamp_not_iso8601', ...
            sprintf('timestamp not ISO-8601: %s', c.timestamp));
    end
end
lk_all = okf.links(b);
for i = 1:numel(lk_all)
    lk = lk_all(i);
    if strcmp(lk.target, 'concept') || strcmp(lk.target, 'scope')
        continue;
    end
    if strcmp(lk.target, 'file')
        % The target exists, it is simply not a concept (an attester .py, a
        % computation .sql). SPEC 6.2 and 6.3 expect exactly this.
        add(lk.src_path, 'info', 'non_concept_target', ...
            sprintf('reference resolves to a non-concept file: %s', lk.dst_raw));
    elseif strcmp(lk.kind, 'body') || strcmp(lk.kind, 'wikilink')
        add(lk.src_path, 'warn', 'broken_link', ...
            sprintf('unresolved link: %s', lk.dst_raw));
    else
        add(lk.src_path, 'warn', 'broken_reference', ...
            sprintf('unresolved %s path: %s', lk.kind, lk.dst_raw));
    end
end
% A frontmatter path that resolves only against the bundle root, though SPEC
% 6.2 reserves that meaning for a leading slash. Reported so a producer can fix
% it; consumed regardless, because a consumer must be permissive (SPEC 11).
if isfield(b, 'files') && ~isempty(b.files)
    targets = b.files;
else
    targets = b.known;
end
for i = 1:numel(b.concepts)
    c = b.concepts(i);
    fps = okf.fm_paths(c.frontmatter);
    for j = 1:numel(fps)
        kind = fps{j}{1};
        raw = fps{j}{2};
        if ~isempty(raw) && raw(1) == '/'
            continue;
        end
        if strcmp(kind, 'source') && okf.is_scope(raw)
            continue;
        end
        [~, how] = okf.resolve_path(raw, c.path, targets);
        if strcmp(how, 'root')
            add(c.path, 'info', 'path_root_relative', ...
                sprintf(['%s path resolves against the bundle root, not the ' ...
                         'concept directory; SPEC 6.2 reserves that for a ' ...
                         'leading slash: %s'], kind, raw));
        end
    end
end
% orphan concepts: non-reserved, parseable, no inbound link
inbound = {};
for i = 1:numel(lk_all)
    if lk_all(i).resolved
        inbound{end + 1} = lk_all(i).dst_path; %#ok<AGROW>
    end
end
for i = 1:numel(b.concepts)
    c = b.concepts(i);
    if c.reserved || ~isempty(c.parse_error)
        continue;
    end
    if ~any(strcmp(c.path, inbound))
        add(c.path, 'warn', 'orphan', 'no inbound links (orphan concept)');
    end
end
end
