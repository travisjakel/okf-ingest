function out = mask_fences(body)
%MASK_FENCES Blank out fenced code blocks before extracting references.
%   Markdown does not linkify fenced content, so neither do we -- but this only
%   became consequential with SPEC 10, which makes code in the body the NORMAL
%   case for an Attested Computation. Measured on a real `runtime: r` bundle:
%   R's flat[[paste0("knock_on_", src)]] indexing syntax is literally [[...]],
%   so three phantom wikilinks came out of one computation. Phantom BROKEN
%   references are only noise; the real hazard is a reference in code that
%   happens to match a concept, which becomes a silently false edge.
%
%   Fenced blocks only. Indented (4-space) blocks are NOT masked -- that is
%   also ordinary nested-list continuation. Inline code spans are NOT masked
%   either: authors put backticks around a reference for emphasis and mean it,
%   and masking spans would have dropped 8 resolving edges in a 219-concept
%   wiki.
%
%   Simplified CommonMark, chosen so five bindings implement it identically: a
%   line of >=3 backticks or tildes (indented up to 3 spaces) opens; a line of
%   >=N of the SAME character with nothing else on it closes. An unclosed fence
%   masks to the end of the body.
if isempty(body)
    out = body;
    return;
end
lines = okf.internal.split_lines(body);
open_ch = '';
open_len = 0;
for i = 1:numel(lines)
    ln = lines{i};
    indent = 0;
    while indent < numel(ln) && ln(indent + 1) == ' '
        indent = indent + 1;
    end
    handled = false;
    if indent <= 3 && indent < numel(ln) && (ln(indent + 1) == '`' || ln(indent + 1) == '~')
        ch = ln(indent + 1);
        run = 0;
        while indent + run < numel(ln) && ln(indent + run + 1) == ch
            run = run + 1;
        end
        if run >= 3
            rest = strtrim(ln(indent + run + 1:end));
            if isempty(open_ch)
                open_ch = ch;
                open_len = run;
                lines{i} = '';
                handled = true;
            elseif ch == open_ch && run >= open_len && isempty(rest)
                open_ch = '';
                open_len = 0;
                lines{i} = '';
                handled = true;
            end
        end
    end
    if ~handled && ~isempty(open_ch)
        lines{i} = '';
    end
end
out = strjoin(lines, sprintf('\n'));
end
