# =============================================================================
# 01_download_infodengue.R
# Downloads the weekly InfoDengue series (public "alertcity" API) for ALL
# Brazilian municipalities, from 2010 to the current year.
#
# Raw output   : data/raw/infodengue/<disease>/<geocode>.csv  (one file per municipality)
# Final output : data/processed/infodengue_<disease>.rds (+ .parquet if arrow is installed)
#
# The script is RESUMABLE: if it stops, run it again and it skips the
# municipalities already downloaded. Run it from the repository root.
# =============================================================================

# ---- Packages ----------------------------------------------------------------
pkgs <- c("httr2", "jsonlite", "readr", "dplyr", "purrr")
missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) install.packages(missing)
if (packageVersion("httr2") < "1.1.0") {
  stop("httr2 >= 1.1.0 is required: run install.packages('httr2')")
}

library(httr2)
library(dplyr)
library(purrr)
library(readr)

# ---- Parameters --------------------------------------------------------------
DISEASES   <- c("dengue")   # add "chikungunya", "zika" if needed
YEAR_START <- 2010
YEAR_END   <- as.integer(format(Sys.Date(), "%Y"))
MAX_ACTIVE <- 4             # parallel requests: keep it low, the API is public
BATCH_SIZE <- 200           # municipalities per batch (only affects progress messages)
TEST_MODE  <- FALSE         # TRUE = only 20 municipalities, to test the script

RAW_DIR <- file.path("data", "raw", "infodengue")
OUT_DIR <- file.path("data", "processed")

# ---- 1. List of municipalities (IBGE API) ------------------------------------
# The IBGE geocode has 7 digits: the first 2 are the state (UF) code.
get_municipalities <- function(path = file.path("data", "raw", "municipios_ibge.csv")) {
  if (file.exists(path)) return(read_csv(path, show_col_types = FALSE))

  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)

  # Primary source: official IBGE API (often slow or unreachable from abroad)
  mun <- tryCatch({
    raw <- request("https://servicodados.ibge.gov.br/api/v1/localidades/municipios") |>
      req_options(connecttimeout = 60) |>
      req_timeout(120) |>
      req_retry(max_tries = 3, retry_on_failure = TRUE) |>
      req_perform() |>
      resp_body_string() |>
      jsonlite::fromJSON(simplifyVector = TRUE)
    tibble(geocode = as.integer(raw$id), municipality = raw$nome)
  }, error = function(e) {
    message("IBGE API unreachable, using the GitHub mirror (kelvins/municipios-brasileiros)")
    NULL
  })

  # Fallback source: community-maintained CSV with the IBGE codes
  if (is.null(mun)) {
    raw <- read_csv(
      "https://raw.githubusercontent.com/kelvins/municipios-brasileiros/main/csv/municipios.csv",
      show_col_types = FALSE
    )
    mun <- tibble(geocode = as.integer(raw$codigo_ibge), municipality = raw$nome)
  }

  mun <- mun |> mutate(uf_code = geocode %/% 100000L)
  write_csv(mun, path)
  message(sprintf("Municipality list saved: %d municipalities", nrow(mun)))
  mun
}

# ---- 2. Request for one municipality -----------------------------------------
build_request <- function(geocode, disease) {
  request("https://info.dengue.mat.br/api/alertcity") |>
    req_url_query(
      geocode  = geocode,
      disease  = disease,
      format   = "csv",
      ew_start = 1,
      ew_end   = 53,          # 53, not 52: some years have an epidemiological week 53
      ey_start = YEAR_START,
      ey_end   = YEAR_END
    ) |>
    req_user_agent("AMU Predictive Methods student project (R/httr2)") |>
    req_options(connecttimeout = 60) |>
    req_timeout(120) |>
    req_retry(max_tries = 5, retry_on_failure = TRUE,
              backoff = function(i) min(60, 2^i))
}

