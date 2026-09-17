function check_matlab()
%CHECK_MATLAB Conformance check: MATLAB binding vs conformance/expected/*.json.
%   Mirrors check_py.py -- collects every failure, then errors (nonzero exit
%   under matlab -batch / octave --eval). Run from anywhere:
%     matlab -batch "run('conformance/check_matlab.m')"   or
%     octave --eval "run('conformance/check_matlab.m')"
%   Note: jsondecode mangles JSON keys containing '.'/'|' into struct field
%   names, so content_hashes and resolutions are read from the raw JSON text.

here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..', 'matlab'));
fails = {};
    function chk(name, got, want)
        if ~isequaln(norm_v(got), norm_v(want))
            fails{end + 1} = sprintf('%s: got %s want %s', name, disp_v(got), disp_v(want));
        end
    end

% sha1 self-test (pure-M implementation) against FIPS 180-1 vectors
chk('sha1.abc', okf.internal.sha1_hex(uint8('abc')), ...
    'a9993e364706816aba3e25717850c26c9cd0d89d');
chk('sha1.empty', okf.internal.sha1_hex(uint8([])), ...
    'da39a3ee5e6b4b0d3255bfef95601890afd80709');

% --- store (conformant) ---
ing = okf.ingest(fullfile(here, 'bundles', 'store'));
raw = fileread(fullfile(here, 'expected', 'store.json'));
exp_store = jsondecode(raw);
chk('store.okf_version', ing.bundle.okf_version, exp_store.bundle.okf_version);
chk('store.n_concepts', ing.summary.n_concepts, exp_store.bundle.n_concepts);
chk('store.n_conformant', ing.summary.n_conformant, exp_store.bundle.n_conformant);
chk('store.conformant', ing.summary.conformant, exp_store.bundle.conformant);
chk('store.errors', ing.summary.errors, 0);
chk('store.links_total', ing.summary.links_total, 8);
chk('store.links_broken', ing.summary.links_broken, 1);
want_h = regexp(raw, '"customers\.md":\s*"([0-9a-f]{40})"', 'tokens', 'once');
got_h = '';
for i = 1:numel(ing.bundle.concepts)
    if strcmp(ing.bundle.concepts(i).path, 'customers.md')
        got_h = ing.bundle.concepts(i).content_hash;
    end
end
chk('store.content_hash[customers.md]', got_h, want_h{1});

% --- fetch path: ingest the same bundle from a tar archive (offline) ---
tmp = tempname();
mkdir(tmp);
% plain .tar: the tar() builtin gzips by extension in MATLAB but not Octave;
% a plain archive keeps the round-trip portable across both.
tarp = fullfile(tmp, 'store.tar');
try
    tar(tarp, {'store'}, fullfile(here, 'bundles'));
    ing3 = okf.ingest(tarp);
    chk('fetch.tar.n_concepts', ing3.summary.n_concepts, 3);
    chk('fetch.tar.conformant', ing3.summary.conformant, true);
catch err
    fails{end + 1} = sprintf('fetch.tar: %s', err.message);
end
try
    rmdir(tmp, 's');
catch
end

% --- negative ---
ing2 = okf.ingest(fullfile(here, 'bundles', 'negative'));
expn = jsondecode(fileread(fullfile(here, 'expected', 'negative.json')));
chk('negative.conformant', ing2.summary.conformant, expn.bundle.conformant);
chk('negative.errors', ing2.summary.errors, expn.validation.errors);
for i = 1:numel(expn.validation.error_rules)
    er = expn.validation.error_rules(i);
    got_rule = '';
    for j = 1:numel(ing2.findings)
        f = ing2.findings(j);
        if strcmp(f.severity, 'error') && strcmp(f.path, er.path)
            got_rule = f.rule;
        end
    end
    chk(sprintf('negative.%s', er.path), got_rule, er.rule);
end

% --- wikilinks ---
ingw = okf.ingest(fullfile(here, 'bundles', 'wikilinks'));
raww = fileread(fullfile(here, 'expected', 'wikilinks.json'));
expw = jsondecode(raww);
chk('wikilinks.n_concepts', ingw.summary.n_concepts, expw.bundle.n_concepts);
chk('wikilinks.conformant', ingw.summary.conformant, expw.bundle.conformant);
chk('wikilinks.links_total', ingw.summary.links_total, expw.links.total);
chk('wikilinks.links_broken', ingw.summary.links_broken, expw.links.broken);
% resolutions from raw JSON (keys contain '.' and '|')
res_tok = regexp(raww, '"([^"]+\|[^"]+)":\s*(null|"[^"]*")', 'tokens');
for i = 1:numel(res_tok)
    key = res_tok{i}{1};
    want_raw = res_tok{i}{2};
    if strcmp(want_raw, 'null')
        want = '';
    else
        want = want_raw(2:end - 1);
    end
    bar = find(key == '|', 1);
    src = key(1:bar - 1);
    raw_ref = key(bar + 1:end);
    got = '';
    for j = 1:numel(ingw.links)
        l = ingw.links(j);
        if strcmp(l.src_path, src) && strcmp(l.dst_raw, raw_ref)
            got = l.dst_path;
        end
    end
    chk(sprintf('wikilinks.%s', key), got, want);
end

% --- v0.2 (generated/sources/verified; generated.at timestamp fallback) ---
ingv = okf.ingest(fullfile(here, 'bundles', 'v02'));
rawv = fileread(fullfile(here, 'expected', 'v02.json'));
expv = jsondecode(rawv);
chk('v02.okf_version', ingv.bundle.okf_version, expv.bundle.okf_version);
chk('v02.n_concepts', ingv.summary.n_concepts, expv.bundle.n_concepts);
chk('v02.conformant', ingv.summary.conformant, expv.bundle.conformant);
chk('v02.errors', ingv.summary.errors, expv.validation.errors);
chk('v02.warnings', ingv.summary.warnings, expv.validation.warnings);
chk('v02.links_total', ingv.summary.links_total, expv.links.total);
chk('v02.links_broken', ingv.summary.links_broken, expv.links.broken);
for i = 1:numel(expv.validation.forbidden_rules)
    fr = expv.validation.forbidden_rules{i};
    present = false;
    for j = 1:numel(ingv.findings)
        if strcmp(ingv.findings(j).rule, fr)
            present = true;
        end
    end
    chk(sprintf('v02.no_%s', fr), present, false);
end
% timestamps from raw JSON (keys contain '.'; jsondecode mangles them)
ts_tok = regexp(rawv, '"([a-z]+\.md)":\s*"([0-9TZ:.-]+)"', 'tokens');
for i = 1:numel(ts_tok)
    pth = ts_tok{i}{1};
    want = ts_tok{i}{2};
    got = '';
    for j = 1:numel(ingv.bundle.concepts)
        if strcmp(ingv.bundle.concepts(j).path, pth)
            got = ingv.bundle.concepts(j).timestamp;
        end
    end
    chk(sprintf('v02.timestamp[%s]', pth), got, want);
end
% lock the parser extension itself: nested shapes survive into frontmatter
wfm = [];
for j = 1:numel(ingv.bundle.concepts)
    if strcmp(ingv.bundle.concepts(j).path, 'widget.md')
        wfm = ingv.bundle.concepts(j).frontmatter;
    end
end
if ~isa(wfm, 'containers.Map')
    fails{end + 1} = 'v02.shape: widget.md frontmatter did not parse (nested YAML unsupported?)';
else
    gen = wfm('generated');
    chk('v02.shape.generated_is_map', isa(gen, 'containers.Map'), true);
    chk('v02.shape.generated_at', gen('at'), '2026-08-01T00:00:00Z');
    src = wfm('sources');
    chk('v02.shape.sources_is_cell', iscell(src) && numel(src) == 2, true);
    s1 = src{1};
    chk('v02.shape.source1_id', s1('id'), 'widget-schema');
    chk('v02.shape.source1_usage_count_verbatim', s1('usage_count'), '5000');
    vrf = wfm('verified');
    v1 = vrf{1};
    chk('v02.shape.verified_by', v1('by'), 'human:reviewer');
    uw = wfm('usage_window');
    chk('v02.shape.usage_window_from', uw('from'), '2026-06-01');
end

% --- v0.2 Attested Computation: SPEC 6.2 frontmatter path fields as edges ---
inga = okf.ingest(fullfile(here, 'bundles', 'v02_attested'));
expa = jsondecode(fileread(fullfile(here, 'expected', 'v02_attested.json')));
chk('v02a.n_files', inga.summary.n_files, expa.bundle.n_files);
chk('v02a.n_concepts', inga.summary.n_concepts, expa.bundle.n_concepts);
chk('v02a.n_conformant', inga.summary.n_conformant, expa.bundle.n_conformant);
chk('v02a.conformant', inga.summary.conformant, expa.bundle.conformant);
chk('v02a.errors', inga.summary.errors, expa.validation.errors);
chk('v02a.warnings', inga.summary.warnings, expa.validation.warnings);
chk('v02a.links_total', inga.summary.links_total, expa.links.total);
chk('v02a.links_broken', inga.summary.links_broken, expa.links.broken);
for i = 1:numel(expa.validation.forbidden_rules)
    fr = expa.validation.forbidden_rules{i};
    present = false;
    for j = 1:numel(inga.findings)
        if strcmp(inga.findings(j).rule, fr)
            present = true;
        end
    end
    chk(sprintf('v02a.no_%s', fr), present, false);
end
rcn = fieldnames(expa.validation.rule_counts);
for i = 1:numel(rcn)
    got = 0;
    for j = 1:numel(inga.findings)
        if strcmp(inga.findings(j).rule, rcn{i})
            got = got + 1;
        end
    end
    chk(sprintf('v02a.rule[%s]', rcn{i}), got, expa.validation.rule_counts.(rcn{i}));
end
kn = fieldnames(expa.links.by_kind);
for i = 1:numel(kn)
    got = 0;
    for j = 1:numel(inga.links)
        if strcmp(inga.links(j).kind, kn{i})
            got = got + 1;
        end
    end
    chk(sprintf('v02a.kind[%s]', kn{i}), got, expa.links.by_kind.(kn{i}));
end
tn = fieldnames(expa.links.by_target);
for i = 1:numel(tn)
    got = 0;
    for j = 1:numel(inga.links)
        if strcmp(inga.links(j).target, tn{i})
            got = got + 1;
        end
    end
    chk(sprintf('v02a.target[%s]', tn{i}), got, expa.links.by_target.(tn{i}));
end
% lock the parser extension itself: the Attested Computation shapes survive
cfm = [];
for j = 1:numel(inga.bundle.concepts)
    if strcmp(inga.bundle.concepts(j).path, 'computations/throughput.md')
        cfm = inga.bundle.concepts(j).frontmatter;
    end
end
if ~isa(cfm, 'containers.Map')
    fails{end + 1} = 'v02a.shape: throughput.md frontmatter did not parse';
else
    chk('v02a.shape.runtime', cfm('runtime'), 'duckdb');
    ex = cfm('executor');
    chk('v02a.shape.executor_is_map', isa(ex, 'containers.Map'), true);
    chk('v02a.shape.executor_resource', ex('resource'), 'skills/run-local.md');
    prm = cfm('parameters');
    chk('v02a.shape.parameters_is_cell', iscell(prm) && numel(prm) == 2, true);
    p1 = prm{1};
    chk('v02a.shape.param1_name', p1('name'), 'day');
    chk('v02a.shape.param1_type', p1('type'), 'string');
    vrfa = cfm('verified');
    chk('v02a.shape.verified_is_cell', iscell(vrfa) && numel(vrfa) == 2, true);
end

% --- rank (Personalized PageRank: exact, deterministic, parity-locked) ---
ingr = okf.ingest(fullfile(here, 'bundles', 'store'));
expr = jsondecode(fileread(fullfile(here, 'expected', 'rank.json')));
ranked = okf.ppr(ingr, expr.start, 'damping', expr.damping, 'k', 10);
chk('rank.n', numel(ranked), numel(expr.ranking));
for i = 1:min(numel(ranked), numel(expr.ranking))
    chk(sprintf('rank.%d.path', i), ranked(i).path, expr.ranking(i).path);
    chk(sprintf('rank.%d.score', i), okf.round_dec(ranked(i).score, 8), ...
        expr.ranking(i).score);
end

% --- query seeding (lexical seeds -> multi-seed PPR, parity-locked) ---
expq = jsondecode(fileread(fullfile(here, 'expected', 'query.json')));
got_seeds = okf.seeds(ingr, expq.query, 5);
chk('query.n_seeds', numel(got_seeds), numel(expq.seeds));
starts = {};
weights = [];
for i = 1:min(numel(got_seeds), numel(expq.seeds))
    chk(sprintf('query.seed.%d.path', i), got_seeds(i).path, expq.seeds(i).path);
    chk(sprintf('query.seed.%d.score', i), got_seeds(i).score, expq.seeds(i).score);
end
for i = 1:numel(got_seeds)
    starts{end + 1} = got_seeds(i).path; %#ok<AGROW>
    weights(end + 1) = got_seeds(i).score; %#ok<AGROW>
end
qr = okf.ppr(ingr, starts, 'weights', weights, 'k', 10);
chk('query.n', numel(qr), numel(expq.ranking));
for i = 1:min(numel(qr), numel(expq.ranking))
    chk(sprintf('query.%d.path', i), qr(i).path, expq.ranking(i).path);
    chk(sprintf('query.%d.score', i), okf.round_dec(qr(i).score, 8), ...
        expq.ranking(i).score);
end

% --- diff (deterministic concept-level changelog) ---
da = fullfile(here, 'bundles', 'diff_a');
db = fullfile(here, 'bundles', 'diff_b');
dd = okf.diff(da, db);
expd = jsondecode(fileread(fullfile(here, 'expected', 'diff.json')));
chk('diff.identical', dd.identical, expd.identical);
chk('diff.added', dd.added, expd.added);
chk('diff.removed', dd.removed, expd.removed);
chk('diff.changed', dd.changed, expd.changed);
chk('diff.type_changed', fmt_field(dd.type_changed), expd.type_changed);
chk('diff.retitled', fmt_field(dd.retitled), expd.retitled);
chk('diff.links_added', fmt_edge(dd.links_added), expd.links_added);
chk('diff.links_removed', fmt_edge(dd.links_removed), expd.links_removed);
chk('diff.broken_added', fmt_edge(dd.broken_added), expd.broken_added);
chk('diff.broken_fixed', fmt_edge(dd.broken_fixed), expd.broken_fixed);
% drift mode: an ingest diffed against its own source directory is identical
ingd = okf.ingest(da);
d0 = okf.diff(ingd, da);
chk('diff.drift_identical', d0.identical, true);

% --- dogfood: the repo's own bundle must ingest clean ---
dog = okf.ingest(fullfile(here, '..', 'docs', 'okf-bundle'));
chk('dogfood.errors', dog.summary.errors, 0);
chk('dogfood.conformant', dog.summary.conformant, true);
chk('dogfood.nonempty', dog.summary.n_concepts > 0, true);

if ~isempty(fails)
    fprintf('FAIL\n');
    for i = 1:numel(fails)
        fprintf('  %s\n', fails{i});
    end
    error('okf:conformance', '%d conformance check(s) failed', numel(fails));
end
fprintf('PASS -- MATLAB binding conformant on all fixtures\n');
end

function v = norm_v(v)
%NORM_V Normalize for isequaln: empties unify, cellstr columns/rows unify,
%   numerics to double, logicals kept.
if isempty(v) && ~ischar(v)
    v = [];
elseif ischar(v) && isempty(v)
    v = [];
elseif iscell(v)
    v = v(:)';
elseif isnumeric(v)
    v = double(v);
end
end

function s = disp_v(v)
if ischar(v)
    s = ['''' v ''''];
elseif iscell(v)
    s = ['{' strjoin(cellfun(@disp_v, v, 'UniformOutput', false), ', ') '}'];
elseif islogical(v)
    if v, s = 'true'; else, s = 'false'; end
elseif isnumeric(v) && isscalar(v)
    s = sprintf('%.10g', v);
else
    s = '<value>';
end
end

function out = fmt_field(xs)
out = {};
for i = 1:numel(xs)
    out{end + 1} = sprintf('%s|%s|%s', xs{i}.path, xs{i}.from, xs{i}.to); %#ok<AGROW>
end
end

function out = fmt_edge(xs)
out = {};
for i = 1:numel(xs)
    out{end + 1} = sprintf('%s|%s', xs{i}.src_path, xs{i}.dst); %#ok<AGROW>
end
end
