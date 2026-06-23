#' okf: Open Knowledge Format (OKF) Ingestion
#'
#' Read, validate, and load Open Knowledge Format (OKF) bundles into a portable
#' DuckDB catalog, build the concept graph, and optionally embed concept bodies
#' for semantic search. Conformant and permissive per the OKF v0.1
#' specification.
#'
#' @keywords internal
#' @importFrom yaml yaml.load
#' @importFrom digest digest
#' @importFrom jsonlite toJSON
#' @importFrom DBI dbConnect dbDisconnect dbExecute dbGetQuery dbAppendTable
#' @importFrom duckdb duckdb
#' @importFrom utils download.file unzip untar
#' @importFrom stats setNames
"_PACKAGE"
