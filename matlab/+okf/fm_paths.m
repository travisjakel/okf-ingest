function out = fm_paths(fm)
%FM_PATHS Path-valued frontmatter fields (SPEC 6.2), in a fixed order.
%   resource, computation, executor.resource, attester.resource,
%   sources[].resource. Returns a cell array of {kind, raw} pairs; the fixed
%   order is what keeps the edge list deterministic across bindings.
out = {};
if ~isa(fm, 'containers.Map')
    return;
end
out = push(out, fm, 'resource', 'resource');
out = push(out, fm, 'computation', 'computation');
out = push_nested(out, fm, 'executor');
out = push_nested(out, fm, 'attester');
if isKey(fm, 'sources')
    ss = fm('sources');
    if isa(ss, 'containers.Map')
        ss = {ss};
    end
    if iscell(ss)
        for i = 1:numel(ss)
            s = ss{i};
            if isa(s, 'containers.Map') && isKey(s, 'resource') && ischar(s('resource'))
                v = s('resource');
                if ~isempty(v)
                    out{end + 1} = {'source', v}; %#ok<AGROW>
                end
            end
        end
    end
end
end

function out = push(out, m, key, kind)
if isKey(m, key)
    v = m(key);
    if ischar(v) && ~isempty(v)
        out{end + 1} = {kind, v};
    end
end
end

function out = push_nested(out, fm, key)
if ~isKey(fm, key)
    return;
end
inner = fm(key);
if isa(inner, 'containers.Map') && isKey(inner, 'resource') && ischar(inner('resource'))
    v = inner('resource');
    if ~isempty(v)
        out{end + 1} = {key, v};
    end
end
end
