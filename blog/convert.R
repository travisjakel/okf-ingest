# Convert the Interpretable ML book (Quarto .qmd chapters) into a minimal OKF bundle.
# Part -> chapters structure taken verbatim from the book's _quarto.yml.
src <- "src/manuscript"; out <- "iml-okf"; ts <- "2025-04-13T00:00:00Z"
unlink(out, recursive = TRUE); dir.create(out)

parts <- list(
  "Foundations" = c("intro","interpretability","goals","overview","data"),
  "Interpretable Models" = c("limo","logistic","extend-lm","tree","rules","rulefit"),
  "Local Model-Agnostic Methods" = c("ceteris-paribus","ice","lime","counterfactual","anchors","shapley","shap"),
  "Global Model-Agnostic Methods" = c("pdp","ale","interaction","decomposition","feature-importance","lofo","global","proto"),
  "Neural Network Interpretation" = c("cnn-features","pixel-attribution","detecting-concepts","adversarial","influential"),
  "Beyond the Methods" = c("evaluation","storytime","future","translations"),
  "Back Matter" = c("cite","acknowledgements"),
  "Appendix" = c("what-is-machine-learning","math-terms","r-packages","references")
)

pslug <- function(p) paste0("part-", gsub("[^a-z0-9]+", "-", tolower(p)))
clean <- function(x) {
  x <- x[!grepl("^\\s*(\\{\\{<|:::)", x)]                       # drop Quarto directives
  x <- sub("\\s*\\{#[^}]+\\}\\s*$", "", x)                      # strip {#label} from headings
  x <- gsub("!\\[[^]]*\\]\\([^)]*\\)", "", x)                   # remove image embeds
  gsub("\\[([^]]+)\\]\\([^)]*\\)", "\\1", x)                    # de-link to prose (concept links come from structure)
}
first_sentence <- function(body) {
  p <- body[nzchar(trimws(body)) & !grepl("^#", body)]
  if (!length(p)) return("")
  substr(sub("([.!?]).*$", "\\1", trimws(p[1])), 1, 200)
}
yqt <- function(s) paste0("\"", gsub("\"", "'", s), "\"")
fm <- function(type, title, desc) c("---", paste0("type: ", type),
  paste0("title: ", yqt(title)), paste0("description: ", yqt(desc)),
  paste0("timestamp: ", ts), "tags: [interpretable-ml]", "---", "")

for (part in names(parts)) for (stub in parts[[part]]) {
  f <- file.path(src, paste0(stub, ".qmd")); if (!file.exists(f)) next
  raw <- readLines(f, warn = FALSE, encoding = "UTF-8")
  h1 <- raw[grepl("^#\\s", raw)][1]
  title <- if (is.na(h1)) stub else trimws(sub("\\{#[^}]+\\}", "", sub("^#\\s+", "", h1)))
  body <- clean(raw)
  writeLines(c(fm(part, title, first_sentence(body)), body),
             file.path(out, paste0(stub, ".md")), useBytes = TRUE)
}

# One page per book part, linking its chapters -> a clustered (not flat-star) graph.
for (part in names(parts)) {
  links <- sprintf("- [%s](%s.md)", parts[[part]], parts[[part]])
  writeLines(c(fm("Part", part, paste("Chapters in the", part, "part.")),
               paste0("# ", part), "", links),
             file.path(out, paste0(pslug(part), ".md")), useBytes = TRUE)
}

# index.md links to the parts (the parts link to chapters).
ix <- c(fm("Index", "Interpretable Machine Learning",
           "A Guide for Making Black Box Models Explainable - Christoph Molnar (CC BY-NC-SA)."),
        "# Interpretable Machine Learning", "")
for (part in names(parts)) ix <- c(ix, sprintf("- [%s](%s.md)", part, pslug(part)))
writeLines(ix, file.path(out, "index.md"), useBytes = TRUE)
writeLines(c("---","type: Log","title: \"Change log\"",paste0("timestamp: ", ts),"---","",
             "# Change log","","- Converted from the Quarto sources of *Interpretable Machine Learning*."),
           file.path(out, "log.md"), useBytes = TRUE)
cat("wrote", length(list.files(out, pattern = "\\.md$")), "OKF files\n")
