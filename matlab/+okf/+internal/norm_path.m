function p = norm_path(p)
%NORM_PATH Collapse '.', '..' and empty segments; forward slashes only.
%   Shared by resolve_link (links.m) and okf.resolve_path so the two can never
%   drift apart.
p = strrep(p, '\', '/');
segs = strsplit(p, '/', 'CollapseDelimiters', false);
out = {};
for i = 1:numel(segs)
    s = segs{i};
    if isempty(s) || strcmp(s, '.')
        continue;
    elseif strcmp(s, '..')
        if ~isempty(out)
            out(end) = []; %#ok<AGROW>
        end
    else
        out{end + 1} = s; %#ok<AGROW>
    end
end
p = strjoin(out, '/');
end
