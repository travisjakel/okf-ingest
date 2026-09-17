function ing = ingest_bundle(b)
%INGEST_BUNDLE Pure summary computation -- mirrors py _ingest_bundle,
%   catalog-free (all conformance-asserted values are in-memory).
findings = okf.validate(b);
lk = okf.links(b);

err_paths = {};
n_err = 0;
n_warn = 0;
for i = 1:numel(findings)
    if strcmp(findings(i).severity, 'error')
        err_paths{end + 1} = findings(i).path; %#ok<AGROW>
        n_err = n_err + 1;
    elseif strcmp(findings(i).severity, 'warn')
        % 'info' is neither: a note for a producer, never a defect count.
        n_warn = n_warn + 1;
    end
end
n_non_reserved = 0;
n_conf = 0;
for i = 1:numel(b.concepts)
    if b.concepts(i).reserved
        continue;
    end
    n_non_reserved = n_non_reserved + 1;
    if ~any(strcmp(b.concepts(i).path, err_paths))
        n_conf = n_conf + 1;
    end
end
n_broken = 0;
for i = 1:numel(lk)
    if strcmp(lk(i).target, 'missing')
        n_broken = n_broken + 1;
    end
end

summary = struct('n_files', numel(b.concepts), 'n_concepts', n_non_reserved, ...
                 'n_conformant', n_conf, 'conformant', isempty(err_paths), ...
                 'errors', n_err, 'warnings', n_warn, ...
                 'links_total', numel(lk), 'links_broken', n_broken);
ing = struct('bundle', b, 'links', lk, 'findings', findings, 'summary', summary);
end
