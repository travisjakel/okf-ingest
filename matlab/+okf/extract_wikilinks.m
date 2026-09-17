function out = extract_wikilinks(body)
%EXTRACT_WIKILINKS [[wikilink]] / [[target|display]] refs (display stripped).
raw = regexp(okf.internal.mask_fences(body), '\[\[([^\]]+)\]\]', 'tokens');
out = cell(1, numel(raw));
for i = 1:numel(raw)
    m = raw{i}{1};
    bar = find(m == '|', 1);
    if ~isempty(bar)
        m = m(1:bar - 1);
    end
    out{i} = strtrim(m);
end
end