# A valid response is a CSV whose header contains the SE column
is_valid_csv <- function(body) {
  first_line <- strsplit(body, "\n", fixed = TRUE)[[1]][1]
  !is.na(first_line) && grepl("SE", first_line, fixed = TRUE) &&
    !grepl("[EE]", first_line, fixed = TRUE)
}

# ---- 3. Download all municipalities for one disease --------------------------
download_disease <- function(disease, geocodes) {
  dir_d <- file.path(RAW_DIR, disease)
  dir.create(dir_d, recursive = TRUE, showWarnings = FALSE)

  files <- file.path(dir_d, paste0(geocodes, ".csv"))
  done  <- file.exists(files) & file.size(files) > 0
  todo  <- geocodes[!done]
  message(sprintf("[%s] %d municipalities already downloaded, %d to download",
                  disease, sum(done), length(todo)))
  if (length(todo) == 0) return(integer(0))

  failed  <- integer(0)
  batches <- split(todo, ceiling(seq_along(todo) / BATCH_SIZE))

  for (b in seq_along(batches)) {
    g     <- batches[[b]]
    reqs  <- map(g, build_request, disease = disease)
    resps <- req_perform_parallel(reqs, on_error = "continue",
                                  max_active = MAX_ACTIVE, progress = FALSE)

    for (i in seq_along(g)) {
      r  <- resps[[i]]
      ok <- inherits(r, "httr2_response") && resp_status(r) == 200
      if (ok) {
        body <- resp_body_string(r)
        ok   <- is_valid_csv(body)
        if (ok) writeLines(body, file.path(dir_d, paste0(g[i], ".csv")), sep = "")
      }
      if (!ok) failed <- c(failed, g[i])
    }

    message(sprintf("[%s] batch %d/%d done (failed so far: %d)",
                    disease, b, length(batches), length(failed)))
  }
  failed
}

# ---- 4. Combine the files into a single dataset ------------------------------
combine_disease <- function(disease) {
  files <- list.files(file.path(RAW_DIR, disease), pattern = "\\.csv$", full.names = TRUE)
  message(sprintf("[%s] combining %d files...", disease, length(files)))

  df <- map(files, function(f) {
    # read everything as text to avoid type conflicts between files
    d <- read_csv(f, col_types = cols(.default = col_character()), progress = FALSE)
    if (nrow(d) == 0) return(NULL)
    d$geocode <- tools::file_path_sans_ext(basename(f))
    d
  }, .progress = TRUE) |>
    list_rbind() |>
    type_convert(guess_integer = TRUE) |>
    mutate(disease = disease, geocode = as.integer(geocode)) |>
    arrange(geocode, SE) |>
    distinct(geocode, SE, .keep_all = TRUE)

  dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(df, file.path(OUT_DIR, paste0("infodengue_", disease, ".rds")))
  if (requireNamespace("arrow", quietly = TRUE)) {
    arrow::write_parquet(df, file.path(OUT_DIR, paste0("infodengue_", disease, ".parquet")))
  }
  message(sprintf("[%s] saved: %d rows, %d municipalities, SE from %s to %s",
                  disease, nrow(df), n_distinct(df$geocode), min(df$SE), max(df$SE)))
  invisible(df)
}

# ---- 5. Run ------------------------------------------------------------------
mun      <- get_municipalities()
geocodes <- mun$geocode
if (TEST_MODE) geocodes <- head(geocodes, 20)
message(sprintf("Municipalities to process: %d", length(geocodes)))

for (d in DISEASES) {
  failed <- download_disease(d, geocodes)
  if (length(failed) > 0) {
    fail_path <- file.path(RAW_DIR, paste0("failed_", d, ".csv"))
    write_csv(tibble(geocode = failed), fail_path)
    message(sprintf("[%s] %d municipalities failed (see %s): run the script again to retry them",
                    d, length(failed), fail_path))
  }
  combine_disease(d)
}
