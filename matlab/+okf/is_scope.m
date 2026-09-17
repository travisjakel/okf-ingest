function tf = is_scope(raw)
%IS_SCOPE True when a sources[].resource is a scope descriptor, not a path.
%   SPEC 5.1 allows e.g. 'all queries in BigQuery project X'. A path never
%   contains whitespace, which is the only signal the spec gives.
tf = ~isempty(regexp(raw, '\s', 'once'));
end
