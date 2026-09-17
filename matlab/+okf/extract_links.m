function out = extract_links(body)
%EXTRACT_LINKS Markdown link targets: ](target) -- mirrors py _LINK.
out = regexp(okf.internal.mask_fences(body), '\]\(\s*([^)\s]+)', 'tokens');
out = cellfun(@(t) t{1}, out, 'UniformOutput', false);
end
