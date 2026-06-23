#!/usr/bin/env python3
"""Convert the Interpretable ML book (Quarto .qmd chapters) into a minimal OKF bundle.
Part -> chapters structure taken verbatim from the book's _quarto.yml."""
import os, re, shutil

SRC, OUT, TS = "src/manuscript", "iml-okf", "2025-04-13T00:00:00Z"
PARTS = {
    "Foundations": ["intro", "interpretability", "goals", "overview", "data"],
    "Interpretable Models": ["limo", "logistic", "extend-lm", "tree", "rules", "rulefit"],
    "Local Model-Agnostic Methods": ["ceteris-paribus", "ice", "lime", "counterfactual", "anchors", "shapley", "shap"],
    "Global Model-Agnostic Methods": ["pdp", "ale", "interaction", "decomposition", "feature-importance", "lofo", "global", "proto"],
    "Neural Network Interpretation": ["cnn-features", "pixel-attribution", "detecting-concepts", "adversarial", "influential"],
    "Beyond the Methods": ["evaluation", "storytime", "future", "translations"],
    "Back Matter": ["cite", "acknowledgements"],
    "Appendix": ["what-is-machine-learning", "math-terms", "r-packages", "references"],
}

shutil.rmtree(OUT, ignore_errors=True); os.makedirs(OUT)
pslug = lambda p: "part-" + re.sub(r"[^a-z0-9]+", "-", p.lower())
yqt = lambda s: '"' + s.replace('"', "'") + '"'

def clean(lines):
    out = []
    for ln in lines:
        if re.match(r"^\s*(\{\{<|:::)", ln):           # drop Quarto directives
            continue
        ln = re.sub(r"\s*\{#[^}]+\}\s*$", "", ln)      # strip {#label} from headings
        ln = re.sub(r"!\[[^]]*\]\([^)]*\)", "", ln)    # remove image embeds
        ln = re.sub(r"\[([^]]+)\]\([^)]*\)", r"\1", ln) # de-link to prose
        out.append(ln)
    return out

def first_sentence(body):
    for ln in body:
        if ln.strip() and not ln.startswith("#"):
            return re.sub(r"([.!?]).*$", r"\1", ln.strip())[:200]
    return ""

def fm(type_, title, desc):
    return ["---", f"type: {type_}", f"title: {yqt(title)}", f"description: {yqt(desc)}",
            f"timestamp: {TS}", "tags: [interpretable-ml]", "---", ""]

def write(name, lines):
    with open(os.path.join(OUT, name), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

for part, stubs in PARTS.items():
    for stub in stubs:
        f = os.path.join(SRC, stub + ".qmd")
        if not os.path.exists(f):
            continue
        raw = open(f, encoding="utf-8").read().splitlines()
        h1 = next((l for l in raw if re.match(r"^#\s", l)), None)
        title = stub if h1 is None else re.sub(r"\{#[^}]+\}", "", re.sub(r"^#\s+", "", h1)).strip()
        body = clean(raw)
        write(stub + ".md", fm(part, title, first_sentence(body)) + body)

for part, stubs in PARTS.items():
    links = [f"- [{s}]({s}.md)" for s in stubs]
    write(pslug(part) + ".md", fm("Part", part, f"Chapters in the {part} part.") + [f"# {part}", ""] + links)

ix = fm("Index", "Interpretable Machine Learning",
        "A Guide for Making Black Box Models Explainable - Christoph Molnar (CC BY-NC-SA).")
ix += ["# Interpretable Machine Learning", ""] + [f"- [{p}]({pslug(p)}.md)" for p in PARTS]
write("index.md", ix)
write("log.md", ["---", "type: Log", 'title: "Change log"', f"timestamp: {TS}", "---", "",
                 "# Change log", "", "- Converted from the Quarto sources of *Interpretable Machine Learning*."])
print("wrote", len([f for f in os.listdir(OUT) if f.endswith(".md")]), "OKF files")
